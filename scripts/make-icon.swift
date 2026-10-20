// Draws the app icon (an orange conversion wheel) into an .iconset folder.
// usage: swift make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded square background.
    let inset = s * 0.09
    let bg = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: bg, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 1, green: 0.66, blue: 0.25, alpha: 1), CGColor(red: 0.96, green: 0.42, blue: 0.08, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Wheel segments.
    let c = CGPoint(x: s / 2, y: s / 2)
    let outer = s * 0.33, inner = s * 0.14
    let n = 6
    for i in 0..<n {
        let a0 = CGFloat(i) * 2 * .pi / CGFloat(n) + 0.06, a1 = CGFloat(i + 1) * 2 * .pi / CGFloat(n) - 0.06
        let p = CGMutablePath()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: i == 1 ? 1 : 0.55))
        ctx.fillPath()
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: c.x - inner * 0.7, y: c.y - inner * 0.7, width: inner * 1.4, height: inner * 1.4))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
