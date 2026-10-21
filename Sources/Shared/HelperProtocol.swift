import Foundation

// Contrat partagé entre l'app (client) et le helper root (serveur XPC).
//
// Choix de conception : plutôt que des primitives génériques
// (setSMCByte(key:value:) pour N'IMPORTE QUELLE clé), le helper n'accepte
// qu'une POLITIQUE de haut niveau et décide lui-même des écritures, sur une
// liste blanche de clés (CHIE, ACLC…). Un client compromis ne peut donc pas
// écrire de clé SMC arbitraire.

public enum HelperConstants {
    public static let machService = "com.polat.plafond.helper"
    public static let bundleID = "com.polat.plafond.helper"
    public static let version = "1.0.0"
    public static let installedPath = "/Library/PrivilegedHelperTools/com.polat.plafond.helper"
    public static let launchdPlist = "/Library/LaunchDaemons/com.polat.plafond.helper.plist"
    public static let stateDir = "/Library/Application Support/Plafond"
}

@objc(PlafondHelperProtocol)
public protocol PlafondHelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    /// Statut JSON (HelperStatus).
    func getStatus(withReply reply: @escaping (Data) -> Void)
    /// Remplace la politique (JSON HelperPolicy). Réponse : statut JSON ou message d'erreur.
    func setPolicy(_ policy: Data, withReply reply: @escaping (Data?, String?) -> Void)
    /// Rétablit l'état d'origine (adaptateur, LED) puis se retire de launchd.
    func uninstall(withReply reply: @escaping (Bool) -> Void)
}

public enum LEDMode: String, Codable, CaseIterable, Sendable {
    case system      // le firmware décide (valeur ACLC 0)
    case off         // éteinte (1)
    case smart       // verte quand la charge est en pause/pleine, orange en charge

    public var label: String {
        switch self {
        case .system: return "Système"
        case .off: return "Éteinte"
        case .smart: return "Intelligente"
        }
    }
}

public struct HelperPolicy: Codable, Equatable, Sendable {
    /// Décharge forcée (adaptateur coupé) jusqu'à ce pourcentage, puis retour à la normale.
    public var dischargeTarget: Int?
    /// Limite logicielle sous 80 % (expérimental) : coupe l'adaptateur au-dessus,
    /// le rétablit sous (limite − sailingRange).
    public var softLimit: Int?
    public var sailingRange: Int
    public var magSafeLED: LEDMode

    public init(dischargeTarget: Int? = nil, softLimit: Int? = nil, sailingRange: Int = 5, magSafeLED: LEDMode = .system) {
        self.dischargeTarget = dischargeTarget
        self.softLimit = softLimit
        self.sailingRange = sailingRange
        self.magSafeLED = magSafeLED
    }

    /// Bornes de sécurité appliquées côté helper, quoi que demande le client.
    public func sanitized() -> HelperPolicy {
        var p = self
        p.dischargeTarget = dischargeTarget.map { min(max($0, 15), 100) }
        p.softLimit = softLimit.map { min(max($0, 20), 100) }
        p.sailingRange = min(max(sailingRange, 2), 20)
        return p
    }
}

public struct HelperStatus: Codable, Sendable {
    public var version: String
    public var isRoot: Bool
    public var adapterKeyAvailable: Bool   // CHIE présente
    public var ledKeyAvailable: Bool       // ACLC présente
    public var adapterDisabled: Bool       // CHIE ≠ 0
    public var ledValue: Int?
    public var policy: HelperPolicy
    public var activity: String?           // ce que le helper est en train de faire
    public var lastError: String?
}
