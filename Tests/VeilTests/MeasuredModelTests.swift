// Tests for the numbers that were measured off the reference app (see the 1.2 plan file):
// grain model, blur calibration, tint presets, auto-hide options and shortcut key caps.
import XCTest
import AppKit
import Carbon
@testable import Veil

final class MeasuredModelTests: XCTestCase {

    /// Grain: black-or-white pixels with opacity uniform in [0, 0.1 × grain] — so the mean
    /// opacity is 0.05 × grain and about half the pixels are white.
    func testGrainOpacityAndColourSplit() throws {
        let img = try XCTUnwrap(Grain.image(amount: 1.0))
        let rep = NSBitmapImageRep(cgImage: img)
        var alphaSum = 0.0, white = 0, n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                var px = [Int](repeating: 0, count: 4)
                rep.getPixel(&px, atX: x, y: y)
                alphaSum += Double(px[3]) / 255
                if px[0] > 0 { white += 1 }
                n += 1
            }
        }
        XCTAssertEqual(alphaSum / Double(n), 0.05, accuracy: 0.005)
        XCTAssertEqual(Double(white) / Double(n), 0.5, accuracy: 0.05)
    }

    func testGrainScalesWithAmountAndVanishesAtZero() throws {
        let half = try XCTUnwrap(Grain.image(amount: 0.5))
        let rep = NSBitmapImageRep(cgImage: half)
        var maxA = 0
        for x in 0..<rep.pixelsWide { var px = [Int](repeating: 0, count: 4); rep.getPixel(&px, atX: x, y: 0); maxA = max(maxA, px[3]) }
        XCTAssertLessThanOrEqual(maxA, 13)   // 0.05 × 255 ≈ 12.75
        let zero = NSBitmapImageRep(cgImage: try XCTUnwrap(Grain.image(amount: 0)))
        var px = [Int](repeating: 0, count: 4); zero.getPixel(&px, atX: 10, y: 10)
        XCTAssertEqual(px[3], 0)
    }

    /// inputRadius 51 gave σ = 50 pt on screen; σ is 0.5 pt per blur percent.
    func testBlurCalibration() {
        XCTAssertEqual(OverlayWindow.inputRadius(sigma: 50), 51, accuracy: 0.001)
        XCTAssertEqual(OverlayWindow.inputRadius(sigma: 0.5 * 50), 25.5, accuracy: 0.001)
    }

    /// Presets resolve in the light appearance (systemBlue = #007AFF), like the reference.
    func testTintPresetsUseLightAppearance() {
        let s = Settings.shared
        let saved = (s.tintPreset, s.tintHex)
        defer { s.tintPreset = saved.0; s.tintHex = saved.1 }
        s.tintPreset = .blue
        let c = s.tintColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(c.redComponent, 0, accuracy: 0.02)
        XCTAssertEqual(c.greenComponent, 122.0 / 255, accuracy: 0.02)
        XCTAssertEqual(c.blueComponent, 1, accuracy: 0.02)
        s.tintPreset = .custom; s.tintHex = "#FF6B6B"
        XCTAssertEqual(s.tintColor.usingColorSpace(.sRGB)!.redComponent, 1, accuracy: 0.01)
    }

    func testTintPresetOrderMatchesPanel() {
        XCTAssertEqual(TintPreset.allCases.map(\.rawValue),
                       ["system", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite", "black", "custom"])
    }

    func testAutoHideOptions() {
        XCTAssertFalse(AutoHide.off.hidesDock || AutoHide.off.hidesMenuBar)
        XCTAssertTrue(AutoHide.menuBar.hidesMenuBar && !AutoHide.menuBar.hidesDock)
        XCTAssertTrue(AutoHide.dock.hidesDock && !AutoHide.dock.hidesMenuBar)
        XCTAssertTrue(AutoHide.both.hidesDock && AutoHide.both.hidesMenuBar)
    }

    func testShortcutKeyCaps() {
        let sc = Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: Shortcut.hyper)
        XCTAssertEqual(Array(sc.glyphs.prefix(3)), ["⌃", "⌥", "⌘"])
        XCTAssertEqual(sc.glyphs.count, 4)
    }

    func testMonochromeOnlyWhenToggled() {
        let s = Settings.shared
        let saved = (s.monochromeOn, s.monochrome)
        defer { s.monochromeOn = saved.0; s.monochrome = saved.1 }
        s.monochrome = 0.5; s.monochromeOn = false
        XCTAssertEqual(s.effectiveMonochrome, 0)
        s.monochromeOn = true
        XCTAssertEqual(s.effectiveMonochrome, 0.5)
    }
}

final class PanelMeasurementTests: XCTestCase {
    /// Edge fade measured on the reference: 0 at the edge → 1 at 56 pt, never decreasing.
    func testEdgeFadeRamp() {
        let r = EdgeFade.ramp
        XCTAssertEqual(r.first?.a, 0); XCTAssertEqual(r.last?.a, 1); XCTAssertEqual(r.last?.pt, 56)
        for (a, b) in zip(r, r.dropFirst()) { XCTAssertLessThan(a.pt, b.pt); XCTAssertLessThanOrEqual(a.a, b.a) }
    }
}
