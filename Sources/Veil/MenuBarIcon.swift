// Menu-bar icon, drawn in code (no asset catalog). Four states:
//   deep      veil on, Deep mode      — solid disc with a soft halo
//   ambient   veil on, Ambient mode   — disc that fades from the edge in (a "gradient" veil)
//   ignored   the front app is in Ignored apps — an empty ring
//   off       veil off                — a faint disc
// The drawing handler runs again whenever the menu bar's appearance changes, so
// `NSColor.labelColor` resolves to white on a dark menu bar and black on a light one.

import AppKit

enum MenuBarIcon {
    enum State { case deep, ambient, ignored, off }

    static func image(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSColor.labelColor
            let disc = rect.insetBy(dx: 4, dy: 4)
            switch state {
            case .deep:
                // Halo: three concentric rings of decreasing alpha, then the solid disc.
                for (i, a) in [0.10, 0.18, 0.28].enumerated() {
                    c.withAlphaComponent(a).setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: CGFloat(1 + i), dy: CGFloat(1 + i))).fill()
                }
                c.setFill(); NSBezierPath(ovalIn: disc).fill()
            case .ambient:
                // Radial fade: dense centre, soft edge — the Ambient falloff in miniature.
                let g = NSGradient(colors: [c, c.withAlphaComponent(0.85), c.withAlphaComponent(0.25)],
                                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)
                g?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)), relativeCenterPosition: .zero)
            case .ignored:
                let ring = NSBezierPath(ovalIn: disc.insetBy(dx: -0.5, dy: -0.5))
                ring.lineWidth = 1.6
                c.withAlphaComponent(0.85).setStroke(); ring.stroke()
            case .off:
                c.withAlphaComponent(0.35).setFill(); NSBezierPath(ovalIn: disc).fill()
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Veil"
        return img
    }
}
