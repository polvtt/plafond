import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

// Plafond — helper privilégié (LaunchDaemon root, service Mach XPC).
//
// Rôle : appliquer une politique (décharge forcée, limite logicielle, LED
// MagSafe) en écrivant une poignée de clés SMC sur liste blanche. Toute la
// décision est prise ICI, à partir de l'état batterie lu dans l'IORegistry,
// pour que la politique tienne même app fermée.
//
// Sécurités :
//  • client XPC vérifié par exigence de signature (certificat épinglé) ;
//  • adaptateur rétabli avant la mise en veille, à l'arrêt (SIGTERM) et
//    sous un plancher de 10 % ;
//  • LED rendue au système à l'arrêt.

let log = Logger(subsystem: "com.polat.plafond.helper", category: "helper")

// MARK: - Clés SMC (liste blanche)

/// Coupure de l'adaptateur (« décharge forcée »). Valeurs relevées dans le
/// firmware et confirmées par le projet open source batt.
struct AdapterKey { let key: String; let off: [UInt8]; let on: [UInt8] }
let adapterKeys = [
    AdapterKey(key: "CHIE", off: [0x08], on: [0x00]),   // Apple Silicon, firmware récent
    AdapterKey(key: "CH0I", off: [0x01], on: [0x00]),   // Apple Silicon ancien / Intel
]

/// Inhibition de la charge (maintien sans décharger). Absente des firmwares
/// macOS 27 (vérifié sur MacBook Air M4) : remplacée par la limite native MCL.
struct InhibitKey { let keys: [String]; let inhibit: [UInt8]; let allow: [UInt8] }
let inhibitKeys = [
    InhibitKey(keys: ["CHTE"], inhibit: [0x01, 0x00, 0x00, 0x00], allow: [0x00, 0x00, 0x00, 0x00]),
    InhibitKey(keys: ["CH0B", "CH0C"], inhibit: [0x02], allow: [0x00]),
]

let ledKey = "ACLC"
enum LEDValue: UInt8 { case system = 0, off = 1, green = 3, orange = 4 }

let safetyFloor = 10

// MARK: - Moteur

final class Engine {
    private var smc: SMC?
    private let adapter: AdapterKey?
    private let inhibit: InhibitKey?
    private let ledAvailable: Bool
    private(set) var policy: HelperPolicy
    private var sailing = false          // phase « on redescend » de la limite logicielle
    private var ledOwned = false         // on a écrit une couleur → rendre la main ensuite
    private var activity: String?
    private var lastError: String?
    private let policyURL = URL(fileURLWithPath: HelperConstants.stateDir).appendingPathComponent("policy.json")

    init() {
        var opened: SMC?
        do { opened = try SMC() } catch { lastError = "\(error)"; log.error("SMC : \(String(describing: error), privacy: .public)") }
        smc = opened
        adapter = adapterKeys.first { opened?.exists($0.key) == true }
        inhibit = inhibitKeys.first { k in k.keys.allSatisfy { opened?.exists($0) == true } }
        ledAvailable = opened?.exists(ledKey) == true
        policy = HelperPolicy()
        if let data = try? Data(contentsOf: policyURL), let p = try? JSONDecoder().decode(HelperPolicy.self, from: data) {
            policy = p.sanitized()
        }
        log.info("démarrage : adaptateur=\(self.adapter?.key ?? "-", privacy: .public) inhibition=\(self.inhibit?.keys.joined(separator: "+") ?? "-", privacy: .public) led=\(self.ledAvailable)")
    }

    func setPolicy(_ p: HelperPolicy) {
        let old = policy
        policy = p.sanitized()
        if policy.softLimit != old.softLimit { sailing = false }
        save()
        evaluate()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(atPath: HelperConstants.stateDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(policy).write(to: policyURL, options: .atomic)
        } catch { log.error("sauvegarde politique : \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Écritures SMC

    private func write(_ key: String, _ bytes: [UInt8]) {
        guard let smc else { return }
        do {
            if try smc.read(key) != bytes {
                try smc.write(key, bytes)
                log.info("SMC \(key, privacy: .public) ← \(bytes.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
            }
        } catch {
            lastError = "\(key) : \(error)"
            log.error("écriture \(key, privacy: .public) : \(String(describing: error), privacy: .public)")
        }
    }

    private func setAdapter(enabled: Bool) {
        guard let adapter else { return }
        write(adapter.key, enabled ? adapter.on : adapter.off)
    }

    private func setCharging(inhibited: Bool) {
        guard let inhibit else { return }
        for k in inhibit.keys { write(k, inhibited ? inhibit.inhibit : inhibit.allow) }
    }

    private func setLED(_ v: LEDValue) {
        guard ledAvailable else { return }
        if v == .system {
            guard ledOwned else { return }   // ne jamais forcer « système » si on n'a rien touché
            write(ledKey, [v.rawValue]); ledOwned = false
        } else {
            write(ledKey, [v.rawValue]); ledOwned = true
        }
    }

    var adapterDisabled: Bool {
        guard let adapter, let b = try? smc?.read(adapter.key) else { return false }
        return b != adapter.on
    }

    // MARK: Boucle de décision

    func evaluate() {
        guard let b = BatteryReader.read() else { activity = nil; return }
        var cutAdapter = false
        var inhibitCharge = false
        var act: String?

        if b.adapterPresent && b.percent > safetyFloor {
            if let t = policy.dischargeTarget {
                if b.percent > t {
                    cutAdapter = true
                    act = "Décharge forcée jusqu'à \(t) %"
                } else {
                    policy.dischargeTarget = nil   // objectif atteint : opération ponctuelle
                    save()
                }
            }
            if !cutAdapter, let limit = policy.softLimit {
                if b.percent >= limit { sailing = true }
                else if b.percent <= limit - policy.sailingRange { sailing = false }
                if sailing {
                    if inhibit != nil {
                        inhibitCharge = true
                        act = "Charge suspendue à \(limit) %"
                    } else if adapter != nil {
                        cutAdapter = true
                        act = "Limite logicielle \(limit) % : redescente à \(limit - policy.sailingRange) %"
                    }
                }
            }
        } else {
            sailing = false
            // Débranché : une décharge forcée en cours est annulée (pas de reprise
            // surprise au prochain branchement, peut-être des jours plus tard).
            if !b.adapterPresent && policy.dischargeTarget != nil {
                policy.dischargeTarget = nil
                save()
            }
        }

        setAdapter(enabled: !cutAdapter)
        setCharging(inhibited: inhibitCharge)
        activity = act

        switch policy.magSafeLED {
        case .system: setLED(.system)
        case .off: setLED(.off)
        case .smart:
            if !b.adapterPresent { setLED(.system) }
            else if cutAdapter { setLED(.off) }
            else if b.isCharging && !b.fullyCharged { setLED(.orange) }
            else { setLED(.green) }
        }
    }

    /// Avant la veille : on ne laisse jamais l'adaptateur coupé (la batterie se
    /// viderait Mac endormi). L'inhibition de charge, elle, peut rester.
    func prepareForSleep() {
        setAdapter(enabled: true)
        log.info("veille : adaptateur rétabli")
    }

    /// Arrêt / désinstallation : tout remettre comme le firmware l'attend.
    func restore() {
        setAdapter(enabled: true)
        setCharging(inhibited: false)
        if ledAvailable { ledOwned = true; setLED(.system) }
        log.info("état d'origine rétabli")
    }

    func status() -> HelperStatus {
        HelperStatus(version: HelperConstants.version,
                     isRoot: getuid() == 0,
                     adapterKeyAvailable: adapter != nil,
                     ledKeyAvailable: ledAvailable,
                     adapterDisabled: adapterDisabled,
                     ledValue: (try? smc?.read(ledKey))?.first.map(Int.init),
                     policy: policy,
                     activity: activity,
                     lastError: lastError)
    }
}

// MARK: - Service XPC

final class HelperService: NSObject, PlafondHelperProtocol {
    let engine: Engine
    init(engine: Engine) { self.engine = engine }

    private func onMain<T>(_ work: @escaping () -> T, _ reply: @escaping (T) -> Void) {
        DispatchQueue.main.async { reply(work()) }
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    func getStatus(withReply reply: @escaping (Data) -> Void) {
        onMain({ (try? JSONEncoder().encode(self.engine.status())) ?? Data() }, reply)
    }

    func setPolicy(_ policy: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let p = try? JSONDecoder().decode(HelperPolicy.self, from: policy) else {
            reply(nil, "politique illisible"); return
        }
        DispatchQueue.main.async {
            self.engine.setPolicy(p)
            reply(try? JSONEncoder().encode(self.engine.status()), nil)
        }
    }

    func uninstall(withReply reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.engine.restore()
            reply(true)
            // Laisser partir la réponse, puis se retirer de launchd.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.removeItem(atPath: HelperConstants.launchdPlist)
                try? FileManager.default.removeItem(atPath: HelperConstants.installedPath)
                try? FileManager.default.removeItem(atPath: HelperConstants.stateDir)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["bootout", "system/\(HelperConstants.bundleID)"]
                try? p.run()
                exit(0)
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: HelperService
    init(service: HelperService) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Seule l'app Plafond signée avec NOTRE certificat peut parler au helper.
        // (Équivalent manuel : SecCodeCopyGuestWithAttributes
        // + audit token + exigence SMAuthorizedClients.)
        c.setCodeSigningRequirement(BuildConfig.clientRequirement)
        c.exportedInterface = NSXPCInterface(with: PlafondHelperProtocol.self)
        c.exportedObject = service
        c.resume()
        log.info("connexion client pid=\(c.processIdentifier)")
        return true
    }
}

// MARK: - Notifications système

let engine = Engine()

// Changement de source d'alimentation (branchement, % qui bouge…)
let psSource = IOPSNotificationCreateRunLoopSource({ _ in engine.evaluate() }, nil)?.takeRetainedValue()
if let psSource { CFRunLoopAddSource(CFRunLoopGetMain(), psSource, .defaultMode) }

// Veille / réveil — macros iokit_common_msg() non importées en Swift :
// sys_iokit (0xE0000000) | sub_iokit_common (0) | code.
let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300
var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var notifyPort: IONotificationPortRef?
rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, argument in
    switch messageType {
    case kMsgCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kMsgSystemWillSleep:
        engine.prepareForSleep()
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kMsgSystemHasPoweredOn:
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { engine.evaluate() }
    default: break
    }
}, &notifier)
if let notifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
}

// Filet de sécurité périodique (le SMC peut être réinitialisé par le firmware)
let timer = Timer(timeInterval: 20, repeats: true) { _ in engine.evaluate() }
RunLoop.main.add(timer, forMode: .default)

// Arrêt propre
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { log.info("signal \(sig) : restauration"); engine.restore(); exit(0) }
    s.resume()
    signalSources.append(s)
}

let delegate = ListenerDelegate(service: HelperService(engine: engine))
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()

engine.evaluate()
log.info("Plafond helper \(HelperConstants.version, privacy: .public) prêt (uid \(getuid()))")
RunLoop.main.run()
