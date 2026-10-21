import SwiftUI
import Charts

// Briques visuelles réutilisées par le panneau.

extension Color {
    /// Jaune « énergie » lisible sur fond clair comme sombre.
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.80, green: 0.52, blue: 0.0, alpha: 1)
    })
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct Pill: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// Jauge circulaire : niveau de charge + repère de la limite.
struct ChargeRing: View {
    var percent: Int
    var limit: Int?
    var tint: Color

    var body: some View {
        ZStack {
            Circle().inset(by: 3.5).stroke(Color.primary.opacity(0.08), lineWidth: 7)
            Circle().inset(by: 3.5)
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * Double(percent) / 100)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: percent)
            if let limit, limit < 100 {
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 2.5, height: 13)
                    .offset(y: -32.5)
                    .rotationEffect(.degrees(360 * Double(limit) / 100))
                    .animation(.easeInOut(duration: 0.4), value: limit)
            }
            VStack(spacing: -2) {
                Text("\(percent)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 72)
    }
}

/// Flux d'énergie Adaptateur → Mac → Batterie.
struct PowerFlow: View {
    var battery: BatterySnapshot

    var body: some View {
        let charging = battery.batteryPower > 0.3
        let discharging = battery.batteryPower < -0.3
        HStack(spacing: 0) {
            node("powerplug.fill", "Adaptateur",
                 battery.adapterPresent ? Fmt.watts(battery.systemPowerIn ?? 0) : "—",
                 active: battery.adapterPresent && (battery.systemPowerIn ?? 0) > 0.3, tint: .amber)
            arrow(active: battery.adapterPresent && (battery.systemPowerIn ?? 0) > 0.3, reversed: false)
            node("laptopcomputer", "Mac", battery.systemLoad.map(Fmt.watts) ?? "—", active: true, tint: .blue)
            arrow(active: charging || discharging, reversed: discharging)
            node(charging ? "battery.100percent.bolt" : "battery.75percent", "Batterie",
                 (charging ? "+" : discharging ? "−" : "") + Fmt.watts(abs(battery.batteryPower)),
                 active: charging || discharging, tint: charging ? .green : .orange)
        }
    }

    private func node(_ icon: String, _ label: String, _ value: String, active: Bool, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? tint : .secondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill((active ? tint : .secondary).opacity(0.14)))
            Text(value).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func arrow(active: Bool, reversed: Bool) -> some View {
        Image(systemName: reversed ? "chevron.left.2" : "chevron.right.2")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
            .padding(.bottom, 30)
    }
}

struct Stat: View {
    var label: String
    var value: String
    var detail: String?
    var icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                if let detail { Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit() }
            }
            Spacer(minLength: 0)
        }
    }
}

struct HistoryChart: View {
    var points: [HistoryPoint]
    var limit: Int?

    var body: some View {
        let since = Date().addingTimeInterval(-12 * 3600)
        let visible = points.filter { $0.t >= since }
        Chart {
            ForEach(visible) { p in
                AreaMark(x: .value("Heure", p.t), y: .value("Charge", p.p))
                    .foregroundStyle(LinearGradient(colors: [.green.opacity(0.35), .green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Heure", p.t), y: .value("Charge", p.p))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            if let limit, limit < 100 {
                RuleMark(y: .value("Limite", limit))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text("limite \(limit) %").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: since...Date())
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)").font(.system(size: 9)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
            }
        }
        .frame(height: 86)
        .overlay {
            if visible.count < 2 {
                Text("L'historique se remplit au fil de l'utilisation")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Témoin de fraîcheur des mesures du flux d'énergie.
struct LiveBadge: View {
    var live: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(live ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
                .opacity(live ? 1 : 0.6)
            Text(live ? "en direct" : "toutes les 60 s")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help(live ? "Mesures SMC rafraîchies chaque seconde" : "Mesures de l'IORegistry, mises à jour par macOS toutes les 60 s")
    }
}

/// Signale si la fenêtre qui contient la vue est réellement visible à l'écran.
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: TrackingView, context: Context) { v.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            guard let window else { onChange?(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.report(closing: note.name == NSWindow.willCloseNotification) }
                })
            }
            report()
        }

        private func report(closing: Bool = false) {
            guard let window else { return }
            let visible = !closing && window.isVisible && (window.occlusionState.contains(.visible) || window.isKeyWindow)
            onChange?(visible)
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
