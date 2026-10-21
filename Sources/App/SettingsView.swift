import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var back: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: back) {
                    Label("Retour", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Réglages").font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 4)

            helperCard
            ledCard
            experimentalCard
            generalCard

            Text("Plafond — outil personnel. PowerUI et le SMC sont pilotés directement.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(12)
    }

    private var helper: HelperClient { model.helper }

    private var helperCard: some View {
        Card("Assistant privilégié") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: helper.isConnected ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 22))
                    .foregroundStyle(helper.isConnected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(helperTitle).font(.system(size: 12.5, weight: .semibold))
                    Text("Démon root qui écrit dans le SMC : décharge forcée (CHIE), LED MagSafe (ACLC), limite sous 80 %. La limite native 80–100 % fonctionne sans lui.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let s = helper.status {
                        Text("SMC : adaptateur \(s.adapterKeyAvailable ? "✓" : "✗") · LED \(s.ledKeyAvailable ? "✓" : "✗") · root \(s.isRoot ? "✓" : "✗")")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                switch helper.state {
                case .notInstalled, .error:
                    Button("Installer…") { helper.install() }.buttonStyle(.borderedProminent)
                case .outdated:
                    Button("Mettre à jour…") { helper.install() }.buttonStyle(.borderedProminent)
                default:
                    EmptyView()
                }
                if helper.isInstalled {
                    Button("Désinstaller", role: .destructive) { helper.uninstall() }
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var helperTitle: String {
        switch helper.state {
        case .connected(let v): return "Installé et connecté (v\(v))"
        case .outdated(let v): return "Version \(v) installée — mise à jour disponible"
        case .notInstalled: return "Non installé"
        case .connecting: return "Connexion…"
        case .error(let e): return "Injoignable : \(e)"
        }
    }

    private var ledCard: some View {
        Card("LED MagSafe") {
            Picker("", selection: Binding(get: { helper.status?.policy.magSafeLED ?? .system },
                                          set: { model.setLED($0) })) {
                ForEach(LEDMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!(helper.isConnected && (helper.status?.ledKeyAvailable ?? false)))
            Text("« Intelligente » : verte quand la charge est en pause à la limite (le système la laisse orange), orange en charge, éteinte en décharge forcée.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var experimentalCard: some View {
        Card("Expérimental") {
            Toggle(isOn: $model.allowBelow80) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autoriser une limite sous 80 %").font(.system(size: 12.5))
                    Text("macOS 27 ne sait plus suspendre la charge sous 80 % (clés CHTE/CH0B absentes du firmware). Plafond coupe alors l'adaptateur au-dessus de la limite et le rétablit après une redescente de quelques %.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            .disabled(!helper.isConnected)

            if model.allowBelow80 {
                Stepper(value: Binding(get: { helper.status?.policy.sailingRange ?? 5 },
                                       set: { model.setSailing($0) }), in: 2...15) {
                    Text("Plage de redescente : \(helper.status?.policy.sailingRange ?? 5) %").font(.system(size: 12))
                }
                .controlSize(.small)
            }
        }
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    private var generalCard: some View {
        Card("Général") {
            row("Pourcentage dans la barre de menus", isOn: $model.showPercent)
            row("Ouvrir à la connexion", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        }
    }
}
