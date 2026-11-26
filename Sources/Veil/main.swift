// Veil — blurs and dims every window except the one you're working in.
//
// Files
//   Settings.swift      persisted, observable settings
//   Overlay.swift       per-display overlay window (blur / tint / grain / mask)
//   Engine.swift        focus logic + overlay ordering
//   Input.swift         shake & corner gestures, hotkeys, menu bar/Dock auto-hide
//   SettingsPanel.swift the right-edge settings panel (window)
//   SettingsView.swift  its content (SwiftUI)
//   MenuBarIcon.swift   the four menu-bar icon states
//   main.swift          app delegate, menu bar item, URL scheme
//
// Permissions: none for the core feature. Auto-hide Menu Bar & Dock asks for
// Automation access to System Events the first time it runs.

import AppKit
import SwiftUI
import Carbon
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let s = Settings.shared
    private var engine: Engine!
    private var gestures: Gestures!
    private let bars = BarHider()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var bag = Set<AnyCancellable>()
    /// Sparkle auto-updater, created once for the app's lifetime.
    private let updater = Updater()
    private let onboarding = OnboardingController()

    func applicationDidFinishLaunching(_ note: Notification) {
        engine = Engine()
        engine.onActiveChange = { [weak self] active in
            self?.bars.set(active: active)
            self?.updateIcon()
        }
        gestures = Gestures(engine: engine) { [weak self] in self?.toggle() }
        reloadHotkeys()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        updateIcon()

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))

        SettingsPanel.shared.makeContent = { [weak self] in
            AnyView(SettingsView(reloadHotkeys: { self?.reloadHotkeys() },
                                 checkForUpdates: { self?.checkForUpdates() },
                                 toggleIgnoreFront: { self?.ignoreFrontApp() }))
        }
        // Icon follows mode / on-off / ignore changes; auto-hide follows its setting live.
        s.objectWillChange.debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.updateIcon()
                self.bars.set(active: self.engine.active)
            }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontChanged),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // First launch (or first launch after the guide changed): show the welcome guide once.
        if Onboarding.shouldShow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showWelcomeGuide() }
        }
    }

    func applicationWillTerminate(_ note: Notification) { bars.restoreNow() }

    private func reloadHotkeys() {
        HotKeys.reload([
            .toggle: { [weak self] in self?.toggle() },
            .switchMode: { [weak self] in self?.switchMode() },
            .ignoreApp: { [weak self] in self?.ignoreFrontApp() },
            .toggleControls: { [weak self] in self?.toggleSettings() },
        ])
    }

    @objc private func frontChanged() { updateIcon() }

    private func updateIcon() {
        let front = engine?.focusedAppPublic?.bundleIdentifier ?? ""
        let state: MenuBarIcon.State
        if !s.enabled { state = .off }
        else if s.ignored.contains(front) { state = .ignored }
        else { state = s.mode == .deep ? .deep : .ambient }
        statusItem?.button?.image = MenuBarIcon.image(state)
    }

    // MARK: Actions

    @objc func toggle() { s.enabled.toggle(); engine.tick(); updateIcon() }
    @objc func switchMode() { s.mode = s.mode == .ambient ? .deep : .ambient }
    @objc func setMode(_ sender: NSMenuItem) { s.mode = Mode.allCases[sender.tag] }

    @objc func ignoreFrontApp() { ignoreFront(onlyAdd: false) }

    /// Toggle the front app in Ignored apps (`onlyAdd`: add only, never remove).
    func ignoreFront(onlyAdd: Bool) {
        guard let app = engine.focusedAppPublic, let id = app.bundleIdentifier else { return }
        if s.ignored.contains(id) { if !onlyAdd { s.ignored.removeAll { $0 == id } } } else { s.ignored.append(id) }
        engine.tick()
        updateIcon()
    }

    @objc func checkForUpdates() { updater.checkForUpdates() }

    /// Opens the welcome guide (also shown automatically once, see applicationDidFinishLaunching).
    @objc func showWelcomeGuide() {
        onboarding.show(title: { L("onboarding.veil.window") }, pages: VeilGuide.pages, ctaTitle: { VeilGuide.ctaTitle }) { [weak self] in
            self?.openSettings()
        }
    }

    @objc func peek() {
        engine.peeking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.engine.peeking = false }
    }

    @objc func toggleSettings() { SettingsPanel.shared.toggle() }
    @objc func openSettings() { SettingsPanel.shared.open() }

    // MARK: Menu bar item

    @objc private func statusClicked() {
        let e = NSApp.currentEvent
        let right = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true
        if right {
            showMenu()
        } else if s.menuClick == .settings {
            toggleSettings()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // opens the menu attached above
    }

    func menuDidClose(_ menu: NSMenu) { statusItem.menu = nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?, _ action: Action? = nil, symbol: String? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            if let a = action, let sc = s.shortcut(a) {
                it.title = title + "    " + sc.display
            }
            if let symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(it)
            return it
        }
        add(s.enabled ? L("Turn Veil Off") : L("Turn Veil On"), #selector(toggle), .toggle, symbol: "power")
        menu.addItem(.separator())
        for (i, m) in Mode.allCases.enumerated() {
            let it = add(m.title, #selector(setMode(_:)), symbol: m == .ambient ? "sun.haze" : "moon.haze")
            it.tag = i
            it.state = s.mode == m ? .on : .off
        }
        add(L("Switch Mode"), #selector(switchMode), .switchMode, symbol: "arrow.triangle.2.circlepath")
        menu.addItem(.separator())
        let front = engine.focusedAppPublic
        let name = front?.localizedName ?? L("App")
        let isIgnored = s.ignored.contains(front?.bundleIdentifier ?? "")
        add(isIgnored ? LF("Stop Ignoring %@", name) : LF("Ignore %@", name), #selector(ignoreFrontApp), .ignoreApp, symbol: "eye.slash")
        add(L("Peek"), #selector(peek), symbol: "eye")
        menu.addItem(.separator())
        add(L("Settings…"), #selector(toggleSettings), .toggleControls, symbol: "slider.horizontal.3")
        add(L("Welcome Guide…"), #selector(showWelcomeGuide), symbol: "hand.wave")
        add(L("Check for Updates…"), #selector(checkForUpdates), symbol: "arrow.down.circle")
        let quit = NSMenuItem(title: L("Quit Veil"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    // MARK: URL scheme (veil://…)
    //
    // Mirrors the command set listed under Scripting Commands (ScriptCommands.all):
    //   toggle · on · off · peek · settings · check-updates · quit
    //   mode/{toggle|ambient|deep}            blur/0-100          grain/0-100
    //   grayscale/{on|off|toggle|0-100}       tint/opacity/0-100  tint/color/{preset|RRGGBB}
    //   display/{perScreen|global}            reveal-all/{on|off|toggle}
    //   ignore[/toggle|/<bundle id>]          unignore[/<bundle id>]
    // plus the 1.0 form veil://set?blur=30&tint=blue&… (kept for existing scripts).

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: str), let host = comps.host else { return }
        let path = comps.path.split(separator: "/").map(String.init)
        let first = path.first?.lowercased() ?? ""
        let pct = { (v: String?) -> Double? in v.flatMap(Double.init).map { min(max($0, 0), 100) / 100 } }
        let flag = { (v: String, cur: Bool) -> Bool in v == "toggle" ? !cur : ["on", "true", "1", "yes"].contains(v) }
        switch host.lowercased() {
        case "toggle": toggle()
        case "on": s.enabled = true
        case "off": s.enabled = false
        case "peek": peek()
        case "settings": openSettings()
        case "check-updates": checkForUpdates()
        case "quit": NSApp.terminate(nil)
        case "mode":
            if first == "toggle" { switchMode() } else if let v = Mode(rawValue: first) { s.mode = v }
        case "blur": if let p = pct(path.first) { s.blur = p * 100 }
        case "grain": if let p = pct(path.first) { s.grain = p }
        case "grayscale", "monochrome":
            if let p = pct(path.first) { s.monochrome = p; s.monochromeOn = p > 0 }
            else if !first.isEmpty { s.monochromeOn = flag(first, s.monochromeOn) }
        case "tint":
            if first == "opacity", let p = pct(path.dropFirst().first) { s.tintAmount = p }
            else if first == "color", let v = path.dropFirst().first ?? comps.fragment { setTint(v) }   // also tint/color/#RRGGBB
        case "display": if !first.isEmpty { s.screenMode = first.hasPrefix("g") ? .global : .perScreen }
        case "reveal-all", "appwide": if !first.isEmpty { s.appWide = flag(first, s.appWide) }
        case "ignore":
            if path.isEmpty || first == "toggle" { ignoreFront(onlyAdd: path.isEmpty) }
            else if !s.ignored.contains(path[0]) { s.ignored.append(path[0]) }
        case "unignore":
            if let id = path.first { s.ignored.removeAll { $0 == id } }
            else if let id = engine.focusedAppPublic?.bundleIdentifier { s.ignored.removeAll { $0 == id } }
        case "set":
            for q in comps.queryItems ?? [] { apply(q.name.lowercased(), q.value ?? "") }
        default: NSLog("Veil: unknown URL \(str)")
        }
        engine.tick()
        updateIcon()
    }

    private func setTint(_ v: String) {
        if let p = TintPreset(rawValue: v.lowercased()), p != .custom { s.tintPreset = p }
        else if NSColor(hex: v) != nil { s.tintHex = v.hasPrefix("#") ? v.uppercased() : "#" + v.uppercased(); s.tintPreset = .custom }
        // Like the reference, tint/color only picks the colour; tint/opacity sets how much.
    }

    /// Legacy veil://set?key=value (Veil 1.0/1.1). Values are in the old units.
    private func apply(_ key: String, _ v: String) {
        let num = Double(v)
        let on = ["on", "true", "1", "yes"].contains(v.lowercased())
        switch key {
        case "blur": if let n = num { s.blur = min(max(n * 2.5, 0), 100) }   // 1.x took a radius 0…40
        case "tint": setTint(v)
        case "tintamount": if let n = num { s.tintAmount = min(max(n, 0), 1) }
        case "grain": if let n = num { s.grain = min(max(n, 0), 1) }
        case "monochrome": if let n = num { s.monochrome = min(max(n, 0), 1); s.monochromeOn = n > 0 }
        case "mode": if let m = Mode(rawValue: v.lowercased()) { s.mode = m }
        case "display": s.screenMode = v.lowercased().hasPrefix("g") ? .global : .perScreen
        case "appwide": s.appWide = on
        case "blurstagemanager": s.blurStageManager = on
        case "autohide": s.autoHide = AutoHide(rawValue: v) ?? (on ? .both : .off)
        case "transition", "reveal":
            if let t = RevealEffect(rawValue: v) { s.reveal = t }
            else if v == "cursor" { s.reveal = .fromCursor }
            else if v == "none" { s.reveal = .fade; s.transitionDuration = 0 }   // 1.x "None" = no animation
        case "duration": if let n = num { s.transitionDuration = min(max(n, 0), 1.5) }
        default: NSLog("Veil: unknown setting \(key)")
        }
    }
}

// Developer aid: `Veil --render-onboarding <outDir> <lang> <prefix>` renders the guide pages to PNGs and exits.
if let i = CommandLine.arguments.firstIndex(of: "--render-onboarding"), CommandLine.arguments.count > i + 3 {
    let a = CommandLine.arguments
    OnboardingRender.run(outDir: a[i + 1], lang: a[i + 2], prefix: a[i + 3], pages: VeilGuide.pages, cta: { VeilGuide.ctaTitle })
    exit(0)
}

_ = LanguageStore.shared   // apply the saved language override before any UI is built
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
