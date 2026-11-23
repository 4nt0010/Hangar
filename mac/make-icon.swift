// Disegna l'icona di Hangar e la salva come iconset (usato dalla build su GitHub).
// Uso: swift make-icon.swift Hangar.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Hangar.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(size px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(px) / 1024
    let cg = ctx.cgContext
    cg.scaleBy(x: s, y: s)

    // Corpo dell'icona (griglia macOS: 824 pt su 1024, angoli morbidi)
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x3A2F6B, 0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0xA394E4).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x7DB898), color(0x8FA9C9), color(0xA394E4), color(0xC69ACB)],
               atLocations: [0, 0.38, 0.72, 1], colorSpace: .sRGB)?.draw(in: body, angle: -45)
    // riflesso "vetro" in alto e un velo pesca in basso a destra
    NSGradient(starting: color(0xFFFFFF, 0.34), ending: color(0xFFFFFF, 0))?
        .draw(in: NSRect(x: 100, y: 540, width: 824, height: 384), angle: -90)
    NSGradient(starting: color(0xEFA67C, 0.0), ending: color(0xEFA67C, 0.35))?
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 520, y: 40, width: 560, height: 520)), relativeCenterPosition: NSPoint(x: 0.3, y: -0.3))
    NSGraphicsContext.restoreGraphicsState()

    // bordo sottile chiaro
    color(0xFFFFFF, 0.35).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()

    // Hangar (stesso disegno del logo del sito, viewBox 34×34, asse y capovolto)
    let k: CGFloat = 15.5
    let ox: CGFloat = 512 - 17 * k, oy: CGFloat = 512 + 17.5 * k
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy - y * k) }
    let roof = NSBezierPath()
    roof.move(to: p(5, 17)); roof.line(to: p(17, 8)); roof.line(to: p(29, 17)); roof.line(to: p(29, 27)); roof.line(to: p(5, 27)); roof.close()
    let door = NSBezierPath()
    door.move(to: p(11.5, 27)); door.line(to: p(11.5, 21.5)); door.line(to: p(22.5, 21.5)); door.line(to: p(22.5, 27))
    for path in [roof, door] {
        path.lineWidth = 2.8 * k
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
    }
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x2B2350, 0.22)
    glow.shadowBlurRadius = 18
    glow.shadowOffset = NSSize(width: 0, height: -8)
    glow.set()
    NSColor.white.setStroke()
    roof.stroke(); door.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in sizes {
    guard let data = draw(size: px) else { fatalError("disegno non riuscito") }
    try! data.write(to: out.appendingPathComponent("\(name).png"))
}
print("Icone create in \(out.path)")
