// The Controls / Settings window (SwiftUI), grouped into tiles like the original.

import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - App helpers

enum Apps {
    static func url(_ bundle: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }
    static func name(_ bundle: String) -> String {
        guard let u = url(bundle) else { return bundle }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    static func icon(_ bundle: String) -> NSImage {
        guard let u = url(bundle) else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
        return NSWorkspace.shared.icon(forFile: u.path)
    }
    /// Multi-select app picker (⌘-click to pick several).
    static func pick(prompt: String) -> [String] {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = prompt
        p.message = L("⌘-click to choose several apps")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return [] }
        return p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

// MARK: - Building blocks

struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var body: some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

struct AppChip: View {
    let bundle: String
    var onRemove: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Apps.icon(bundle)).resizable().frame(width: 18, height: 18)
            Text(Apps.name(bundle)).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Click, then press the new key combination. Esc cancels, the trash button clears.
struct ShortcutRecorder: View {
    let action: Action
    @ObservedObject var s = Settings.shared
    let onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            Button(recording ? L("Press keys…") : (s.shortcut(action)?.display ?? L("Record"))) { start() }
                .frame(minWidth: 110)
            Button { s.shortcuts[action.rawValue] = nil; onChange() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(L("Remove shortcut"))
            Button { s.shortcuts[action.rawValue] = action.defaultShortcut; onChange() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).help(L("Restore default"))
        }
    }

    private func start() {
        recording = true
        HotKeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            defer { stop() }
            if e.keyCode == 53 { return nil }   // Esc cancels
            let mods = Shortcut.carbonFlags(e.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }   // require at least one modifier
            s.shortcuts[action.rawValue] = Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        onChange()
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    let reloadHotkeys: () -> Void
    let ignoreFront: () -> Void
    let checkForUpdates: () -> Void
    /// Observed so every label re-renders the moment the language changes.
    @ObservedObject private var language = LanguageStore.shared
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                lookTile
                focusTile
                screensTile
                gesturesTile
                shortcutsTile
                generalTile
            }
            .padding(16)
            .id(language.effective.rawValue)   // rebuild every tile so ShortcutRecorder etc. re-read their strings
        }
        .frame(width: 460, height: 720)
    }

    private var header: some View {
        HStack {
            Toggle(isOn: $s.enabled) { Text(L("Veil")).font(.title2.bold()) }.toggleStyle(.switch)
            Spacer()
            Button { ignoreFront() } label: {
                Label(LF("Ignore %@", Engine.current?.focusedAppPublic?.localizedName ?? L("app")), systemImage: "eye.slash")
            }
        }
    }

    private var lookTile: some View {
        Tile(title: L("Look"), symbol: "circle.lefthalf.filled") {
            Picker(L("Mode"), selection: $s.mode) { ForEach(Mode.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            SliderRow(title: L("Blur"), value: $s.blur, range: 0...60, format: { $0 < 0.5 ? L("Off") : "\(Int($0))" })
            HStack(spacing: 6) {
                Text(L("Tint")).frame(width: 96, alignment: .leading)
                ForEach(TintPreset.allCases.filter { $0 != .custom }) { p in
                    Circle().fill(Color(nsColor: p.color ?? .gray)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: s.tintPreset == p ? 2 : 0))
                        .overlay(p == .system ? Image(systemName: "a.circle").font(.system(size: 10)).foregroundStyle(.white) : nil)
                        .onTapGesture { s.tintPreset = p }
                        .help(p.title)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: s.tintHex) ?? .gray) },
                    set: { c in
                        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
                        s.tintHex = String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
                        s.tintPreset = .custom
                    }), supportsOpacity: false).labelsHidden().help(L("Custom colour"))
            }
            Text(s.tintPreset == .system ? L("Tint: As System (accent colour)") : s.tintPreset == .custom ? LF("Tint: custom %@", s.tintHex) : LF("Tint: %@", s.tintPreset.title))
                .font(.caption).foregroundStyle(.secondary)
            SliderRow(title: L("Tint amount"), value: $s.tintAmount, range: 0...0.8)
            SliderRow(title: L("Grain"), value: $s.grain)
            SliderRow(title: L("Monochrome"), value: $s.monochrome)
            Picker(L("Transition"), selection: $s.transition) { ForEach(Transition.allCases) { Text($0.title).tag($0) } }
        }
    }

    private var focusTile: some View {
        Tile(title: L("Focus"), symbol: "scope") {
            Toggle(L("App-wide focus — keep all windows of the focused app sharp"), isOn: $s.appWide)
            Divider()
            HStack {
                Text(L("App Groups")).bold()
                Spacer()
                Button(L("New Group…")) {
                    let ids = Apps.pick(prompt: L("Create Group"))
                    if ids.count >= 2 { s.groups.append(AppGroup(bundleIDs: ids)) }
                    else if !ids.isEmpty { NSSound.beep() }
                }
            }
            Text(L("Apps in a group share focus: focus one and the others stay sharp too.")).font(.caption).foregroundStyle(.secondary)
            ForEach(s.groups) { g in
                HStack {
                    FlowChips(bundles: g.bundleIDs) { b in
                        if let i = s.groups.firstIndex(of: g) {
                            s.groups[i].bundleIDs.removeAll { $0 == b }
                            if s.groups[i].bundleIDs.count < 2 { s.groups.remove(at: i) }
                        }
                    }
                    Spacer()
                    Button { if let i = s.groups.firstIndex(of: g) {
                        let add = Apps.pick(prompt: L("Add to Group"))
                        s.groups[i].bundleIDs += add.filter { !s.groups[i].bundleIDs.contains($0) }
                    } } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                    Button { s.groups.removeAll { $0 == g } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            Divider()
            HStack {
                Text(L("Ignored apps")).bold()
                Spacer()
                Button(L("Add…")) { s.ignored += Apps.pick(prompt: L("Ignore")).filter { !s.ignored.contains($0) } }
            }
            Text(L("Veil stays out of the way while these apps are in front.")).font(.caption).foregroundStyle(.secondary)
            FlowChips(bundles: s.ignored) { b in s.ignored.removeAll { $0 == b } }
        }
    }

    private var screensTile: some View {
        Tile(title: L("Screens"), symbol: "display.2") {
            Picker(L("Multi-screen mode"), selection: $s.screenMode) { ForEach(ScreenMode.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            Text(s.screenMode == .perScreen ? L("Each display keeps its own front window sharp.") : L("Only the focused window is sharp; every other display is blurred."))
                .font(.caption).foregroundStyle(.secondary)
            if !Engine.separateSpaces {
                Text(L("“Displays have separate Spaces” is off — Global mode usually works best.")).font(.caption).foregroundStyle(.orange)
            }
            Toggle(L("Auto-hide Menu Bar & Dock while Veil is on"), isOn: $s.autoHideBars)
            Toggle(L("Blur Stage Manager (cover thumbnails with the overlay)"), isOn: $s.blurStageManager)
            Text(Engine.stageManagerOn ? L("Stage Manager detected.") : L("Stage Manager is off.")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var gesturesTile: some View {
        Tile(title: L("Gestures"), symbol: "cursorarrow.motionlines") {
            Picker(L("Shake to toggle"), selection: $s.shakeToggle) { ForEach(ShakeModifier.allCases) { Text($0.title).tag($0) } }
            Picker(L("Hold + shake to peek"), selection: $s.shakePeek) { ForEach(ShakeModifier.allCases) { Text($0.title).tag($0) } }
            HStack {
                Text(L("Sensitivity")).frame(width: 96, alignment: .leading)
                Text(L("Low")).font(.caption).foregroundStyle(.secondary)
                Slider(value: $s.sensitivity, in: 0...1)
                Text(L("High")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L("Corner peek — park the pointer in a screen corner to peek"), isOn: $s.cornerPeek)
            Toggle(L("Hide the overlay while dragging files"), isOn: $s.hideWhileDragging)
        }
    }

    private var shortcutsTile: some View {
        Tile(title: L("Shortcuts"), symbol: "command") {
            ForEach(Action.allCases) { a in ShortcutRecorder(action: a, onChange: reloadHotkeys) }
        }
    }

    private var generalTile: some View {
        Tile(title: L("General"), symbol: "gearshape") {
            Picker(L("Language"), selection: Binding(get: { language.selection }, set: { LanguageStore.shared.set($0) })) {
                ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
            }
            Picker(L("Menu bar left-click"), selection: $s.menuClick) { ForEach(MenuClick.allCases) { Text($0.title).tag($0) } }
            Toggle(L("Launch at login"), isOn: Binding(get: { loginOn }, set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("\(error)") }
                loginOn = SMAppService.mainApp.status == .enabled
            }))
            HStack {
                Button(L("Check for Updates…")) { checkForUpdates() }
                Spacer()
            }
            DisclosureGroup(L("Automation (URL scheme)")) {
                Text(verbatim: """
                open "veil://toggle"      · on · off · peek · settings · ignore
                open "veil://mode/deep"   · ambient · toggle
                open "veil://set?blur=30&tint=blue&tintAmount=0.2"
                open "veil://set?tint=%23FF8800&grain=0.3&monochrome=1"
                open "veil://set?display=global&appwide=on&blurStageManager=off"
                """).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(L("Use from Terminal, AppleScript (open location …) or Shortcuts (Open URL).")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("Reset all settings"), role: .destructive) { s.resetAll(); reloadHotkeys() }
            }
        }
    }
}

/// Wrapping row of app chips.
struct FlowChips: View {
    let bundles: [String]
    let onRemove: (String) -> Void
    var body: some View {
        if bundles.isEmpty {
            Text(L("None")).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(bundles, id: \.self) { b in AppChip(bundle: b) { onRemove(b) } }
            }
        }
    }
}
