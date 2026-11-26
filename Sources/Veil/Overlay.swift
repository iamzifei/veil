// One overlay window per display, ordered directly below the focused window.
//
// Every number in this file was measured off the reference app with a test scene
// (flat white / black / grey backgrounds, 200 pt stripes, colour bars) and 60 fps
// screen recordings — see /Users/james/Dev/mac-clones/docs/plans/2026-11-27-v1.2-monocle-3.5.1-parity.md.
//
// Layer tree inside the window:
//   content            opacity = the show / hide cross-fade
//     ├─ backdrop      CABackdropLayer: WindowServer-side Gaussian blur (+ saturation for
//     │                monochrome) of whatever is BEHIND this window
//     ├─ tint          solid colour, alpha = 0.75 × tint slider
//     └─ grain         static black/white noise, opacity up to 0.1 × grain
//   content.mask = maskRoot
//     ├─ modeMask      Deep: solid. Ambient: vertical gradient, 0 at the top edge of the
//     │                screen → 1 at half height → 1 at the bottom (fixed to the screen).
//     │                modeMask.mask = shape (screen minus holes for other sharp windows)
//     └─ closing       one per window that just LOST focus: the same gradient clipped to
//                      that window, fading in so the old window blurs over 0.75 s while
//                      the new one is sharp at once.
//   maskRoot.mask = reveal (only during a From-cursor reveal): radial gradient around the
//                   pointer, solid to 35 % of its radius, clear at 100 %.
//
// CABackdropLayer / CAFilter are private Core Animation classes (what NSVisualEffectView
// uses internally); using them directly is what gives an exact Gaussian radius.

import AppKit
import QuartzCore

enum PrivateCA {
    static let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
    static let filterClass = NSClassFromString("CAFilter") as? NSObject.Type

    static func filter(_ type: String) -> NSObject? {
        guard let cls = filterClass else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        return cls.perform(sel, with: type)?.takeUnretainedValue() as? NSObject
    }
}

/// Measured animation curves.
enum VeilTiming {
    /// Show: ease-out quad (fast start, soft landing).
    static let show = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)   // ease-out quad
    /// Hide: linear.
    static let hide = CAMediaTimingFunction(name: .linear)
    /// Deep ⇄ Ambient: ease-in-out.
    static let mode = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
    /// Previous focus window blurring back in: ease-out.
    static let focus = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
    /// From-cursor reveal: radius grows ease-out, shrinks ease-out-quad.
    static let cursorGrow = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
    static let cursorShrink = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
}

/// Static film grain, measured off the reference: every device pixel is either black or
/// white, laid over the blur with a random opacity in [0, 0.1 × grain] (normal "over"
/// blending). On mid-grey that is ±≈12/255 at full grain; it never animates.
enum Grain {
    static let tilePx = 512
    private static let seeds: [(white: Bool, a: Float)] = (0..<(tilePx * tilePx)).map { _ in (Bool.random(), Float.random(in: 0...1)) }

    static func image(amount: Double) -> CGImage? {
        let n = tilePx
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let maxA = Float(0.1 * amount)
        for i in 0..<(n * n) {
            let s = seeds[i]
            let a = s.a * maxA
            let v = UInt8((s.white ? a : 0) * 255)          // premultiplied
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }
}

final class OverlayWindow: NSWindow {
    let content = CALayer()
    let backdrop: CALayer
    let tint = CALayer()
    let grain = CALayer()
    private let maskRoot = CALayer()
    private let modeMask = CAGradientLayer()
    private let shape = CAShapeLayer()
    private let reveal = CAGradientLayer()
    private var holes: [CGPath] = []
    private var grainAmp: Double = -1
    private var currentMode: Mode?
    let displayID: CGDirectDisplayID
    /// Last "shown" target, so a reveal can be reversed mid-flight.
    private(set) var targetShown = false
    private var hideToken = 0

    init(screen: NSScreen) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        backdrop = PrivateCA.backdropClass?.init() ?? CALayer()
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true          // clicks fall through to whatever is underneath
        isReleasedWhenClosed = false
        level = .normal                    // same level as app windows, so it can slot between them
        // .transient: Mission Control / App Exposé hide this window.
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        alphaValue = 0

        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        contentView = v
        let root = v.layer!
        let scale = screen.backingScaleFactor
        content.frame = root.bounds
        content.opacity = 0
        root.addSublayer(content)
        for l in [backdrop, tint, grain] {
            l.frame = content.bounds
            content.addSublayer(l)
        }
        backdrop.setValue(true, forKey: "windowServerAware")   // sample other apps' windows
        backdrop.setValue(1.0, forKey: "scale")
        grain.contentsScale = scale

        maskRoot.frame = content.bounds
        modeMask.frame = content.bounds
        modeMask.startPoint = CGPoint(x: 0.5, y: 1)     // layer space is y-up: 1 = top edge
        modeMask.endPoint = CGPoint(x: 0.5, y: 0)
        modeMask.locations = [0, 0.5, 1]
        shape.frame = content.bounds
        shape.fillRule = .evenOdd
        modeMask.mask = shape
        maskRoot.addSublayer(modeMask)
        content.mask = maskRoot

        reveal.type = .radial
        reveal.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        reveal.locations = [0, 0.35, 1]
        reveal.startPoint = CGPoint(x: 0.5, y: 0.5)
        reveal.endPoint = CGPoint(x: 1, y: 1)

        updateMask()
        applyStyle(animated: false)
    }

    // MARK: Look

    /// CAFilter gaussianBlur inputRadius for a Gaussian of standard deviation σ points.
    /// The reference blurs with σ = 0.5 pt per slider percent (σ 50 pt at 100 %).
    static func inputRadius(sigma: Double) -> Double { sigma * BlurCalibration.radiusPerSigma }

    /// Push the current look into the layers. `animated`: Deep ⇄ Ambient eases over the
    /// transition duration; everything else applies at once (as in the reference).
    func applyStyle(animated: Bool = true) {
        let s = Settings.shared
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var filters: [NSObject] = []
        let sigma = s.blur * 0.5
        if sigma > 0.05, let f = PrivateCA.filter("gaussianBlur") {
            f.setValue(Self.inputRadius(sigma: sigma), forKey: "inputRadius")
            f.setValue(true, forKey: "inputNormalizeEdges")
            filters.append(f)
        }
        let mono = s.effectiveMonochrome
        if mono > 0.001, let f = PrivateCA.filter("colorSaturate") {
            f.setValue(1 - mono, forKey: "inputAmount")
            filters.append(f)
        }
        backdrop.filters = filters

        let c = s.tintColor.usingColorSpace(.sRGB) ?? .gray
        tint.backgroundColor = c.withAlphaComponent(CGFloat(0.75 * s.tintAmount)).cgColor

        if abs(s.grain - grainAmp) > 0.0005 {
            grainAmp = s.grain
            let sz = NSSize(width: CGFloat(Grain.tilePx) / contentsScale, height: CGFloat(Grain.tilePx) / contentsScale)
            grain.backgroundColor = Grain.image(amount: s.grain).map { NSColor(patternImage: NSImage(cgImage: $0, size: sz)).cgColor }
        }
        grain.isHidden = s.grain < 0.005
        CATransaction.commit()
        setMode(s.mode, animated: animated)
    }

    private var contentsScale: CGFloat { screen?.backingScaleFactor ?? 2 }

    private static func modeColors(_ m: Mode) -> [CGColor] {
        m == .deep ? [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
                   : [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
    }

    private func setMode(_ m: Mode, animated: Bool) {
        guard m != currentMode else { return }
        let from = (modeMask.presentation()?.colors) ?? modeMask.colors
        currentMode = m
        let to = Self.modeColors(m)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        modeMask.colors = to
        closing.forEach { ($0.layer as? CAGradientLayer)?.colors = to }
        CATransaction.commit()
        guard animated, alphaValue > 0, Settings.shared.transitionDuration > 0.01, let from else { return }
        let a = CABasicAnimation(keyPath: "colors")
        a.fromValue = from; a.toValue = to
        a.duration = Settings.shared.transitionDuration
        a.timingFunction = VeilTiming.mode
        modeMask.add(a, forKey: "veil.mode")
    }

    // MARK: Holes

    /// Regions (window-local, y-up) that must stay unveiled: sharp windows stacked BELOW
    /// the overlay (App Groups, app-wide focus, the Stage Manager strip).
    func setHoles(_ paths: [CGPath]) {
        guard paths != holes else { return }
        holes = paths
        updateMask()
    }

    private func updateMask() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var path = CGPath(rect: content.bounds, transform: nil)
        let allHoles = holes + closing.map(\.cut)
        if !allHoles.isEmpty {
            let cut = CGMutablePath()
            allHoles.forEach { cut.addPath($0) }
            path = path.subtracting(cut.union(CGPath(rect: .zero, transform: nil)))
        }
        shape.path = path
        CATransaction.commit()
    }

    // MARK: Focus change

    /// Windows that just lost focus: their veil patch and the cut-out it fills while it fades in.
    private var closing: [(layer: CALayer, id: Int, cut: CGPath)] = []

    /// The window `rect` (window-local) just lost focus. Until now it sat above the overlay
    /// (sharp); from now on it is below it. Instead of snapping to blurred, cover it with a
    /// patch of veil that fades in.
    func blurIn(previous rect: CGRect, id: Int) {
        guard alphaValue > 0, content.opacity > 0.01, Settings.shared.transitionDuration > 0.01 else { return }
        closing.removeAll { c in if c.id == id { c.layer.removeFromSuperlayer(); return true }; return false }
        let r = rect.intersection(content.bounds)
        guard !r.isNull, r.width > 1 else { return }
        // The patch is the full-screen mode gradient (so Ambient stays correct), clipped to the old window.
        let g = CAGradientLayer()
        g.frame = content.bounds
        g.startPoint = modeMask.startPoint; g.endPoint = modeMask.endPoint
        g.locations = modeMask.locations; g.colors = modeMask.colors
        let clip = CAShapeLayer()
        clip.frame = content.bounds
        clip.path = CGPath(roundedRect: r, cornerWidth: Engine.holeRadius, cornerHeight: Engine.holeRadius, transform: nil)
        g.mask = clip
        // Cut the old window out of the main mask while the patch fades in (kept in `closing`,
        // so any other mask update in the meantime keeps the cut).
        let hole = CGPath(roundedRect: r, cornerWidth: Engine.holeRadius, cornerHeight: Engine.holeRadius, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        maskRoot.addSublayer(g)
        g.opacity = 1
        CATransaction.commit()
        closing.append((g, id, hole))
        updateMask()
        let d = Settings.shared.transitionDuration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak g] in
            guard let self, let g else { return }
            self.closing.removeAll { $0.layer === g }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            g.removeFromSuperlayer()
            CATransaction.commit()
            self.updateMask()
        }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1
        a.duration = d; a.timingFunction = VeilTiming.focus
        g.add(a, forKey: "veil.focus")
        CATransaction.commit()
    }

    // MARK: Show / hide

    /// Show or hide with the configured reveal effect. `cursor` is in screen coordinates.
    /// `animated: false` snaps (first layout, rebuilds).
    func setShown(_ shown: Bool, cursor: CGPoint, animated: Bool = true) {
        targetShown = shown
        hideToken += 1
        let token = hideToken
        let s = Settings.shared
        let d = s.transitionDuration
        if shown { alphaValue = 1 }

        guard animated, d > 0.01 else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.removeAllAnimations(); maskRoot.mask = nil
            content.opacity = shown ? 1 : 0
            CATransaction.commit()
            if !shown { alphaValue = 0 }
            return
        }

        switch s.reveal {
        case .fade:
            maskRoot.mask = nil
            let from = Double(content.presentation()?.opacity ?? (shown ? 0 : 1))
            let to: Double = shown ? 1 : 0
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, token == self.hideToken, !shown else { return }
                self.alphaValue = 0
            }
            let op = CABasicAnimation(keyPath: "opacity")
            op.fromValue = from; op.toValue = to
            // Remaining fraction keeps the speed constant when a fade reverses mid-flight.
            op.duration = d * max(0.05, abs(to - from))
            op.timingFunction = shown ? VeilTiming.show : VeilTiming.hide
            CATransaction.setDisableActions(true)
            content.opacity = Float(to)
            content.add(op, forKey: "veil.opacity")
            CATransaction.commit()

        case .fromCursor:
            // A soft disc of veil grows from (or shrinks into) the pointer.
            content.removeAnimation(forKey: "veil.opacity")
            let c = CGPoint(x: cursor.x - frame.minX, y: cursor.y - frame.minY)
            let R = 1.2 * hypot(frame.width, frame.height)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.opacity = 1
            reveal.bounds = CGRect(x: 0, y: 0, width: R * 2, height: R * 2)
            reveal.position = c
            reveal.transform = CATransform3DMakeScale(shown ? 1 : 0.0001, shown ? 1 : 0.0001, 1)
            maskRoot.mask = reveal
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, token == self.hideToken else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.maskRoot.mask = nil
                if !shown { self.content.opacity = 0 }
                CATransaction.commit()
                if !shown { self.alphaValue = 0 }
            }
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = shown ? 0.0001 : 1; a.toValue = shown ? 1 : 0.0001
            a.duration = shown ? d * 0.5 : d * 0.34          // ≈ 0.38 s / 0.25 s at the default 0.75 s
            a.timingFunction = shown ? VeilTiming.cursorGrow : VeilTiming.cursorShrink
            reveal.add(a, forKey: "veil.reveal")
            CATransaction.commit()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// CAFilter "gaussianBlur" inputRadius per point of Gaussian σ, calibrated against the
/// reference with the stripe scene (see the plan file). Kept separate so it is easy to re-measure.
enum BlurCalibration {
    static let radiusPerSigma: Double = 1.02   // measured: inputRadius 51 → σ 50 pt
}
