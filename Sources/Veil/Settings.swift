// All user settings, persisted in UserDefaults and observable by SwiftUI.

import AppKit
import Carbon
import Combine

enum Mode: String, CaseIterable, Identifiable {
    case ambient, deep
    var id: String { rawValue }
    var title: String { self == .ambient ? "Ambient" : "Deep" }
}

enum ScreenMode: String, CaseIterable, Identifiable {
    case perScreen, global
    var id: String { rawValue }
    var title: String { self == .perScreen ? "Per screen" : "Global" }
}

enum Transition: String, CaseIterable, Identifiable {
    case fade, cursor, none
    var id: String { rawValue }
    var title: String { ["fade": "Fade", "cursor": "Cursor reveal", "none": "None"][rawValue]! }
}

/// Modifier that must be held for a shake gesture ("off" disables that gesture).
enum ShakeModifier: String, CaseIterable, Identifiable {
    case none, shift, control, option, command, off
    var id: String { rawValue }
    var title: String {
        ["none": "No modifier", "shift": "⇧ Shift", "control": "⌃ Control", "option": "⌥ Option",
         "command": "⌘ Command", "off": "Off"][rawValue]!
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        default: return []
        }
    }
}

enum MenuClick: String, CaseIterable, Identifiable {
    case settings, toggle
    var id: String { rawValue }
    var title: String { self == .settings ? "Open Settings" : "Toggle Veil" }
}

enum TintPreset: String, CaseIterable, Identifiable {
    case system, graphite, blue, purple, pink, red, orange, yellow, green, custom
    var id: String { rawValue }
    var title: String { self == .system ? "As System" : rawValue.capitalized }
    var color: NSColor? {
        switch self {
        case .system: return .controlAccentColor
        case .graphite: return .systemGray
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .custom: return nil
        }
    }
}

/// A recorded global shortcut (Carbon key code + Carbon modifier mask).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        // Ask the current keyboard layout for the character the key produces.
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            _ = UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(code),
                               UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        let s = String(utf16CodeUnits: chars, count: len).uppercased()
        return s.isEmpty ? "#\(code)" : s
    }

    static func carbonFlags(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static let hyper = UInt32(cmdKey | optionKey | controlKey)
}

enum Action: String, CaseIterable, Identifiable {
    case toggle, switchMode, ignoreApp, toggleControls
    var id: String { rawValue }
    var title: String {
        ["toggle": "Toggle Veil", "switchMode": "Switch Mode", "ignoreApp": "Ignore App",
         "toggleControls": "Toggle Controls"][rawValue]!
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .toggle: return Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: Shortcut.hyper)
        case .switchMode: return Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: Shortcut.hyper)
        case .ignoreApp: return Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: Shortcut.hyper)
        case .toggleControls: return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: Shortcut.hyper)
        }
    }
}

struct AppGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleIDs: [String]
}

/// Settings store. Every property writes through to UserDefaults on change.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private static func load<T>(_ k: String, _ def: T) -> T { UserDefaults.standard.object(forKey: k) as? T ?? def }
    private static func loadJSON<T: Decodable>(_ k: String, _ def: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: k),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }
    private func saveJSON<T: Encodable>(_ v: T, _ k: String) { d.set(try? JSONEncoder().encode(v), forKey: k) }

    @Published var enabled: Bool = load("enabled", true) { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var mode: Mode = Mode(rawValue: load("mode", "ambient")) ?? .ambient { didSet { d.set(mode.rawValue, forKey: "mode") } }
    /// Gaussian blur radius in points; 0 = blur-free mode (tint / grain / monochrome only).
    @Published var blur: Double = load("blur", 22) { didSet { d.set(blur, forKey: "blur") } }
    @Published var tintPreset: TintPreset = TintPreset(rawValue: load("tintPreset", "graphite")) ?? .graphite { didSet { d.set(tintPreset.rawValue, forKey: "tintPreset") } }
    @Published var tintHex: String = load("tintHex", "#3A6EA5") { didSet { d.set(tintHex, forKey: "tintHex") } }
    @Published var tintAmount: Double = load("tintAmount", 0.15) { didSet { d.set(tintAmount, forKey: "tintAmount") } }
    @Published var grain: Double = load("grain", 0.0) { didSet { d.set(grain, forKey: "grain") } }
    @Published var monochrome: Double = load("monochrome", 0.0) { didSet { d.set(monochrome, forKey: "monochrome") } }
    @Published var ignored: [String] = load("ignored", []) { didSet { d.set(ignored, forKey: "ignored") } }
    @Published var groups: [AppGroup] = loadJSON("groups", []) { didSet { saveJSON(groups, "groups") } }
    @Published var appWide: Bool = load("appWide", false) { didSet { d.set(appWide, forKey: "appWide") } }
    @Published var screenMode: ScreenMode = ScreenMode(rawValue: load("screenMode", "perScreen")) ?? .perScreen { didSet { d.set(screenMode.rawValue, forKey: "screenMode") } }
    @Published var autoHideBars: Bool = load("autoHideBars", false) { didSet { d.set(autoHideBars, forKey: "autoHideBars") } }
    @Published var blurStageManager: Bool = load("blurStageManager", false) { didSet { d.set(blurStageManager, forKey: "blurStageManager") } }
    @Published var shakeToggle: ShakeModifier = ShakeModifier(rawValue: load("shakeToggle", "none")) ?? .none { didSet { d.set(shakeToggle.rawValue, forKey: "shakeToggle") } }
    @Published var shakePeek: ShakeModifier = ShakeModifier(rawValue: load("shakePeek", "shift")) ?? .shift { didSet { d.set(shakePeek.rawValue, forKey: "shakePeek") } }
    /// 0 = low sensitivity (hard to trigger) … 1 = high.
    @Published var sensitivity: Double = load("sensitivity", 0.5) { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var cornerPeek: Bool = load("cornerPeek", false) { didSet { d.set(cornerPeek, forKey: "cornerPeek") } }
    @Published var transition: Transition = Transition(rawValue: load("transition", "fade")) ?? .fade { didSet { d.set(transition.rawValue, forKey: "transition") } }
    @Published var menuClick: MenuClick = MenuClick(rawValue: load("menuClick", "toggle")) ?? .toggle { didSet { d.set(menuClick.rawValue, forKey: "menuClick") } }
    @Published var hideWhileDragging: Bool = load("hideWhileDragging", true) { didSet { d.set(hideWhileDragging, forKey: "hideWhileDragging") } }
    @Published var shortcuts: [String: Shortcut] = loadJSON("shortcuts", Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, $0.defaultShortcut) })) { didSet { saveJSON(shortcuts, "shortcuts") } }

    /// The resolved tint colour.
    var tintColor: NSColor {
        tintPreset == .custom ? (NSColor(hex: tintHex) ?? .systemGray) : (tintPreset.color ?? .systemGray)
    }

    func shortcut(_ a: Action) -> Shortcut? { shortcuts[a.rawValue] }

    func resetAll() {
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
        let fresh = Settings()
        enabled = fresh.enabled; mode = fresh.mode; blur = fresh.blur; tintPreset = fresh.tintPreset
        tintHex = fresh.tintHex; tintAmount = fresh.tintAmount; grain = fresh.grain; monochrome = fresh.monochrome
        ignored = []; groups = []; appWide = fresh.appWide; screenMode = fresh.screenMode
        autoHideBars = fresh.autoHideBars; blurStageManager = fresh.blurStageManager
        shakeToggle = fresh.shakeToggle; shakePeek = fresh.shakePeek; sensitivity = fresh.sensitivity
        cornerPeek = fresh.cornerPeek; transition = fresh.transition; menuClick = fresh.menuClick
        hideWhileDragging = fresh.hideWhileDragging; shortcuts = fresh.shortcuts
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
