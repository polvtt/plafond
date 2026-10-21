import AppKit
import SwiftUI

// Mode de vérification visuelle : `Plafond --snapshot <dossier>` rend le panneau
// (données réelles, lecture seule) en clair et en sombre, puis quitte.

@MainActor
enum Snapshot {
    static func runIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            model.panelVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for (page, pageName) in [(PanelState.Page.main, "main"), (.settings, "settings")] {
                    for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                        render(PanelView(initialPage: page).environmentObject(model),
                               appearance: appearance,
                               to: dir.appendingPathComponent("panel-\(pageName)-\(name).png"))
                    }
                }
                let icon = MenuBarIcon.image(percent: model.battery.percent,
                                             limit: model.limitEnabled ? model.effectiveLimit : 80,
                                             badge: model.battery.isCharging ? .charging : .plugged)
                for (p, n) in [(23, "23"), (67, "67"), (100, "100")] {
                    writePNG(MenuBarIcon.image(percent: p, limit: 80, badge: .charging), scale: 6, to: dir.appendingPathComponent("icon-\(n).png"))
                }
                writePNG(icon, scale: 6, to: dir.appendingPathComponent("menubar-icon.png"))
                exit(0)
            }
        }
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea()))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private static func writePNG(_ image: NSImage, scale: CGFloat, to url: URL) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let out = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            image.draw(in: r)
            return true
        }
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
