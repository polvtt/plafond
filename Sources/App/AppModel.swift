import Foundation
import SwiftUI
import IOKit.ps
import ServiceManagement
import os

private let uiLog = Logger(subsystem: "com.polat.plafond", category: "ui")

struct HistoryPoint: Codable, Identifiable, Equatable {
    var t: Date
    var p: Int
    var c: Bool          // en charge
    var id: Date { t }
}

/// D'où vient la limite actuellement appliquée.
enum LimitBackend: Equatable {
    case none
    case native            // PowerUI / PowerUIAgent (80…100)
    case helper            // limite logicielle du helper (sous 80 % ou Mac sans MCL)

    var label: String {
        switch self {
        case .none: return "Inactive"
        case .native: return "Native macOS"
        case .helper: return "Logicielle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // État observé
    @Published private(set) var battery = BatterySnapshot()
    @Published private(set) var native = NativeChargeLimit.State()
    @Published private(set) var history: [HistoryPoint] = []
    @Published var message: String?
    @Published var panelVisible = false {
        didSet {
            guard oldValue != panelVisible else { return }
            uiLog.info("panneau \(self.panelVisible ? "ouvert" : "fermé", privacy: .public)")
            reschedule()
        }
    }
    /// Vrai quand le flux d'énergie vient du SMC (≈ 1 s) plutôt que de l'IORegistry (60 s).
    @Published private(set) var liveSource = false

    // Réglages
    @AppStorage("targetLimit") var targetLimit = 80
    @AppStorage("showPercent") var showPercent = true
    @AppStorage("allowBelow80") var allowBelow80 = false
    @AppStorage("resumeSoftLimit") private var resumeSoftLimit = 0   // limite logicielle à rétablir après « 100 % une fois »

    let helper = HelperClient()
    private let nativeLimit = NativeChargeLimit()
    private let smc = try? SMC()
    private var timer: Timer?
    private var psSource: CFRunLoopSource?
    private var lastSample: Date = .distantPast
    private var tickCount = 0

    private let historyURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plafond", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        loadHistory()
        tick()
        helper.refresh()
        native = nativeLimit.read()
        // Réagit tout de suite aux branchements / changements de % (sans polling agressif).
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let model = Unmanaged<AppModel>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { model.tick() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            psSource = src
        }
        reschedule()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveHistory() }
        }
    }

    private func reschedule() {
        timer?.invalidate()
        // Panneau ouvert : 1 s (le SMC se met à jour ~chaque seconde). Fermé : 15 s suffisent
        // pour l'icône et l'historique (l'IORegistry batterie ne bouge que toutes les 60 s).
        let interval: TimeInterval = panelVisible ? 1 : 15
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if panelVisible {
            native = nativeLimit.read()
            helper.refresh()
            tick()
        }
    }

    // MARK: Rafraîchissement

    func tick() {
        guard var b = BatteryReader.read() else { return }
        liveSource = panelVisible && applyLiveSMC(&b)
        if b.temperature == nil, let t = try? smc?.readNumber("TB0T"), t > 0, t < 100 { b.temperature = t }
        battery = b
        tickCount += 1
        if panelVisible && tickCount % 3 == 0 { helper.refresh() }
        sample(b)
        resumeSoftLimitIfNeeded(b)
    }

    /// Remplace les mesures électriques de l'IORegistry (rafraîchies toutes les 60 s
    /// par le pilote AppleSmartBattery) par celles du SMC, mises à jour ~chaque seconde.
    /// Clés relevées sur M4 / macOS 27, lisibles sans privilèges, little-endian :
    ///   PDTR (flt, W) puissance d'entrée DC · PSTR (flt, W) consommation système
    ///   B0AV (ui16, mV) tension batterie · B0AC (si16, mA) courant batterie (> 0 en charge)
    private func applyLiveSMC(_ b: inout BatterySnapshot) -> Bool {
        guard let smc,
              let mv = try? smc.readNumber("B0AV"), mv > 5_000, mv < 20_000,
              let ma = try? smc.readNumber("B0AC"), abs(ma) < 20_000 else { return false }
        b.voltage = Int(mv)
        b.amperage = Int(ma)
        if let w = try? smc.readNumber("PDTR"), w >= 0, w < 300 { b.systemPowerIn = b.adapterPresent ? w : 0 }
        if let w = try? smc.readNumber("PSTR"), w >= 0, w < 300 { b.systemLoad = w }
        if let t = try? smc.readNumber("TB0T"), t > 0, t < 100 { b.temperature = t }
        return true
    }

    private func sample(_ b: BatterySnapshot) {
        let now = Date()
        let changed = history.last.map { $0.p != b.percent || $0.c != b.isCharging } ?? true
        guard changed || now.timeIntervalSince(lastSample) > 120 else { return }
        lastSample = now
        history.append(HistoryPoint(t: now, p: b.percent, c: b.isCharging))
        let cutoff = now.addingTimeInterval(-48 * 3600)
        if let first = history.firstIndex(where: { $0.t >= cutoff }), first > 0 { history.removeFirst(first) }
        if history.count % 10 == 0 { saveHistory() }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let h = try? JSONDecoder().decode([HistoryPoint].self, from: data) else { return }
        history = h.filter { $0.t > Date().addingTimeInterval(-48 * 3600) }
    }

    func saveHistory() {
        try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }

    // MARK: Limite — état dérivé

    var softLimit: Int? { helper.status?.policy.softLimit }

    var backend: LimitBackend {
        if let s = softLimit, s < 80 || !native.supported { return .helper }
        if native.enabled || native.suspended { return .native }
        if softLimit != nil { return .helper }
        return .none
    }

    var limitEnabled: Bool { backend != .none }

    /// Limite effective affichée.
    var effectiveLimit: Int {
        switch backend {
        case .helper: return softLimit ?? targetLimit
        case .native: return native.limit
        case .none: return targetLimit
        }
    }

    var canGoBelow80: Bool { allowBelow80 && helper.isConnected && (helper.status?.adapterKeyAvailable ?? false) }
    var sliderRange: ClosedRange<Double> { canGoBelow80 || !native.supported ? 20...100 : 80...100 }

    var dischargeTarget: Int? { helper.status?.policy.dischargeTarget }

    // MARK: Actions

    func setLimitEnabled(_ on: Bool) {
        if on { applyLimit(targetLimit) } else { disableLimit() }
    }

    func applyLimit(_ value: Int) {
        let v = min(max(value, Int(sliderRange.lowerBound)), 100)
        targetLimit = v
        message = nil
        do {
            if native.supported && v >= 80 {
                let snapped = native.available.min { abs($0 - v) < abs($1 - v) } ?? v
                targetLimit = snapped
                try nativeLimit.apply(percent: snapped, enable: true)
                if softLimit != nil { helper.update { $0.softLimit = nil } }
            } else {
                guard helper.isConnected else {
                    message = "Une limite sous 80 % demande l'assistant privilégié (Réglages)."
                    return
                }
                // Plancher natif à 80 % : si le helper tombe, la charge s'arrête quand même à 80.
                if native.supported { try nativeLimit.apply(percent: 80, enable: true) }
                helper.update { $0.softLimit = v }
            }
        } catch {
            message = error.localizedDescription
        }
        native = nativeLimit.read()
    }

    func disableLimit() {
        do {
            if native.enabled || native.suspended { try nativeLimit.disable() }
        } catch { message = error.localizedDescription }
        if softLimit != nil { helper.update { $0.softLimit = nil } }
        resumeSoftLimit = 0
        native = nativeLimit.read()
    }

    func chargeToFullOnce() {
        do {
            if native.enabled { try nativeLimit.chargeToFullOnce() }
            if let s = softLimit {
                resumeSoftLimit = s
                helper.update { $0.softLimit = nil }
            }
            message = "Charge jusqu'à 100 % : la limite reprendra ensuite."
        } catch { message = error.localizedDescription }
        native = nativeLimit.read()
    }

    /// Après « 100 % une fois », on rétablit la limite logicielle au débranchement ou à 100 %.
    private func resumeSoftLimitIfNeeded(_ b: BatterySnapshot) {
        guard resumeSoftLimit > 0, helper.isConnected, b.percent >= 100 || !b.adapterPresent else { return }
        let s = resumeSoftLimit
        resumeSoftLimit = 0
        helper.update { $0.softLimit = s }
    }

    func toggleDischarge() {
        guard helper.isConnected else { message = "La décharge forcée demande l'assistant privilégié."; return }
        if dischargeTarget != nil {
            helper.update { $0.dischargeTarget = nil }
        } else {
            let target = limitEnabled ? effectiveLimit : targetLimit
            guard battery.percent > target else { message = "La batterie est déjà sous \(target) %."; return }
            helper.update { $0.dischargeTarget = target }
        }
    }

    func setLED(_ mode: LEDMode) {
        helper.update { $0.magSafeLED = mode }
    }

    func setSailing(_ range: Int) {
        helper.update { $0.sailingRange = range }
    }

    // MARK: Ouverture à la connexion

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { message = "Ouverture à la connexion : \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }

    // MARK: Textes d'état

    var stateTitle: String {
        let b = battery
        if helper.status?.adapterDisabled == true && b.adapterPresent { return "Décharge forcée" }
        if !b.adapterPresent { return "Sur batterie" }
        if b.isCharging { return "En charge" }
        if b.fullyCharged || b.percent >= 100 { return "Chargée" }
        if limitEnabled && b.percent >= effectiveLimit - 1 { return "En pause à la limite" }
        return "Branché, sans charge"
    }

    /// Minutes pour atteindre `target` % au courant de charge actuel (phase à courant
    /// quasi constant sous 80 % : l'estimation linéaire y est raisonnable).
    private func minutesToReach(_ target: Int, _ b: BatterySnapshot) -> Int? {
        guard b.amperage > 50, b.fullChargeCapacity > 0 else { return nil }
        let needed = Double(b.fullChargeCapacity) * Double(target) / 100 - Double(b.remainingCapacity)
        guard needed > 0 else { return nil }
        return Int((needed / Double(b.amperage) * 60).rounded())
    }

    var stateDetail: String {
        let b = battery
        var parts: [String] = []
        if let a = helper.status?.activity, b.adapterPresent { return a }
        if native.suspended && b.adapterPresent { parts.append("limite suspendue jusqu'à 100 %") }
        if b.isCharging {
            parts.append(Fmt.watts(b.batteryPower))
            // macOS donne le temps jusqu'à 100 % ; avec une limite, on estime jusqu'à la limite.
            if limitEnabled, b.percent < effectiveLimit, let t = minutesToReach(effectiveLimit, b) {
                parts.append("\(effectiveLimit) % dans ~\(Fmt.duration(t))")
            } else if let t = b.timeToFull {
                parts.append("plein dans \(Fmt.duration(t))")
            }
        } else if !b.adapterPresent {
            parts.append(Fmt.watts(abs(b.batteryPower)))
            if let t = b.timeToEmpty { parts.append("\(Fmt.duration(t)) restantes") }
        } else if let name = b.adapterName {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }
}

enum Fmt {
    static func watts(_ w: Double) -> String {
        w.formatted(.number.precision(.fractionLength(1))) + " W"
    }
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
}
