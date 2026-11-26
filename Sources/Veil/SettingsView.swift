// The settings panel (SwiftUI): a column of frosted-glass tiles in the style of
// Control Center. It lives in SettingsPanel (a borderless panel that slides in from
// the right edge of the screen); this file is only the content.
//
// Layout, top to bottom
//   Welcome card (until "Got it!")
//   [Ignore <front app> +]  [⏻]          — pill + power button
//   [● Mode            Deep ⋮]           — tap to switch Deep / Ambient
//   Blur / Tint / Grain card             — tick sliders; the colour wheel opens swatches in place
//   App Groups card
//   More settings ▾ (everything below is hidden until expanded)
//   Behaviour card · Gestures · Shortcuts · Monochrome / Transition / Reveal · Ignored apps · About · Credits

import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import Carbon

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
    static func pick(prompt: String, message: String) -> [String] {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = prompt
        p.message = message
        SettingsPanel.shared.childOpen = true
        defer { SettingsPanel.shared.childOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return [] }
        return p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}

// MARK: - Theme

enum Glass {
    static let tileRadius: CGFloat = 32
    static let pillHeight: CGFloat = 62
    static let text = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.14)
    static let divider = Color.white.opacity(0.09)
}

/// Accent used by sliders and switches: the tint colour, or the system accent when
/// the tint is too dark or too grey to read as a highlight.
func panelAccent(_ s: Settings) -> Color {
    let c = (s.tintPreset == .system ? NSColor.controlAccentColor : s.tintColor).usingColorSpace(.sRGB) ?? .systemBlue
    let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
    if lum < 0.12 || sat < 0.08 { return Color(nsColor: .controlAccentColor) }
    return Color(nsColor: c)
}

/// Behind-window blur for a tile: a CABackdropLayer (same private class the overlay uses)
/// clipped to the tile's corner radius. Measured on the reference: a tile over pure black
/// reads 32/255 and over a light area ≈ 0.53 × the blurred background + 32, i.e. a neutral
/// grey (68) wash at 47 % over the blur — no colour cast.
struct FrostedBackground: NSViewRepresentable {
    var radius: CGFloat
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let root = v.layer!
        root.cornerRadius = radius
        root.cornerCurve = .continuous
        root.masksToBounds = true
        let b = PrivateCA.backdropClass?.init() ?? CALayer()
        b.setValue(true, forKey: "windowServerAware")
        if let f = PrivateCA.filter("gaussianBlur") {
            f.setValue(30.0, forKey: "inputRadius")
            f.setValue(true, forKey: "inputNormalizeEdges")
            b.filters = [f]
        }
        b.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        b.frame = root.bounds
        root.addSublayer(b)
        let wash = CALayer()
        wash.backgroundColor = NSColor(srgbRed: 68 / 255, green: 68 / 255, blue: 68 / 255, alpha: 0.47).cgColor
        wash.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wash.frame = root.bounds
        root.addSublayer(wash)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { v.layer?.cornerRadius = radius }
}

/// The frosted tile look: blur + a faint white wash + a top-lit hairline.
struct GlassTile: ViewModifier {
    var radius: CGFloat = Glass.tileRadius
    var fill: Color? = nil
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    FrostedBackground(radius: radius)
                    if let fill { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill) }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .white.opacity(0.14)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

extension View {
    func glass(radius: CGFloat = Glass.tileRadius, fill: Color? = nil) -> some View { modifier(GlassTile(radius: radius, fill: fill)) }
}

/// A small capsule button ("More settings", "Check Updates", "Got it!").
struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Glass.text.opacity(configuration.isPressed ? 0.6 : 0.92))
            .padding(.horizontal, 14).frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(prominent ? 0.24 : 0.14)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Whole-tile press feedback: a quick squash, like Control Center tiles.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// White-thumb switch; the track takes the accent colour when on.
struct GlassToggleStyle: ToggleStyle {
    var accent: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? accent : Color.white.opacity(0.2)).frame(width: 46, height: 26)
                Capsule().fill(.white).frame(width: 28, height: 22).padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// Slider with a pill thumb and a row of tick dots under the track.
struct TickSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var ticks = 11
    var accent: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, thumbW: CGFloat = 20
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = (w - thumbW) * min(max(t, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 4)
                Capsule().fill(accent).frame(width: x + thumbW / 2, height: 4)
                HStack(spacing: 0) {
                    ForEach(0..<ticks, id: \.self) { i in
                        Circle().fill(Color.white.opacity(0.32)).frame(width: 2.2, height: 2.2)
                        if i < ticks - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 8).offset(y: 9)
                Capsule().fill(.white).frame(width: thumbW, height: 16)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                    .offset(x: x)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let p = min(max((v.location.x - thumbW / 2) / max(w - thumbW, 1), 0), 1)
                value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 30)
    }
}

/// "Off ⌄" style pop-up menu used for enum settings.
struct ChipMenu<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    var body: some View {
        Menu {
            ForEach(options) { o in
                Button { selection = o } label: {
                    if o == selection { Label(title(o), systemImage: "checkmark") } else { Text(title(o)) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title(selection))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 13))
            .foregroundStyle(Glass.text.opacity(0.85))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Two stacked dots — the "more options" glyph on the Mode and Multi-screen rows.
struct DotPair: View {
    var body: some View {
        VStack(spacing: 3) { Circle().frame(width: 4, height: 4); Circle().frame(width: 4, height: 4) }
            .foregroundStyle(Glass.text.opacity(0.85))
    }
}

struct RowTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
            if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Glass.secondary) }
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    /// Observed so every label re-renders the moment the language changes.
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject private var live = PanelState.shared
    let reloadHotkeys: () -> Void
    let checkForUpdates: () -> Void
    let toggleIgnoreFront: () -> Void

    @State private var tintExpanded = false
    @State private var gesturesOpen = false
    @State private var shortcutsOpen = false
    @State private var scriptsOpen = false
    @State private var expandedGroup: UUID?
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false
    @State private var copied: String?

    private var accent: Color { panelAccent(s) }
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if !s.welcomeDismissed { welcomeCard.padding(.bottom, 38).transition(.move(edge: .top).combined(with: .opacity)) }
                HStack(spacing: 14) { ignorePill; powerButton }
                modePill.padding(.top, 14)
                lookCard.padding(.top, 38)
                groupsCard.padding(.top, 40)
                Button(s.moreSettings ? L("Less settings") : L("More settings")) {
                    withAnimation(spring) { s.moreSettings.toggle() }
                }
                .buttonStyle(ChipButtonStyle())
                .padding(.top, 38)
                if s.moreSettings {
                    VStack(spacing: 0) {
                        behaviourCard.padding(.top, 36)
                        gesturesSection.padding(.top, 39)
                        shortcutsSection.padding(.top, 15)
                        effectsCard.padding(.top, 39)
                        ignoredCard.padding(.top, 38)
                        aboutCard.padding(.top, 38)
                        creditsCard.padding(.top, 38)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.leading, 40).padding(.trailing, 16).padding(.top, 57).padding(.bottom, 40)
            .id(language.effective.rawValue)
        }
        .frame(width: SettingsPanel.width)
        .environment(\.colorScheme, .dark)
        .tint(accent)
        .animation(spring, value: s.welcomeDismissed)
    }

    // MARK: Welcome

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                VeilMark().frame(width: 46, height: 46)
                Spacer()
            }
            .padding(.top, 8)
            Text(L("welcome.title"))
                .font(.system(size: 32, weight: .regular, design: .serif).italic())
                .lineSpacing(0)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            ForEach(["welcome.p1", "welcome.p2", "welcome.p3", "welcome.p4"], id: \.self) { k in
                Text(L(k)).font(.system(size: 15)).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { withAnimation(spring) { s.welcomeDismissed = true } } label: {
                Text(L("Got it!")).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 36)
                    .background(Capsule().fill(Color.white.opacity(0.2))).foregroundStyle(.white)
            }
            .buttonStyle(TileButtonStyle())
            .padding(.top, 32)
        }
        .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 24)
        .glass(fill: accent.opacity(0.62))
    }

    // MARK: Top row

    private var ignorePill: some View {
        let app = live.frontApp
        let bundle = app?.bundleIdentifier ?? ""
        let ignored = s.ignored.contains(bundle)
        return Button { toggleIgnoreFront() } label: {
            HStack(spacing: 12) {
                Group {
                    if let icon = app?.icon { Image(nsImage: icon).resizable() }
                    else {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Glass.secondary, style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                            .padding(4)
                    }
                }
                .frame(width: 34, height: 34)
                RowTitle(title: ignored ? L("Ignored") : L("Ignore"), subtitle: app?.localizedName ?? L("Current App"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: ignored ? "minus" : "plus").font(.system(size: 17, weight: .light)).foregroundStyle(Glass.secondary)
            }
            .padding(.leading, 16).padding(.trailing, 18)
            .frame(height: Glass.pillHeight)
            .glass(radius: Glass.pillHeight / 2)
        }
        .buttonStyle(TileButtonStyle())
        .disabled(app == nil)
        .help(L("Veil stays out of the way while these apps are in front."))
    }

    private var powerButton: some View {
        Button { withAnimation(spring) { s.enabled.toggle() } } label: {
            Image(systemName: "power").font(.system(size: 21, weight: .medium))
                .foregroundStyle(s.enabled ? accent : Glass.text.opacity(0.85))
                .frame(width: 80, height: Glass.pillHeight)
                .glass(radius: Glass.pillHeight / 2, fill: s.enabled ? .white : nil)
        }
        .buttonStyle(TileButtonStyle())
        .help(s.enabled ? L("Turn Veil Off") : L("Turn Veil On"))
    }

    private var modePill: some View {
        Button { withAnimation(spring) { s.mode = s.mode == .deep ? .ambient : .deep } } label: {
            HStack(spacing: 14) {
                ModeDot(mode: s.mode).frame(width: 34, height: 34)
                Text(L("Mode")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                Spacer()
                Text(s.mode.title).font(.system(size: 13)).foregroundStyle(Glass.text.opacity(0.85))
                    .contentTransition(.opacity)
                DotPair().padding(.leading, 4)
            }
            .padding(.horizontal, 18)
            .frame(height: Glass.pillHeight)
            .glass(radius: Glass.pillHeight / 2)
        }
        .buttonStyle(TileButtonStyle())
        .help(s.mode == .deep ? L("mode.deep.help") : L("mode.ambient.help"))
    }

    // MARK: Look

    private var lookCard: some View {
        VStack(spacing: 0) {
            sliderRow(icon: AnyView(Image(systemName: "drop.fill").font(.system(size: 17))), title: L("Blur"),
                      value: $s.blur, range: 0...100)
            if tintExpanded { tintSwatches.transition(.opacity.combined(with: .scale(scale: 0.96))) }
            else {
                sliderRow(icon: AnyView(Button { withAnimation(spring) { tintExpanded = true } } label: { ColorWheel(preset: s.tintPreset, hex: s.tintHex) }
                    .buttonStyle(TileButtonStyle()).help(L("Choose tint colour"))),
                          title: L("Tint"), value: $s.tintAmount, range: 0...1)
            }
            sliderRow(icon: AnyView(Image(systemName: "water.waves").font(.system(size: 15))), title: L("Grain"),
                      value: $s.grain, range: 0...1)
        }
        .padding(.vertical, 14)
        .glass()
    }

    private func sliderRow(icon: AnyView, title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 0) {
            icon.foregroundStyle(Glass.text).frame(width: 30)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                .frame(width: 70, alignment: .leading).padding(.leading, 14)
            TickSlider(value: value, range: range, accent: accent)
        }
        .padding(.horizontal, 18).frame(height: 56)
    }

    private var tintSwatches: some View {
        VStack(spacing: 10) {
            HStack {
                Button { withAnimation(spring) { tintExpanded = false } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                }
                .buttonStyle(TileButtonStyle())
                Spacer()
                Text(s.tintPreset == .custom ? s.tintHex : s.tintPreset.title).font(.system(size: 10.5)).foregroundStyle(Glass.secondary)
            }
            HStack(spacing: 4) {
                ForEach(TintPreset.allCases.filter { $0 != .custom }) { p in
                    Button { withAnimation(spring) { s.tintPreset = p; if s.tintAmount < 0.05 { s.tintAmount = 0.3 } } } label: {
                        Group {
                            if p == .system { ColorWheel(preset: .system, hex: s.tintHex, size: 20) }
                            else { Circle().fill(Color(nsColor: p.color ?? .gray)).frame(width: 20, height: 20) }
                        }
                        .overlay(Circle().strokeBorder(.white, lineWidth: s.tintPreset == p ? 2 : 0).padding(-3))
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(TileButtonStyle())
                    .help(p.title)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: s.tintHex) ?? .gray) },
                    set: { c in
                        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
                        s.tintHex = String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
                        s.tintPreset = .custom
                    }), supportsOpacity: false)
                    .labelsHidden().frame(width: 22).help(L("Custom colour"))
            }
        }
        .padding(.horizontal, 18).frame(height: 72)
    }

    // MARK: App Groups

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("App Groups")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                Spacer()
                CircleIconButton(symbol: "plus") {
                    let ids = Apps.pick(prompt: L("Create Group"), message: L("Choose Apps for Group"))
                    if ids.count >= 2 { withAnimation(spring) { s.groups.append(AppGroup(bundleIDs: ids)) } }
                    else if !ids.isEmpty { NSSound.beep() }
                }
            }
            .padding(.bottom, s.groups.isEmpty ? 26 : 8)
            if s.groups.isEmpty {
                Text(L("Pair apps that stay focused together")).font(.system(size: 10.5)).foregroundStyle(Glass.secondary)
            }
            ForEach(s.groups) { g in groupRow(g) }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 36)
        .glass()
    }

    private func groupRow(_ g: AppGroup) -> some View {
        let open = expandedGroup == g.id
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Glass.divider)
            Button { withAnimation(spring) { expandedGroup = open ? nil : g.id } } label: {
                HStack(spacing: 10) {
                    StackedIcons(bundles: g.bundleIDs)
                    Text(g.bundleIDs.map(Apps.name).joined(separator: ", ")).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Glass.text).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Glass.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
            }
            .buttonStyle(TileButtonStyle())
            if open {
                ForEach(g.bundleIDs, id: \.self) { b in
                    AppRow(bundle: b) {
                        withAnimation(spring) {
                            if let i = s.groups.firstIndex(of: g) {
                                s.groups[i].bundleIDs.removeAll { $0 == b }
                                if s.groups[i].bundleIDs.count < 2 { s.groups.remove(at: i) }
                            }
                        }
                    }
                }
                HStack {
                    Button(L("Add Apps…")) {
                        if let i = s.groups.firstIndex(of: g) {
                            let add = Apps.pick(prompt: L("Add to Group"), message: L("Add Apps to Group"))
                            s.groups[i].bundleIDs += add.filter { !s.groups[i].bundleIDs.contains($0) }
                        }
                    }
                    Spacer()
                    Button(L("Delete Group")) { withAnimation(spring) { s.groups.removeAll { $0 == g } } }
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(.top, 4)
    }

    // MARK: More settings — behaviour

    private var behaviourCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $s.appWide) { RowTitle(title: L("App-wide focus"), subtitle: L("Show all windows of the same app")) }
                .toggleStyle(GlassToggleStyle(accent: accent)).cardRow()
            divider
            Button { withAnimation(spring) { s.screenMode = s.screenMode == .perScreen ? .global : .perScreen } } label: {
                HStack {
                    RowTitle(title: L("Multi-screen mode"),
                             subtitle: Engine.separateSpaces ? nil : L("“Displays have separate Spaces” is off"))
                    Spacer()
                    Text(s.screenMode.title).font(.system(size: 13)).foregroundStyle(Glass.text.opacity(0.85))
                    DotPair().padding(.leading, 6)
                }
            }
            .buttonStyle(TileButtonStyle()).cardRow()
            .help(s.screenMode == .perScreen ? L("Each display keeps its own front window sharp.") : L("Only the focused window is sharp; every other display is veiled."))
            divider
            HStack {
                RowTitle(title: L("Auto-hide"), subtitle: s.autoHide == .off ? L("Menu bar and Dock while Veil is on") : L("Asks for Automation access once"))
                Spacer()
                ChipMenu(options: AutoHide.allCases, selection: $s.autoHide) { $0.title }
            }
            .cardRow()
            divider
            Toggle(isOn: $s.blurStageManager) { RowTitle(title: L("Blur Stage Manager"), subtitle: L("Cover thumbnails with the overlay")) }
                .toggleStyle(GlassToggleStyle(accent: accent)).cardRow()
            divider
            Toggle(isOn: $s.hideWhileDragging) { RowTitle(title: L("Hide while dragging"), subtitle: L("Drop files onto blurred windows")) }
                .toggleStyle(GlassToggleStyle(accent: accent)).cardRow()
            divider
            HStack {
                RowTitle(title: L("Menu bar icon"))
                Spacer()
                ChipMenu(options: MenuClick.allCases, selection: $s.menuClick) { $0.title }
            }
            .cardRow()
        }
        .padding(.vertical, 6)
        .glass()
    }

    private var divider: some View { Rectangle().fill(Glass.divider).frame(height: 1).padding(.horizontal, 22) }

    // MARK: Gestures

    @ViewBuilder private var gesturesSection: some View {
        if gesturesOpen {
            VStack(alignment: .leading, spacing: 0) {
                subpageHeader(L("Gestures")) { gesturesOpen = false }
                Toggle(isOn: $s.shakeEnabled) { Text(L("Shake gestures")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text) }
                    .toggleStyle(GlassToggleStyle(accent: accent)).padding(.vertical, 6)
                Group {
                    labelled(L("Shake to toggle")) { ChipMenu(options: ShakeModifier.allCases, selection: $s.shakeToggle) { $0.title } }
                    labelled(L("Hold + Shake to peek")) { ChipMenu(options: ShakeModifier.allCases, selection: $s.shakePeek) { $0.title } }
                }
                .opacity(s.shakeEnabled ? 1 : 0.4).disabled(!s.shakeEnabled)
                Rectangle().fill(Glass.divider).frame(height: 1).padding(.vertical, 10)
                Text(L("Alternative")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                Toggle(isOn: $s.cornerPeek) { Text(L("Peek at corners")).font(.system(size: 13)).foregroundStyle(Glass.text.opacity(0.85)) }
                    .toggleStyle(GlassToggleStyle(accent: accent)).padding(.vertical, 6)
                Rectangle().fill(Glass.divider).frame(height: 1).padding(.vertical, 10)
                Text(L("Sensitivity")).font(.system(size: 13)).foregroundStyle(Glass.text.opacity(0.85))
                HStack(spacing: 8) {
                    Text(L("Low")).font(.system(size: 10.5)).foregroundStyle(Glass.secondary)
                    TickSlider(value: $s.sensitivity, accent: accent)
                    Text(L("High")).font(.system(size: 10.5)).foregroundStyle(Glass.secondary)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .glass()
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            collapsedPill(symbol: "computermouse.fill", title: L("Gestures")) { gesturesOpen = true }
        }
    }

    private func labelled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(t).font(.system(size: 13)).foregroundStyle(Glass.text.opacity(0.85)); Spacer(); c() }.padding(.vertical, 5)
    }

    private func subpageHeader(_ title: String, back: @escaping () -> Void) -> some View {
        HStack {
            Button { withAnimation(spring) { back() } } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text).frame(width: 24, height: 24)
            }
            .buttonStyle(TileButtonStyle())
            Spacer()
            Text(title).font(.system(size: 10.5)).foregroundStyle(Glass.secondary)
        }
        .padding(.bottom, 8)
    }

    private func collapsedPill(symbol: String, title: String, open: @escaping () -> Void) -> some View {
        Button { withAnimation(spring) { open() } } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Glass.text).frame(width: 30)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Glass.secondary)
            }
            .padding(.horizontal, 22).frame(height: Glass.pillHeight)
            .glass(radius: Glass.pillHeight / 2)
        }
        .buttonStyle(TileButtonStyle())
    }

    // MARK: Shortcuts

    @ViewBuilder private var shortcutsSection: some View {
        if shortcutsOpen {
            VStack(alignment: .leading, spacing: 4) {
                subpageHeader(L("Shortcuts")) { shortcutsOpen = false }
                ForEach(Action.allCases) { a in ShortcutRow(action: a, onChange: reloadHotkeys) }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .glass()
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            collapsedPill(symbol: "command", title: L("Shortcuts")) { shortcutsOpen = true }
        }
    }

    // MARK: Monochrome / Transition / Reveal

    private var effectsCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $s.monochromeOn) {
                HStack(spacing: 14) {
                    Image(systemName: "camera.filters").font(.system(size: 16)).foregroundStyle(Glass.text).frame(width: 30)
                    Text(L("Monochrome")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                }
            }
            .toggleStyle(GlassToggleStyle(accent: accent)).padding(.horizontal, 18).frame(height: 62)
            divider
            sliderRow(icon: AnyView(Image(systemName: "timer").font(.system(size: 16))), title: L("Transition"),
                      value: $s.transitionDuration, range: 0...1.5)
                .help(String(format: "%.2f s", s.transitionDuration))
            divider
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(Glass.text).frame(width: 30)
                Text(L("Reveal effect")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                Spacer()
                ChipMenu(options: RevealEffect.allCases, selection: $s.reveal) { $0.title }
            }
            .padding(.horizontal, 18).frame(height: 62)
        }
        .padding(.vertical, 4)
        .glass()
    }

    // MARK: Ignored apps

    private var ignoredCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RowTitle(title: L("Ignored apps"))
                Spacer()
                CircleIconButton(symbol: "plus") {
                    let add = Apps.pick(prompt: L("Ignore"), message: L("Apps that skip the veil entirely"))
                    withAnimation(spring) { s.ignored += add.filter { !s.ignored.contains($0) } }
                }
            }
            .padding(.bottom, 6)
            if s.ignored.isEmpty {
                Text(L("Apps that skip the veil entirely")).font(.system(size: 10.5)).foregroundStyle(Glass.secondary).padding(.vertical, 6)
            }
            ForEach(Array(s.ignored.enumerated()), id: \.element) { i, b in
                if i > 0 { Rectangle().fill(Glass.divider).frame(height: 1) }
                AppRow(bundle: b) { withAnimation(spring) { s.ignored.removeAll { $0 == b } } }.padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .glass()
    }

    // MARK: About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("Veil").font(.system(size: 13, weight: .semibold))
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                            .font(.system(size: 13)).foregroundStyle(Glass.secondary)
                    }
                    .foregroundStyle(Glass.text)
                    Text(LF("Update checked: %@", UpdateClock.describe())).font(.system(size: 10.5)).foregroundStyle(Glass.secondary)
                }
                Spacer()
                Button(L("Check Updates")) { UpdateClock.stamp(); checkForUpdates() }.buttonStyle(ChipButtonStyle())
            }
            .padding(.vertical, 12)
            divider.padding(.horizontal, -22)
            HStack {
                RowTitle(title: L("Language"))
                Spacer()
                ChipMenu(options: AppLanguage.allCases, selection: Binding(get: { language.selection }, set: { LanguageStore.shared.set($0) })) { $0.nativeName }
            }
            .padding(.vertical, 14)
            divider.padding(.horizontal, -22)
            Toggle(isOn: Binding(get: { loginOn }, set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("\(error)") }
                loginOn = SMAppService.mainApp.status == .enabled
            })) { RowTitle(title: L("Launch at login")) }
                .toggleStyle(GlassToggleStyle(accent: accent)).padding(.vertical, 14)
            divider.padding(.horizontal, -22)
            Button { withAnimation(spring) { scriptsOpen.toggle() } } label: {
                HStack {
                    RowTitle(title: L("Scripting Commands"))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Glass.secondary)
                        .rotationEffect(.degrees(scriptsOpen ? 180 : 0))
                }
                .padding(.vertical, 14)
            }
            .buttonStyle(TileButtonStyle())
            if scriptsOpen { scriptList.transition(.opacity) }
            HStack {
                Button(L("Show Intro")) { withAnimation(spring) { s.welcomeDismissed = false }; SettingsPanel.shared.scrollToTop() }
                Spacer()
                Button(L("Reset All Settings")) { confirmReset = true }
            }
            .buttonStyle(ChipButtonStyle())
            .padding(.top, 10)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .glass()
        .alert(L("Reset All Settings"), isPresented: $confirmReset) {
            Button(L("Reset"), role: .destructive) { s.resetAll(); reloadHotkeys() }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("This will reset all settings to their default values.")) }
    }

    private var scriptList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Click a command to copy it. Run it in Terminal, Shortcuts or AppleScript."))
                .font(.system(size: 10.5)).foregroundStyle(Glass.secondary).padding(.bottom, 6)
            ForEach(ScriptCommands.all, id: \.url) { c in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("open \"\(c.url)\"", forType: .string)
                    withAnimation { copied = c.url }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("open \"\(c.url)\"").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Glass.text)
                        Text(copied == c.url ? L("Copied") : L(c.help)).font(.system(size: 10)).foregroundStyle(copied == c.url ? accent : Glass.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(copied == c.url ? 0.08 : 0)))
                }
                .buttonStyle(TileButtonStyle())
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Credits

    private var creditsCard: some View {
        VStack(spacing: 12) {
            VeilMark().frame(width: 30, height: 30)
            (Text(L("Made with care by ")) + Text("James").underline())
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                .onTapGesture { NSWorkspace.shared.open(URL(string: "https://jamesai.dev")!) }
            HStack(spacing: 8) {
                Button(L("More Mac apps")) { NSWorkspace.shared.open(URL(string: "https://jamesai.dev/#apps")!) }
                Button(L("Ideas / Issues?")) { NSWorkspace.shared.open(URL(string: "https://github.com/iamzifei/veil/issues")!) }
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            Text("© 2026 James").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(Sheen(accent: accent).clipShape(RoundedRectangle(cornerRadius: Glass.tileRadius, style: .continuous)))
        .glass(fill: .clear)
    }
}

extension View {
    /// Standard padding for a row inside a card.
    func cardRow() -> some View { padding(.horizontal, 22).padding(.vertical, 16) }
}

// MARK: - Small pieces

/// Live data the panel shows (the front app). Refreshed by SettingsPanel while visible.
final class PanelState: ObservableObject {
    static let shared = PanelState()
    @Published var frontApp: NSRunningApplication?
}

/// Glowing dot for the Mode pill: solid + halo for Deep, soft radial fade for Ambient.
struct ModeDot: View {
    let mode: Mode
    var body: some View {
        ZStack {
            if mode == .deep {
                Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .white.opacity(0.9), radius: 6)
            } else {
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0.75), .white.opacity(0.15)], center: .center, startRadius: 1, endRadius: 12))
                    .frame(width: 24, height: 24)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: mode)
    }
}

/// Colour wheel (the "As System" tint), or the chosen tint as a dot.
struct ColorWheel: View {
    let preset: TintPreset
    let hex: String
    var size: CGFloat = 28
    var body: some View {
        Group {
            if preset == .system {
                Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
            } else {
                Circle().fill(Color(nsColor: preset == .custom ? (NSColor(hex: hex) ?? .gray) : (preset.color ?? .gray)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
    }
}

struct CircleIconButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(Glass.text)
                .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(TileButtonStyle())
    }
}

/// Overlapping app icons for an App Group row.
struct StackedIcons: View {
    let bundles: [String]
    var body: some View {
        HStack(spacing: -8) {
            ForEach(bundles.prefix(3), id: \.self) { b in
                Image(nsImage: Apps.icon(b)).resizable().frame(width: 24, height: 24)
            }
        }
    }
}

struct AppRow: View {
    let bundle: String
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Apps.icon(bundle)).resizable().frame(width: 26, height: 26)
            Text(Apps.name(bundle)).font(.system(size: 13, weight: .medium)).foregroundStyle(Glass.text).lineLimit(1)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus").font(.system(size: 13, weight: .medium)).foregroundStyle(Glass.secondary).frame(width: 24, height: 24)
            }
            .buttonStyle(TileButtonStyle())
            .help(L("Remove"))
        }
    }
}

/// Veil's mark: a sharp dot inside a softly veiled ring (original artwork, drawn in code).
struct VeilMark: View {
    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.0), .white.opacity(0.35)], center: .center, startRadius: w * 0.2, endRadius: w * 0.5))
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: max(1.5, w * 0.06))
                Circle().fill(.white).frame(width: w * 0.32, height: w * 0.32)
            }
            .frame(width: w, height: w)
        }
    }
}

/// Accent gradient with a slow diagonal light sweep (the credits card).
struct Sheen: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
            GeometryReader { g in
                ZStack {
                    LinearGradient(colors: [accent, accent.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .rotationEffect(.degrees(20))
                        .offset(x: (CGFloat(t) * 2.2 - 1.1) * g.size.width)
                        .blendMode(.plusLighter)
                }
            }
        }
    }
}

/// One shortcut: title, key caps, edit (record) and remove.
struct ShortcutRow: View {
    let action: Action
    @ObservedObject var s = Settings.shared
    let onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(action.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Glass.text)
                HStack(spacing: 4) {
                    if recording {
                        Text(L("Press keys…")).font(.system(size: 11)).foregroundStyle(Glass.secondary).frame(height: 24)
                    } else if let sc = s.shortcut(action) {
                        ForEach(Array(sc.glyphs.enumerated()), id: \.offset) { _, g in
                            Text(g).font(.system(size: 11, weight: .medium)).foregroundStyle(Glass.text.opacity(0.85))
                                .frame(minWidth: 24, minHeight: 24).padding(.horizontal, g.count > 1 ? 4 : 0)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                    } else {
                        Text(L("Not set")).font(.system(size: 11)).foregroundStyle(Glass.secondary).frame(height: 24)
                    }
                }
            }
            Spacer()
            Button { recording ? stop() : start() } label: {
                Image(systemName: recording ? "xmark" : "pencil").font(.system(size: 12)).foregroundStyle(Glass.secondary).frame(width: 24, height: 24)
            }
            .buttonStyle(TileButtonStyle()).help(L("Record"))
            Button { s.shortcuts[action.rawValue] = nil; onChange() } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Glass.secondary).frame(width: 24, height: 24)
            }
            .buttonStyle(TileButtonStyle()).help(L("Remove shortcut"))
        }
        .padding(.vertical, 8)
        .onReceive(NotificationCenter.default.publisher(for: .veilCancelShortcutRecording)) { _ in
            if recording { stop() }
        }
    }

    private func start() {
        recording = true
        HotKeys.suspend()
        SettingsPanel.shared.recordingShortcut = true
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
        SettingsPanel.shared.recordingShortcut = false
        onChange()
    }
}

/// When the last manual update check happened, for "Update checked: …".
enum UpdateClock {
    static func stamp() { UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck") }
    static func describe() -> String {
        guard let d = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date else { return L("Never") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: LanguageStore.shared.effective == .en ? "en" : LanguageStore.shared.effective.rawValue)
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// The veil:// commands listed under "Scripting Commands" (handled in main.swift).
enum ScriptCommands {
    struct Cmd { let url: String; let help: String }
    static let all: [Cmd] = [
        Cmd(url: "veil://toggle", help: "Toggle the veil"),
        Cmd(url: "veil://on", help: "Turn the veil on"),
        Cmd(url: "veil://off", help: "Turn the veil off"),
        Cmd(url: "veil://mode/toggle", help: "Switch between Deep and Ambient"),
        Cmd(url: "veil://mode/ambient", help: "Ambient mode (gradient)"),
        Cmd(url: "veil://mode/deep", help: "Deep mode (full screen)"),
        Cmd(url: "veil://blur/50", help: "Set blur (0–100)"),
        Cmd(url: "veil://grayscale/toggle", help: "Toggle monochrome (also on / off)"),
        Cmd(url: "veil://grayscale/50", help: "Set monochrome strength (0–100)"),
        Cmd(url: "veil://tint/opacity/50", help: "Set tint opacity (0–100)"),
        Cmd(url: "veil://tint/color/blue", help: "Tint preset: system, blue, purple, pink, red, orange, yellow, green, graphite, black"),
        Cmd(url: "veil://tint/color/FF6B6B", help: "Tint to a custom hex colour (RRGGBB)"),
        Cmd(url: "veil://grain/50", help: "Set grain (0–100)"),
        Cmd(url: "veil://display/perScreen", help: "Per-screen display mode (or global)"),
        Cmd(url: "veil://reveal-all/toggle", help: "Toggle app-wide focus (also on / off)"),
        Cmd(url: "veil://ignore/toggle", help: "Ignore / include the current app"),
        Cmd(url: "veil://ignore/com.apple.Safari", help: "Ignore an app by bundle id (unignore/… to include)"),
        Cmd(url: "veil://peek", help: "Peek for two seconds"),
        Cmd(url: "veil://settings", help: "Open the settings panel"),
        Cmd(url: "veil://check-updates", help: "Check for updates"),
        Cmd(url: "veil://quit", help: "Quit Veil"),
    ]
}

extension Shortcut {
    /// Key caps for display: one per modifier, then the key.
    var glyphs: [String] {
        var g: [String] = []
        if modifiers & UInt32(controlKey) != 0 { g.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { g.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { g.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { g.append("⌘") }
        g.append(Shortcut.keyName(keyCode))
        return g
    }
}
