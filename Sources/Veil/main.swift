// Veil — blurs and dims every window except the one you're working in.
//
// Files
//   Settings.swift      persisted, observable settings
//   Overlay.swift       per-display overlay window (blur / tint / grain / mask)
//   Engine.swift        focus logic + overlay ordering
//   Input.swift         shake & corner gestures, hotkeys, menu bar/Dock auto-hide
//   SettingsView.swift  the Controls window (SwiftUI)
//   main.swift          app delegate, menu bar item, URL scheme
//
// Permissions: none for the core feature. Auto-hide Menu Bar & Dock asks for
// Automation access to System Events the first time it runs.

import AppKit
import SwiftUI
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let s = Settings.shared
    private var engine: Engine!
    private var gestures: Gestures!
    private let bars = BarHider()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var settingsWindow: NSWindow?
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

    private func updateIcon() {
        let name = !s.enabled ? "circle.dashed" : (engine?.active == true ? "circle.lefthalf.filled" : "circle")
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Veil")
    }

    // MARK: Actions

    @objc func toggle() { s.enabled.toggle(); engine.tick(); updateIcon() }
    @objc func switchMode() { s.mode = s.mode == .ambient ? .deep : .ambient }
    @objc func setMode(_ sender: NSMenuItem) { s.mode = Mode.allCases[sender.tag] }

    @objc func ignoreFrontApp() {
        guard let app = engine.focusedAppPublic, let id = app.bundleIdentifier else { return }
        if s.ignored.contains(id) { s.ignored.removeAll { $0 == id } } else { s.ignored.append(id) }
        engine.tick()
    }

    @objc func checkForUpdates() { updater.checkForUpdates() }

    /// Opens the welcome guide (also shown automatically once, see applicationDidFinishLaunching).
    @objc func showWelcomeGuide() {
        onboarding.show(title: { L("onboarding.veil.window") }, pages: VeilGuide.pages, ctaTitle: { VeilGuide.ctaTitle }) { [weak self] in
            self?.toggleSettings()
        }
    }

    @objc func peek() {
        engine.peeking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.engine.peeking = false }
    }

    @objc func toggleSettings() {
        if let w = settingsWindow, w.isVisible { w.close(); return }
        if settingsWindow == nil {
            let view = SettingsView(reloadHotkeys: { [weak self] in self?.reloadHotkeys() },
                                    ignoreFront: { [weak self] in self?.ignoreFrontApp() },
                                    checkForUpdates: { [weak self] in self?.checkForUpdates() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Veil"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            w.delegate = self
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

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

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: str), let host = comps.host?.lowercased() else { return }
        let path = comps.path.split(separator: "/").map { $0.lowercased() }
        switch host {
        case "toggle": toggle()
        case "on": s.enabled = true; engine.tick()
        case "off": s.enabled = false; engine.tick()
        case "peek": peek()
        case "settings": toggleSettings()
        case "ignore": ignoreFrontApp()
        case "mode":
            if let m = path.first { if m == "toggle" { switchMode() } else if let v = Mode(rawValue: m) { s.mode = v } }
        case "set":
            for q in comps.queryItems ?? [] { apply(q.name.lowercased(), q.value ?? "") }
        default: NSLog("Veil: unknown URL \(str)")
        }
        updateIcon()
    }

    private func apply(_ key: String, _ v: String) {
        let num = Double(v)
        let on = ["on", "true", "1", "yes"].contains(v.lowercased())
        switch key {
        case "blur": if let n = num { s.blur = min(max(n, 0), 60) }
        case "tint":
            if v.hasPrefix("#") || v.count == 6 && NSColor(hex: v) != nil { s.tintHex = v.hasPrefix("#") ? v : "#" + v; s.tintPreset = .custom }
            else if let p = TintPreset(rawValue: v.lowercased()) { s.tintPreset = p }
        case "tintamount": if let n = num { s.tintAmount = min(max(n, 0), 0.8) }
        case "grain": if let n = num { s.grain = min(max(n, 0), 1) }
        case "monochrome": if let n = num { s.monochrome = min(max(n, 0), 1) }
        case "mode": if let m = Mode(rawValue: v.lowercased()) { s.mode = m }
        case "display": s.screenMode = v.lowercased().hasPrefix("g") ? .global : .perScreen
        case "appwide": s.appWide = on
        case "blurstagemanager": s.blurStageManager = on
        case "autohide": s.autoHideBars = on
        case "transition": if let t = Transition(rawValue: v.lowercased()) { s.transition = t }
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
