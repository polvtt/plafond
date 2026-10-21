import AppKit

// Icône de barre de menus calquée sur l'indicateur natif de macOS 27, mesuré au
// pixel sur une capture Retina : corps plein sans contour (23 × 12 pt, coins
// ~3,5 pt), partie chargée opaque, partie vide à ~45 %, borne 1,5 × 4 pt, et le
// pourcentage + le pictogramme d'état ÉVIDÉS dans la forme, centrés ensemble.
// Image « template » : macOS la teinte selon la barre claire/sombre.

enum MenuBarIcon {
    enum Badge { case none, charging, plugged, discharging }

    static func image(percent: Int, limit: Int?, badge: Badge, showPercent: Bool = true) -> NSImage {
        let size = NSSize(width: 26, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let body = NSRect(x: 0, y: 2, width: 23, height: 12)
            let shape = NSBezierPath(roundedRect: body, xRadius: 4.3, yRadius: 4.3)
            // Apple remplit ~97 % de la largeur proportionnelle (mesuré sur la ligne haute, sans chiffres).
            let p = CGFloat(min(max(percent, 0), 100)) / 100 * (percent >= 100 ? 1 : 0.97)

            // Partie vide (grisée) puis partie chargée (opaque), découpées dans la forme
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.black.withAlphaComponent(0.6).setFill()
            body.fill()
            NSColor.black.setFill()
            NSRect(x: body.minX, y: body.minY, width: body.width * p, height: body.height).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Borne
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: 6, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()

            // Tout ce qui suit est évidé (le fond de la barre transparaît)
            ctx.compositingOperation = .destinationOut
            NSColor.black.setFill()

            // Pourcentage + pictogramme, centrés ensemble
            let text = showPercent ? "\(percent)" as NSString : "" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: percent >= 100 ? 9 : 10.25, weight: .medium),
                .foregroundColor: NSColor.black,
                .kern: -0.2,
            ]
            let ts = text.size(withAttributes: attrs)
            var glyph: NSImage?
            let symbolName: String? = {
                switch badge {
                case .charging: return "bolt.fill"
                case .plugged: return "powerplug.fill"
                case .discharging: return "arrow.down"
                case .none: return nil
                }
            }()
            if let symbolName {
                glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
            }
            let gs = glyph?.size ?? .zero
            let gap: CGFloat = (glyph != nil && ts.width > 0) ? 0.5 : 0
            let total = ts.width + gap + gs.width
            // Avec un pictogramme, Apple décale le groupe d'environ 1,5 pt vers la droite ;
            // seuls, les chiffres sont centrés.
            var x = body.midX - total / 2 + (glyph != nil ? 1.5 : 0)
            if ts.width > 0 {
                text.draw(at: NSPoint(x: x, y: body.midY - ts.height / 2 + 0.2), withAttributes: attrs)
                x += ts.width + gap
            }
            if let glyph {
                glyph.draw(in: NSRect(x: x, y: body.midY - gs.height / 2, width: gs.width, height: gs.height),
                           from: .zero, operation: .destinationOut, fraction: 1)
            }
            ctx.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true
        return img
    }
}
