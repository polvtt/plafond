import SwiftUI

/// État local du panneau. (Sur le SDK macOS 27, @State est une macro dont le
/// plugin n'est livré qu'avec Xcode : avec les seuls Command Line Tools, on
/// passe par un ObservableObject.)
final class PanelState: ObservableObject {
    enum Page { case main, settings }
    @Published var page: Page
    @Published var draftLimit: Double = 80
    @Published var editing = false
    init(page: Page = .main) { self.page = page }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui: PanelState

    init(initialPage: PanelState.Page = .main) {
        _ui = StateObject(wrappedValue: PanelState(page: initialPage))
    }

    var body: some View {
        VStack(spacing: 0) {
            switch ui.page {
            case .main: main.transition(.move(edge: .leading).combined(with: .opacity))
            case .settings:
                SettingsView(back: { withAnimation(.snappy) { ui.page = .main } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 344)
        .onAppear {
            model.panelVisible = true
            ui.draftLimit = Double(model.effectiveLimit)
        }
        .onDisappear { model.panelVisible = false; ui.page = .main }
        // Une fenêtre MenuBarExtra est réutilisée d'une ouverture à l'autre : onAppear
        // n'est pas un signal fiable. On suit la visibilité réelle de la fenêtre.
        .background(WindowVisibilityReader { visible in
            if model.panelVisible != visible { model.panelVisible = visible }
            if !visible { ui.page = .main }
        })
        .onChange(of: model.effectiveLimit) { _, v in if !ui.editing { ui.draftLimit = Double(v) } }
    }

    // MARK: Page principale

    private var main: some View {
        VStack(spacing: 10) {
            header
            limitCard
            Card("Flux d'énergie", trailing: AnyView(LiveBadge(live: model.liveSource))) {
                PowerFlow(battery: model.battery)
            }
            healthCard
            Card("Dernières 12 heures") {
                HistoryChart(points: model.history, limit: model.limitEnabled ? model.effectiveLimit : nil)
            }
            if let msg = model.message ?? model.helper.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(msg).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.message = nil; model.helper.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            }
            footer
        }
        .padding(12)
    }

    private var tint: Color {
        let b = model.battery
        if model.helper.status?.adapterDisabled == true && b.adapterPresent { return .orange }
        if b.percent <= 15 && !b.adapterPresent { return .red }
        return b.adapterPresent ? .green : (b.percent <= 30 ? .orange : .green)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ChargeRing(percent: model.battery.percent,
                       limit: model.limitEnabled ? model.effectiveLimit : nil,
                       tint: tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.stateTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(model.stateDetail.isEmpty ? " " : model.stateDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    if model.limitEnabled {
                        Pill(text: "Limite \(model.effectiveLimit) %", systemImage: "lock.fill", tint: .green)
                    } else {
                        Pill(text: "Sans limite", systemImage: "lock.open.fill")
                    }
                    if let w = model.battery.adapterWatts, model.battery.adapterPresent {
                        Pill(text: "\(w) W", systemImage: "powerplug.fill", tint: .amber)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Limite

    private var limitCard: some View {
        Card("Limite de charge", trailing: AnyView(
            Toggle("", isOn: Binding(get: { model.limitEnabled },
                                     set: { on in withAnimation(.snappy) { model.setLimitEnabled(on) } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        )) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(ui.draftLimit))")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Pill(text: model.backend.label,
                     systemImage: model.backend == .native ? "apple.logo" : model.backend == .helper ? "gearshape.2.fill" : "pause.fill",
                     tint: model.backend == .none ? .secondary : model.backend == .native ? .blue : .purple)
            }
            .opacity(model.limitEnabled ? 1 : 0.55)

            Slider(value: $ui.draftLimit, in: model.sliderRange, step: 5) { isEditing in
                ui.editing = isEditing
                if !isEditing { model.applyLimit(Int(ui.draftLimit)) }
            }
            .controlSize(.small)
            .tint(ui.draftLimit < 80 ? .purple : .green)

            HStack {
                Text("\(Int(model.sliderRange.lowerBound)) %")
                Spacer()
                if ui.draftLimit < 80 {
                    Text("sous 80 % : coupure d'adaptateur cyclique").foregroundStyle(.purple)
                }
                Spacer()
                Text("100 %")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Button { model.chargeToFullOnce() } label: {
                    Label("100 % une fois", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .disabled(!model.limitEnabled)
                Button { model.toggleDischarge() } label: {
                    Label(model.dischargeTarget.map { "Arrêter (→ \($0) %)" } ?? "Décharger",
                          systemImage: model.dischargeTarget == nil ? "arrow.down.circle" : "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.helper.isConnected || !model.battery.adapterPresent)
                .help(model.helper.isConnected ? "Coupe l'adaptateur jusqu'à la limite (le Mac tourne sur batterie)"
                                               : "Nécessite l'assistant privilégié (Réglages)")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            if model.native.optimizedChargingEnabled && model.limitEnabled {
                Text("La recharge optimisée de macOS est active : elle peut retarder la charge.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Santé

    private var healthCard: some View {
        let b = model.battery
        return Card("Santé de la batterie") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Stat(label: "Capacité max.",
                         value: b.health.map { ($0 * 100).formatted(.number.precision(.fractionLength(0))) + " %" } ?? "—",
                         detail: b.designCapacity > 0 ? "\(b.nominalCapacity) / \(b.designCapacity) mAh" : nil,
                         icon: "heart.fill")
                    Stat(label: "Cycles", value: "\(b.cycleCount)",
                         detail: "sur \(b.designCycleCount) prévus", icon: "arrow.triangle.2.circlepath")
                }
                GridRow {
                    Stat(label: "Température",
                         value: b.temperature.map { $0.formatted(.number.precision(.fractionLength(1))) + " °C" } ?? "—",
                         detail: "capteur TB0T", icon: "thermometer.medium")
                    Stat(label: "Tension",
                         value: (Double(b.voltage) / 1000).formatted(.number.precision(.fractionLength(2))) + " V",
                         detail: (Double(b.amperage) / 1000).formatted(.number.precision(.fractionLength(2))) + " A",
                         icon: "bolt.horizontal.fill")
                }
            }
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 10) {
            helperBadge
            Spacer()
            Button { withAnimation(.snappy) { ui.page = .settings } } label: { Image(systemName: "gearshape") }
                .help("Réglages")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quitter Plafond")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var helperBadge: some View {
        switch model.helper.state {
        case .connected(let v):
            Pill(text: "Assistant v\(v)", systemImage: "checkmark.shield.fill", tint: .green)
        case .outdated:
            Button { model.helper.install() } label: { Pill(text: "Mettre à jour l'assistant", systemImage: "arrow.triangle.2.circlepath", tint: .orange) }
                .buttonStyle(.plain)
        case .notInstalled:
            Button { withAnimation(.snappy) { ui.page = .settings } } label: {
                Pill(text: "Assistant non installé", systemImage: "shield.slash", tint: .secondary)
            }.buttonStyle(.plain)
        case .connecting:
            Pill(text: "Connexion…", systemImage: "ellipsis")
        case .error:
            Pill(text: "Assistant injoignable", systemImage: "exclamationmark.shield", tint: .orange)
        }
    }
}
