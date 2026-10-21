import AppKit

// Génère Resources/AppIcon.icns : squircle vert profond, batterie blanche
// remplie à 80 % sous une ligne de « plafond ».
//   swiftc Tools/make_icon/main.swift -o build/make_icon && build/make_icon Resources

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Fond : squircle avec dégradé (marges de la grille d'icônes macOS : 100 px)
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill(); bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.36, blue: 0.27, alpha: 1),
                        NSColor(srgbRed: 0.13, green: 0.62, blue: 0.43, alpha: 1)])!.draw(in: bg, angle: 90)

    // Batterie verticale
    let body = NSRect(x: 362, y: 232, width: 300, height: 500)
    let outline = NSBezierPath(roundedRect: body, xRadius: 62, yRadius: 62)
    outline.lineWidth = 34
    NSColor.white.setStroke(); outline.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 452, y: body.maxY + 12, width: 120, height: 48), xRadius: 20, yRadius: 20).fill()

    // Remplissage jusqu'à 80 %
    let inner = body.insetBy(dx: 44, dy: 44)
    let level = inner.height * 0.80
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: level), xRadius: 26, yRadius: 26).fill()

    // Ligne de plafond, qui déborde de la batterie
    let y = inner.minY + level + 34
    let ceiling = NSBezierPath()
    ceiling.move(to: NSPoint(x: 268, y: y)); ceiling.line(to: NSPoint(x: 756, y: y))
    ceiling.lineWidth = 26; ceiling.lineCapStyle = .round
    NSColor(srgbRed: 1, green: 0.84, blue: 0.30, alpha: 1).setStroke()
    ceiling.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! draw(pt * sc).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(1024).representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ \(outDir.path)/AppIcon.icns" : "✗ iconutil a échoué")
