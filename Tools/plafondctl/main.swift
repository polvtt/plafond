import Foundation

// plafondctl — pilotage de Plafond en ligne de commande (scripts, Raccourcis).
//
//   plafondctl status                  état batterie + limite native + helper
//   plafondctl limit 80|85|…|100|off   limite native macOS (sans helper)
//   plafondctl topup                   charger à 100 % une fois
//   plafondctl discharge <N>|off       décharge forcée jusqu'à N %   (helper)
//   plafondctl softlimit <N>|off       limite logicielle             (helper)
//   plafondctl led system|off|smart    LED MagSafe                   (helper)
//
// Option --user : helper lancé en agent utilisateur (mode développement).

let args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--user" }
let userDomain = CommandLine.arguments.contains("--user")

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(msg)\n".utf8)); exit(1)
}

// MARK: Helper (XPC synchrone)

func withHelper<T>(_ body: (PlafondHelperProtocol, @escaping (T) -> Void) -> Void) -> T {
    let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: userDomain ? [] : .privileged)
    c.remoteObjectInterface = NSXPCInterface(with: PlafondHelperProtocol.self)
    c.setCodeSigningRequirement(BuildConfig.helperRequirement)
    c.resume()
    defer { c.invalidate() }
    let sem = DispatchSemaphore(value: 0)
    var result: T?
    var xpcError: Error?
    guard let proxy = c.remoteObjectProxyWithErrorHandler({ xpcError = $0; sem.signal() }) as? PlafondHelperProtocol else {
        fail("proxy XPC indisponible")
    }
    body(proxy) { result = $0; sem.signal() }
    if sem.wait(timeout: .now() + 5) == .timedOut { fail("le helper ne répond pas") }
    if let xpcError { fail("helper injoignable : \(xpcError.localizedDescription)") }
    return result!
}

func helperStatus() -> HelperStatus? {
    let data: Data = withHelper { p, done in p.getStatus(withReply: done) }
    return try? JSONDecoder().decode(HelperStatus.self, from: data)
}

func updatePolicy(_ change: (inout HelperPolicy) -> Void) {
    guard var policy = helperStatus()?.policy else { fail("statut du helper illisible") }
    change(&policy)
    let data = try! JSONEncoder().encode(policy)
    let (reply, err): (Data?, String?) = withHelper { p, done in p.setPolicy(data) { done(($0, $1)) } }
    if let err { fail(err) }
    if let reply, let s = try? JSONDecoder().decode(HelperStatus.self, from: reply) {
        print("✓ politique appliquée\(s.activity.map { " — \($0)" } ?? "")")
    }
}

func percentArg(_ i: Int) -> Int? {
    guard args.count > i else { fail("argument manquant") }
    if args[i] == "off" { return nil }
    guard let v = Int(args[i]), (0...100).contains(v) else { fail("pourcentage invalide : \(args[i])") }
    return v
}

// MARK: Commandes

MainActor.assumeIsolated {
    let native = NativeChargeLimit()
    switch args.first ?? "status" {
    case "status":
        if let b = BatteryReader.read() {
            print("Batterie     \(b.percent) %  \(b.isCharging ? "en charge" : b.adapterPresent ? "branché, sans charge" : "sur batterie")")
            print("Santé        \(b.health.map { String(format: "%.0f %%", $0 * 100) } ?? "?")  ·  \(b.cycleCount) cycles")
            if let a = b.adapterName { print("Adaptateur   \(a)") }
        }
        let n = native.read()
        let etat = n.enabled ? "\(n.limit) %" : n.suspended ? "\(n.limit) % (suspendue jusqu'à 100 %)" : "désactivée"
        print("Limite native \(n.supported ? etat : "non prise en charge")  (choix : \(n.available.map(String.init).joined(separator: "/")), état brut \(n.rawState))")
        if FileManager.default.fileExists(atPath: HelperConstants.launchdPlist) || userDomain {
            if let s = helperStatus() {
                print("Helper       v\(s.version)  root:\(s.isRoot)  adaptateur:\(s.adapterKeyAvailable ? "CHIE" : "–")  LED:\(s.ledKeyAvailable)")
                print("Politique    décharge→\(s.policy.dischargeTarget.map { "\($0) %" } ?? "–")  logicielle:\(s.policy.softLimit.map { "\($0) %" } ?? "–")  LED:\(s.policy.magSafeLED.rawValue)")
                if let a = s.activity { print("Activité     \(a)") }
                if let e = s.lastError { print("Erreur       \(e)") }
            }
        } else {
            print("Helper       non installé")
        }
    case "limit":
        do {
            if let v = percentArg(1) { try native.apply(percent: v, enable: true); print("✓ limite native : \(v) %") }
            else { try native.disable(); print("✓ limite native désactivée") }
        } catch { fail(error.localizedDescription) }
    case "topup":
        do { try native.chargeToFullOnce(); print("✓ charge jusqu'à 100 % (une fois)") } catch { fail(error.localizedDescription) }
    case "discharge":
        let v = percentArg(1); updatePolicy { $0.dischargeTarget = v }
    case "softlimit":
        let v = percentArg(1); updatePolicy { $0.softLimit = v }
    case "led":
        guard args.count > 1, let mode = LEDMode(rawValue: args[1]) else { fail("led system|off|smart") }
        updatePolicy { $0.magSafeLED = mode }
    default:
        print("Usage : plafondctl status | limit <N|off> | topup | discharge <N|off> | softlimit <N|off> | led <system|off|smart>")
    }
}
