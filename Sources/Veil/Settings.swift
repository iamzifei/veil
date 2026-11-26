// All user settings, persisted in UserDefaults and observable by SwiftUI.

import AppKit
import Carbon
import Combine

enum Mode: String, CaseIterable, Identifiable {
    case ambient, deep
    var id: String { rawValue }
    var title: String { self == .ambient ? L("Ambient") : L("Deep") }
}

enum ScreenMode: String, CaseIterable, Identifiable {
    case perScreen, global
    var id: String { rawValue }
    var title: String { self == .perScreen ? L("Per screen") : L("Global") }
}

/// How the veil appears / disappears. Duration comes from `Settings.transitionDuration`.
enum RevealEffect: String, CaseIterable, Identifiable {
    case fade, fromCursor
    var id: String { rawValue }
    var title: String { self == .fade ? L("Fade") : L("From cursor") }
}

/// Which system bars are auto-hidden while the veil is up.
enum AutoHide: String, CaseIterable, Identifiable {
    case off, menuBar, dock, both
    var id: String { rawValue }
    var title: String {
        L(["off": "Off", "menuBar": "Menu bar", "dock": "Dock", "both": "Menu bar & Dock"][rawValue]!)
    }
    var hidesDock: Bool { self == .dock || self == .both }
    var hidesMenuBar: Bool { self == .menuBar || self == .both }
}

/// Modifier that must be held for a shake gesture ("off" disables that gesture).
enum ShakeModifier: String, CaseIterable, Identifiable {
    case none, shift, control, option, command, off
    var id: String { rawValue }
    var title: String {
        L(["none": "No modifier", "shift": "⇧ Shift", "control": "⌃ Control", "option": "⌥ Option",
           "command": "⌘ Command", "off": "Off"][rawValue]!)
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
    var title: String { self == .settings ? L("Open Settings") : L("Toggle Veil") }
}

enum TintPreset: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite, black, custom
    var id: String { rawValue }
    var title: String { self == .system ? L("As System") : L(rawValue.capitalized) }
    /// Preset colours as the reference resolves them: Apple's light-appearance system colours,
    /// fixed sRGB values so the result never depends on the current appearance.
    var color: NSColor? {
        func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
        switch self {
        case .system: return .controlAccentColor
        case .blue: return c(0, 122, 255)
        case .purple: return c(175, 82, 222)
        case .pink: return c(255, 45, 85)
        case .red: return c(255, 59, 48)
        case .orange: return c(255, 149, 0)
        case .yellow: return c(255, 204, 0)
        case .green: return c(52, 199, 89)
        case .graphite: return c(142, 142, 147)
        case .black: return c(13, 13, 13)
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
        L(["toggle": "Toggle Veil", "switchMode": "Switch Mode", "ignoreApp": "Ignore App",
           "toggleControls": "Toggle Controls"][rawValue]!)
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
    /// Deep (default): full-screen veil that also covers the menu bar and Dock.
    /// Ambient: a softer veil that fades out towards the focused window and leaves the bars alone.
    @Published var mode: Mode = Mode(rawValue: load("mode", "deep")) ?? .deep { didSet { d.set(mode.rawValue, forKey: "mode") } }
    /// Blur strength in percent (0…100). The overlay uses a Gaussian of σ = 0.5 pt per percent;
    /// 0 = blur-free mode (tint / grain / monochrome only).
    @Published var blur: Double = load("blurPercent", 100) { didSet { d.set(blur, forKey: "blurPercent") } }
    @Published var tintPreset: TintPreset = TintPreset(rawValue: load("tintPreset", "system")) ?? .system { didSet { d.set(tintPreset.rawValue, forKey: "tintPreset") } }
    @Published var tintHex: String = load("tintHex", "#3A6EA5") { didSet { d.set(tintHex, forKey: "tintHex") } }
    /// Tint opacity, 0…1 (the slider); applied at up to 60 % colour coverage.
    @Published var tintAmount: Double = load("tintAmount2", 0.0) { didSet { d.set(tintAmount, forKey: "tintAmount2") } }
    @Published var grain: Double = load("grain2", 0.5) { didSet { d.set(grain, forKey: "grain2") } }
    @Published var monochromeOn: Bool = load("monochromeOn", false) { didSet { d.set(monochromeOn, forKey: "monochromeOn") } }
    /// How much colour monochrome drains (0…1); set from the URL scheme, the toggle uses it as-is.
    @Published var monochrome: Double = load("monochromeAmount", 1.0) { didSet { d.set(monochrome, forKey: "monochromeAmount") } }
    @Published var ignored: [String] = load("ignored2", Settings.migratedIgnored) { didSet { d.set(ignored, forKey: "ignored2") } }
    @Published var groups: [AppGroup] = loadJSON("groups", []) { didSet { saveJSON(groups, "groups") } }
    @Published var appWide: Bool = load("appWide", false) { didSet { d.set(appWide, forKey: "appWide") } }
    @Published var screenMode: ScreenMode = ScreenMode(rawValue: load("screenMode", "perScreen")) ?? .perScreen { didSet { d.set(screenMode.rawValue, forKey: "screenMode") } }
    @Published var autoHide: AutoHide = AutoHide(rawValue: load("autoHide", (load("autoHideBars", false) ? "both" : "off"))) ?? .off { didSet { d.set(autoHide.rawValue, forKey: "autoHide") } }
    @Published var blurStageManager: Bool = load("blurStageManager", false) { didSet { d.set(blurStageManager, forKey: "blurStageManager") } }
    /// Master switch for both shake gestures.
    @Published var shakeEnabled: Bool = load("shakeEnabled", true) { didSet { d.set(shakeEnabled, forKey: "shakeEnabled") } }
    @Published var shakeToggle: ShakeModifier = ShakeModifier(rawValue: load("shakeToggle", "none")) ?? .none { didSet { d.set(shakeToggle.rawValue, forKey: "shakeToggle") } }
    @Published var shakePeek: ShakeModifier = ShakeModifier(rawValue: load("shakePeek", "shift")) ?? .shift { didSet { d.set(shakePeek.rawValue, forKey: "shakePeek") } }
    /// 0 = low sensitivity (hard to trigger) … 1 = high.
    @Published var sensitivity: Double = load("sensitivity", 0.5) { didSet { d.set(sensitivity, forKey: "sensitivity") } }
    @Published var cornerPeek: Bool = load("cornerPeek", false) { didSet { d.set(cornerPeek, forKey: "cornerPeek") } }
    @Published var reveal: RevealEffect = RevealEffect(rawValue: load("revealEffect", "fade")) ?? .fade { didSet { d.set(reveal.rawValue, forKey: "revealEffect") } }
    /// Show / hide / mode-change animation length in seconds (0…1.5; 0.75 by default).
    @Published var transitionDuration: Double = load("transitionDuration2", 0.75) { didSet { d.set(transitionDuration, forKey: "transitionDuration2") } }
    @Published var menuClick: MenuClick = MenuClick(rawValue: load("menuClick2", "settings")) ?? .settings { didSet { d.set(menuClick.rawValue, forKey: "menuClick2") } }
    @Published var hideWhileDragging: Bool = load("hideWhileDragging", true) { didSet { d.set(hideWhileDragging, forKey: "hideWhileDragging") } }
    @Published var shortcuts: [String: Shortcut] = loadJSON("shortcuts", Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, $0.defaultShortcut) })) { didSet { saveJSON(shortcuts, "shortcuts") } }
    /// The welcome card at the top of the settings panel ("Got it!" hides it, "Show Intro" brings it back).
    @Published var welcomeDismissed: Bool = load("welcomeDismissed", false) { didSet { d.set(welcomeDismissed, forKey: "welcomeDismissed") } }
    /// "More settings" expanded in the panel.
    @Published var moreSettings: Bool = load("moreSettings", false) { didSet { d.set(moreSettings, forKey: "moreSettings") } }

    /// Apps that skip the veil out of the box: colour pickers need to see the real screen,
    /// and Finder is usually just a passing click on the desktop.
    static let defaultIgnored = ["com.apple.DigitalColorMeter", "com.apple.finder"]

    /// First run of 1.2: keep a 1.x user's own ignore list (key "ignored"); new users get the defaults.
    static var migratedIgnored: [String] {
        guard let old = UserDefaults.standard.array(forKey: "ignored") as? [String], !old.isEmpty else { return defaultIgnored }
        return old
    }

    /// Monochrome strength actually applied (0 when the toggle is off).
    var effectiveMonochrome: Double { monochromeOn ? monochrome : 0 }

    /// The resolved tint colour.
    var tintColor: NSColor {
        if tintPreset == .custom { return NSColor(hex: tintHex) ?? .systemGray }
        return (tintPreset.color ?? .systemGray).usingColorSpace(.sRGB) ?? .systemGray
    }

    func shortcut(_ a: Action) -> Shortcut? { shortcuts[a.rawValue] }

    func resetAll() {
        if let id = Bundle.main.bundleIdentifier {
            // Keep the language choice and onboarding state; everything else goes back to defaults.
            let keep = ["AppleLanguages", Onboarding.defaultsKey, "welcomeDismissed"].reduce(into: [String: Any]()) { $0[$1] = d.object(forKey: $1) }
            d.removePersistentDomain(forName: id)
            keep.forEach { d.set($0.value, forKey: $0.key) }
        }
        let f = Settings()
        enabled = f.enabled; mode = f.mode; blur = f.blur; tintPreset = f.tintPreset; tintHex = f.tintHex
        tintAmount = f.tintAmount; grain = f.grain; monochromeOn = f.monochromeOn; monochrome = f.monochrome
        ignored = f.ignored; groups = []; appWide = f.appWide; screenMode = f.screenMode; autoHide = f.autoHide
        blurStageManager = f.blurStageManager; shakeEnabled = f.shakeEnabled; shakeToggle = f.shakeToggle
        shakePeek = f.shakePeek; sensitivity = f.sensitivity; cornerPeek = f.cornerPeek; reveal = f.reveal
        transitionDuration = f.transitionDuration; menuClick = f.menuClick; hideWhileDragging = f.hideWhileDragging
        shortcuts = f.shortcuts; moreSettings = f.moreSettings
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
