// One overlay window per display.
//
// Layer tree inside the window:
//   content (masked)
//     ├─ backdrop  CABackdropLayer: WindowServer-side blur + saturation of
//     │            whatever is BEHIND this window (other apps' windows)
//     ├─ tint      solid colour at low opacity (mode dim + chosen tint)
//     └─ grain     tiled noise
//   mask: CAShapeLayer = screen rect minus "holes" (windows that must stay
//         sharp but sit below the overlay), intersected with a circle while a
//         Cursor-reveal transition runs.
//
// CABackdropLayer / CAFilter are private Core Animation classes (what
// NSVisualEffectView uses internally). Using them directly is what makes a
// custom blur radius, blur-free mode and monochrome possible.

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

/// Seamless-enough random noise tile for the grain layer.
enum Grain {
    static let tile: CGImage? = {
        let n = 192
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let v = UInt8.random(in: 0...255)
            let a = UInt8.random(in: 40...255)
            // premultiplied grey
            let pv = UInt8(Int(v) * Int(a) / 255)
            px[i * 4] = pv; px[i * 4 + 1] = pv; px[i * 4 + 2] = pv; px[i * 4 + 3] = a
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }()
}

final class OverlayWindow: NSWindow {
    let content = CALayer()
    let backdrop: CALayer
    let tint = CALayer()
    let grain = CALayer()
    let mask = CAShapeLayer()
    private var holes: [CGRect] = []
    private var revealRadius: CGFloat? = nil   // non-nil while a cursor reveal is masking
    private var revealCenter: CGPoint = .zero
    let displayID: CGDirectDisplayID

    init(screen: NSScreen) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        backdrop = PrivateCA.backdropClass?.init() ?? CALayer()
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true          // clicks fall through to the window underneath
        isReleasedWhenClosed = false
        level = .normal                    // same level as app windows, so we can slot between them
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        alphaValue = 0

        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        contentView = v
        let root = v.layer!
        content.frame = root.bounds
        root.addSublayer(content)
        for l in [backdrop, tint, grain] {
            l.frame = content.bounds
            content.addSublayer(l)
        }
        backdrop.setValue(true, forKey: "windowServerAware")   // sample other apps' windows
        backdrop.setValue(0.5, forKey: "scale")                // half-res sampling: cheaper, looks identical once blurred
        if let tile = Grain.tile {
            grain.backgroundColor = NSColor(patternImage: NSImage(cgImage: tile, size: NSSize(width: 96, height: 96))).cgColor
        }
        mask.fillRule = .evenOdd
        content.mask = mask
        updateMask()
        applyStyle()
    }

    /// Push the current look (mode, blur, tint, grain, monochrome) into the layers.
    func applyStyle() {
        let s = Settings.shared
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let deep = s.mode == .deep
        var filters: [NSObject] = []
        let radius = s.blur * (deep ? 1.6 : 1.0)
        if radius > 0.5, let f = PrivateCA.filter("gaussianBlur") {
            f.setValue(radius, forKey: "inputRadius")
            f.setValue(true, forKey: "inputNormalizeEdges")
            filters.append(f)
        }
        // Saturation: monochrome slider drains colour; Deep also mutes a bit.
        let sat = max(0, (1 - s.monochrome)) * (deep ? 0.8 : 1.05)
        if let f = PrivateCA.filter("colorSaturate") {
            f.setValue(sat, forKey: "inputAmount")
            filters.append(f)
        }
        backdrop.filters = filters
        // Blur-free mode with no other effect would make the backdrop pointless;
        // keep it anyway so monochrome still works without blur.

        // Tint: mode-specific dim first, then the chosen colour blended over it.
        let dim: CGFloat = deep ? 0.45 : 0.08
        let c = s.tintColor.usingColorSpace(.sRGB) ?? .gray
        let a = CGFloat(s.tintAmount)
        // Composite "black at dim" under "tint at a" into one colour.
        let outA = a + dim * (1 - a)
        let mix = { (ch: CGFloat) -> CGFloat in outA > 0 ? (ch * a) / outA : 0 }
        tint.backgroundColor = NSColor(srgbRed: mix(c.redComponent), green: mix(c.greenComponent),
                                       blue: mix(c.blueComponent), alpha: outA).cgColor
        grain.opacity = Float(s.grain * 0.6)
        CATransaction.commit()
    }

    // MARK: Holes & reveal

    /// Rects (window-local, y-up) that must stay unblurred.
    func setHoles(_ rects: [CGRect]) {
        guard rects != holes else { return }
        holes = rects
        updateMask()
    }

    private func updateMask() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = content.bounds
        var shape = CGPath(rect: content.bounds, transform: nil)
        if !holes.isEmpty {
            let cut = CGMutablePath()
            for h in holes { cut.addRoundedRect(in: h, cornerWidth: 10, cornerHeight: 10) }
            // Union first so overlapping holes don't cancel each other out.
            shape = shape.subtracting(cut.union(CGPath(rect: .zero, transform: nil)))
        }
        if let r = revealRadius {
            let circle = CGPath(ellipseIn: CGRect(x: revealCenter.x - r, y: revealCenter.y - r, width: r * 2, height: r * 2), transform: nil)
            shape = shape.intersection(circle)
        }
        mask.path = shape
        CATransaction.commit()
    }

    // MARK: Transitions

    /// Show or hide with the configured transition. `cursor` is in screen coordinates.
    func setShown(_ shown: Bool, transition: Transition, cursor: CGPoint) {
        switch transition {
        case .none:
            alphaValue = shown ? 1 : 0
        case .fade:
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = shown ? 0.32 : 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = shown ? 1 : 0
            }
        case .cursor:
            // Grow (or shrink) a circular mask centred on the pointer.
            alphaValue = 1
            revealCenter = CGPoint(x: cursor.x - frame.minX, y: cursor.y - frame.minY)
            let maxR = hypot(frame.width, frame.height)
            let duration = shown ? 0.45 : 0.3
            let start = CACurrentMediaTime()
            revealTimer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let p = min(1, (CACurrentMediaTime() - start) / duration)
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2    // ease-in-out
                self.revealRadius = maxR * CGFloat(shown ? e : 1 - e)
                self.updateMask()
                if p >= 1 {
                    timer.invalidate()
                    self.revealRadius = nil
                    if !shown { self.alphaValue = 0 }
                    self.updateMask()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            revealTimer = t
            if shown { revealRadius = 0; updateMask() }
        }
    }
    private var revealTimer: Timer?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
