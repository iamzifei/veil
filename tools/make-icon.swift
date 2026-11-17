// Renders Veil's app icon master: blurred background windows, one sharp window in focus.
//   swift tools/make-icon.swift <out.png>
import AppKit
import CoreImage

let N = 1024, inset: CGFloat = 100, side = CGFloat(N) - 200
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func canvas() -> CGContext {
    CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func win(_ c: CGContext, _ r: CGRect, _ fill: NSColor, bar: Bool = false) {
    let p = CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil)
    c.addPath(p); c.setFillColor(fill.cgColor); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)  // shadow only on the window body
    guard bar else { return }
    for (i, col) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFillColor(col.cgColor)
        c.fillEllipse(in: CGRect(x: r.minX + 36 + CGFloat(i) * 44, y: r.maxY - 62, width: 28, height: 28))
    }
    c.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
    for (j, w) in [0.72, 0.55, 0.64, 0.4].enumerated() {
        c.fill(CGRect(x: r.minX + 40, y: r.maxY - 130 - CGFloat(j) * 52, width: (r.width - 80) * w, height: 22))
    }
}

// 1) Background layer: colourful windows, then gaussian-blurred.
let bg = canvas()
let grad = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.42, alpha: 1).cgColor,
                                                 NSColor(srgbRed: 0.42, green: 0.22, blue: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
bg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
win(bg, CGRect(x: 120, y: 560, width: 420, height: 330), NSColor(srgbRed: 1, green: 0.55, blue: 0.3, alpha: 1))
win(bg, CGRect(x: 560, y: 600, width: 360, height: 300), NSColor(srgbRed: 0.3, green: 0.8, blue: 0.7, alpha: 1))
win(bg, CGRect(x: 130, y: 130, width: 330, height: 360), NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1))
win(bg, CGRect(x: 640, y: 120, width: 280, height: 330), NSColor(srgbRed: 1, green: 0.8, blue: 0.3, alpha: 1))
let ci = CIImage(cgImage: bg.makeImage()!).clampedToExtent().applyingGaussianBlur(sigma: 38)
let blurred = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: N, height: N))!

// 2) Composite inside the squircle + a slight dim, then the sharp focus window.
let c = canvas()
c.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side), cornerWidth: 185, cornerHeight: 185, transform: nil))
c.clip()
c.draw(blurred, in: CGRect(x: 0, y: 0, width: N, height: N))
c.setFillColor(NSColor(white: 0, alpha: 0.18).cgColor); c.fill(CGRect(x: 0, y: 0, width: N, height: N))
c.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor(white: 0, alpha: 0.45).cgColor)
win(c, CGRect(x: 262, y: 300, width: 500, height: 420), .white, bar: true)
let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
