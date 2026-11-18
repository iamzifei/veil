// First-run welcome guide: window, page container and small reusable art pieces.
//
// The guide is shown once per `Onboarding.currentVersion` (so upgrading users see
// it once, and bumping the version re-shows it after a major change) and can be
// reopened from the menu ("Welcome Guide…"). The page content lives in
// OnboardingPages.swift; screenshots are bundled in Contents/Resources/Onboarding.

import AppKit
import SwiftUI
import Combine

// MARK: - State

enum Onboarding {
    /// Bump when the guide changes enough that everyone should see it again.
    static let currentVersion = 1
    static let defaultsKey = "onboardingSeenVersion"

    static var shouldShow: Bool { UserDefaults.standard.integer(forKey: defaultsKey) < currentVersion }
    static func markSeen() { UserDefaults.standard.set(currentVersion, forKey: defaultsKey) }
}

// MARK: - Model

struct OnboardingPage: Identifiable {
    let id: Int
    let title: String
    let body: String
    let art: AnyView
    /// Optional extra control under the text (e.g. a button that opens System Settings).
    var extra: AnyView? = nil
}

// MARK: - Buttons

/// Pure-SwiftUI button look (also renders correctly offscreen, where AppKit-backed
/// button styles turn into placeholders).
struct GuideButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 18).frame(minWidth: 72, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? Color.accentColor : Color.primary.opacity(0.09)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Page container

struct OnboardingView: View {
    static let size = CGSize(width: 620, height: 580)

    /// Built on demand so the text follows the language picker immediately.
    let makePages: () -> [OnboardingPage]
    let makeCTA: () -> String
    let onCTA: () -> Void
    let onClose: () -> Void
    @State var index = 0
    @ObservedObject private var language = LanguageStore.shared

    private var isLast: Bool { index == makePages().count - 1 }

    var body: some View {
        let pages = makePages(), ctaTitle = makeCTA()
        let page = pages[index]
        VStack(spacing: 0) {
            HStack {
                Spacer()
                LanguagePicker()
            }
            .padding(.top, 14)

            page.art
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 8) {
                Text(page.title).font(.title2.bold())
                Text(page.body)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let extra = page.extra { extra.padding(.top, 2) }
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .padding(.top, 20)

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == index ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LF("onboarding.page", index + 1, pages.count))
            .padding(.bottom, 14)

            HStack {
                Button(L("onboarding.back")) { withAnimation(.easeInOut(duration: 0.15)) { index -= 1 } }
                    .buttonStyle(GuideButtonStyle())
                    .opacity(index == 0 ? 0 : 1).disabled(index == 0)
                Spacer()
                if isLast {
                    Button(L("onboarding.done")) { onClose() }.buttonStyle(GuideButtonStyle())
                    Button(ctaTitle) { onCTA() }.buttonStyle(GuideButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button(L("onboarding.next")) { withAnimation(.easeInOut(duration: 0.15)) { index += 1 } }
                        .buttonStyle(GuideButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.bottom, 22)

            // Esc closes the guide.
            Button("") { onClose() }.buttonStyle(.plain).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .padding(.horizontal, 24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Compact English / 简体中文 / 繁體中文 switch (pure SwiftUI so it also renders offscreen).
struct LanguagePicker: View {
    @ObservedObject private var language = LanguageStore.shared
    private let options: [AppLanguage] = [.en, .zhHans, .zhHant]
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 6)
            ForEach(options) { opt in
                let on = language.effective == opt
                Button { LanguageStore.shared.set(opt) } label: {
                    Text(opt.nativeName)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Window controller

final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var languageSub: AnyCancellable?

    /// Shows the guide (or brings the open one to the front).
    func show(title: @escaping () -> String, pages: @escaping () -> [OnboardingPage], ctaTitle: @escaping () -> String,
              onCTA: @escaping () -> Void) {
        if let w = window {
            bringToFront(w)
            return
        }
        let view = OnboardingView(makePages: pages, makeCTA: ctaTitle,
                                  onCTA: { [weak self] in self?.window?.close(); onCTA() },
                                  onClose: { [weak self] in self?.window?.close() })
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title()
        languageSub = LanguageStore.shared.$selection.dropFirst().sink { [weak w] _ in
            // $selection fires before the value lands; hop one turn so L() sees the new bundle.
            DispatchQueue.main.async { w?.title = title() }
        }
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.setContentSize(OnboardingView.size)
        w.center()
        w.delegate = self
        window = w
        bringToFront(w)
    }

    /// These are menu-bar-only (LSUIElement) apps, so activate explicitly and order the
    /// window front even if another app is active — otherwise the guide can open behind it.
    private func bringToFront(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    /// Closing by any route (Done, Esc, red button) counts as "seen".
    func windowWillClose(_ notification: Notification) {
        Onboarding.markSeen()
        languageSub = nil
        window = nil
    }
}

// MARK: - Art pieces

/// A bundled screenshot (Contents/Resources/Onboarding/<name>.jpg), cropped to fill.
struct ShotImage: View {
    let name: String
    var body: some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Onboarding"),
           let img = NSImage(contentsOf: url) {
            // GeometryReader so the cropped image fills the proposed size instead of
            // growing the layout (a .fill image reports its full, uncropped size).
            GeometryReader { geo in
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
        } else {
            Color.gray.opacity(0.2)
        }
    }
}

/// Row of keyboard keycaps, e.g. KeyCaps(["⌃", "⌥", "P"]).
struct KeyCaps: View {
    let keys: [String]
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.22)))
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1.5)
            }
        }
    }
}

/// Small rounded label drawn on top of screenshots.
struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

/// A drawn picture of a menu-bar drop-down menu. It is built from the same
/// localised strings the real NSMenu uses (there is no way to snapshot an NSMenu
/// offscreen), so it shows the menu's real structure rather than a screenshot.
struct MenuMock: View {
    enum Row {
        case item(String, trailing: String = "", symbol: String? = nil, checked: Bool = false)
        case separator
        case slider(title: String, left: String, right: String, value: Double)
    }
    let rows: [Row]
    var width: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case let .item(title, trailing, symbol, checked):
                    HStack(spacing: 6) {
                        Text(checked ? "✓" : "").frame(width: 12)
                        if let symbol { Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary) }
                        Text(title)
                        Spacer(minLength: 8)
                        Text(trailing).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 24)
                case .separator:
                    Divider().padding(.vertical, 4).padding(.horizontal, 6)
                case let .slider(title, left, right, value):
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.18)).frame(height: 4)
                            Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.primary.opacity(0.3)))
                                .frame(width: 14, height: 14)
                                .offset(x: (width - 40) * value - 7)
                        }
                        HStack { Text(left); Spacer(); Text(right) }
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.16)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

// MARK: - Offscreen rendering (developer aid)

/// `Veil --render-onboarding <outDir> <lang> <prefix>` renders every guide page
/// to PNG with ImageRenderer (no window, no screen capture) and exits.
enum OnboardingRender {
    static func run(outDir: String, lang: String, prefix: String, pages makePages: @escaping () -> [OnboardingPage], cta makeCTA: @escaping () -> String) {
        _ = NSApplication.shared
        // Select the language without persisting it (this must never touch real preferences).
        LanguageStore.shared.set(AppLanguage(rawValue: lang) ?? .en, persist: false)
        MainActor.assumeIsolated {
            for i in makePages().indices {
                let view = OnboardingView(makePages: makePages, makeCTA: makeCTA, onCTA: {}, onClose: {}, index: i)
                let r = ImageRenderer(content: view)
                r.scale = 2
                guard let cg = r.cgImage else { NSLog("render failed for page \(i + 1)"); continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(prefix)-\(lang)-\(i + 1).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
    }
}
