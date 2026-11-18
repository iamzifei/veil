// Content of Veil's welcome guide (six pages). Text is localised via
// Localizable.strings ("onboarding.veil.*"); images are in Resources/Onboarding.

import AppKit
import SwiftUI

enum VeilGuide {
    static var ctaTitle: String { L("Open Settings") }

    static func pages() -> [OnboardingPage] {
        func key(_ n: Int, _ part: String) -> String { "onboarding.veil.p\(n).\(part)" }
        func page(_ n: Int, _ art: AnyView) -> OnboardingPage {
            OnboardingPage(id: n, title: L(key(n, "title")), body: L(key(n, "body")), art: art)
        }
        return [
            page(1, AnyView(ShotImage(name: "hero"))),
            page(2, AnyView(focusArt)),
            page(3, AnyView(menuBarArt)),
            page(4, AnyView(looksArt)),
            page(5, AnyView(gesturesArt)),
            page(6, AnyView(shortcutsArt)),
        ]
    }

    // Page 2: before / after — the sharp window moves when you click another one (existing stills).
    private static var focusArt: some View {
        HStack(spacing: 14) {
            ForEach(["hero", "tint"], id: \.self) { img in
                ShotImage(name: img)
                    .frame(width: 236, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                if img == "hero" {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Page 3: menu-bar icon. The menu is drawn from the app's real menu strings.
    private static var menuBarArt: some View {
        ZStack(alignment: .topTrailing) {
            ShotImage(name: "tint").frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 13))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.55)))
                    Image(systemName: "wifi").font(.system(size: 12))
                    Image(systemName: "battery.75percent").font(.system(size: 14))
                    Text("9:41").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.black.opacity(0.8))
                .padding(.horizontal, 14).frame(height: 26)
                .background(Color.white.opacity(0.45))
                MenuMock(rows: [
                    .item(L("Turn Veil Off"), trailing: shortcut(.toggle), symbol: "power"),
                    .separator,
                    .item(Mode.ambient.title, symbol: "sun.haze", checked: true),
                    .item(Mode.deep.title, symbol: "moon.haze"),
                    .item(L("Switch Mode"), trailing: shortcut(.switchMode), symbol: "arrow.triangle.2.circlepath"),
                    .separator,
                    .item(LF("Ignore %@", L("onboarding.veil.p3.app")), trailing: shortcut(.ignoreApp), symbol: "eye.slash"),
                    .item(L("Peek"), symbol: "eye"),
                    .separator,
                    .item(L("Settings…"), trailing: shortcut(.toggleControls), symbol: "slider.horizontal.3"),
                ], width: 300)
                .padding(.top, 4).padding(.trailing, 10).frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 10) {
                Tag(text: L("onboarding.veil.p3.tag1"))
                Tag(text: L("onboarding.veil.p3.tag2"))
            }
            .padding(.leading, 18).padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private static func shortcut(_ a: Action) -> String { Settings.shared.shortcut(a)?.display ?? "" }

    // Page 4: three looks (existing marketing stills).
    private static var looksArt: some View {
        HStack(spacing: 10) {
            ForEach([("tint", "onboarding.veil.p4.cap1"), ("deep", "onboarding.veil.p4.cap2"), ("mono", "onboarding.veil.p4.cap3")], id: \.0) { img, cap in
                VStack(spacing: 6) {
                    ShotImage(name: img)
                        .frame(width: 170, height: 230).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    Text(L(cap)).font(.system(size: 12.5, weight: .medium))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Page 5: gestures, over a Deep-mode still.
    private static var gesturesArt: some View {
        ZStack {
            ShotImage(name: "deep").frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 18) {
                Image(systemName: "cursorarrow.motionlines").font(.system(size: 54, weight: .regular))
                    .foregroundStyle(.white).shadow(radius: 6)
                VStack(spacing: 8) {
                    Tag(text: L("onboarding.veil.p5.tag1"))
                    Tag(text: L("onboarding.veil.p5.tag2"))
                    Tag(text: L("onboarding.veil.p5.tag3"))
                }
            }
        }
    }

    // Page 6: the four global shortcuts, using whatever the user has configured.
    private static var shortcutsArt: some View {
        ZStack {
            ShotImage(name: "mono").blur(radius: 6).frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Action.allCases) { a in
                    HStack {
                        Text(a.title).font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 24)
                        KeyCaps(keys: Array(Settings.shared.shortcut(a)?.display ?? "").map(String.init), size: 28)
                    }
                }
            }
            .padding(22).frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.14)))
        }
    }
}
