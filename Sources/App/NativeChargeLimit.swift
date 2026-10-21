import Foundation

// Limite de charge NATIVE de macOS 26+ (« Manual Charge Limit », MCL), pilotée
// par le démon root PowerUIAgent via le service XPC
// com.apple.powerui.smartChargeManager. Le client est la classe privée
// PowerUISmartChargeClient (PowerUI.framework), appelée ici par le runtime
// Objective-C : pas d'en-tête, pas d'édition de liens avec le framework privé.
//
// Constaté sur MacBook Air M4 / macOS 27 :
//  • lecture ET écriture sans privilèges ni entitlement (appelable
//    depuis son app, pas depuis son helper) ;
//  • limites acceptées : availableChargeLimitsWithError: → [80, 85, 90, 95, 100] ;
//  • PowerUIAgent possède com.apple.private.iokit.soc-limit : c'est lui qui
//    coupe réellement la charge, la limite tient donc app fermée.

@MainActor
final class NativeChargeLimit {
    struct State: Equatable {
        var supported = false
        var enabled = false
        var suspended = false      // « 100 % une fois » en cours (MCLTempDisabledUntilDate)
        var rawState: UInt64 = 0
        var limit = 100
        var available: [Int] = [80, 85, 90, 95, 100]
        var optimizedChargingEnabled = false
    }

    private let client: NSObject?

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let c = allocated.perform(NSSelectorFromString("initWithClientName:"), with: "com.polat.plafond")?
                .takeUnretainedValue() as? NSObject
        else { client = nil; return }
        client = c
    }

    var isAvailable: Bool { client != nil }

    // MARK: Appels typés (signatures relevées par class_copyMethodList)

    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias ErrU64 = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt64
    private typealias ErrU8 = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt8
    private typealias ErrObj = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
    private typealias ErrBool = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    private typealias SetU8 = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>) -> Bool

    private func fn<T>(_ name: String, _: T.Type) -> (Selector, T)? {
        let sel = NSSelectorFromString(name)
        guard let client, client.responds(to: sel) else { return nil }
        return (sel, unsafeBitCast(client.method(for: sel), to: T.self))
    }

    private func call(_ name: String) throws -> Bool {
        guard let client, let (sel, f) = fn(name, ErrBool.self) else { throw NativeError.unavailable(name) }
        var err: NSError?
        let ok = f(client, sel, &err)
        if let err { throw err }
        return ok
    }

    // MARK: API

    func read() -> State {
        var s = State()
        guard let client else { return s }
        if let (sel, f) = fn("isMCLSupported", BoolGetter.self) { s.supported = f(client, sel) }
        var err: NSError?
        if let (sel, f) = fn("isMCLCurrentlyEnabled:", ErrU64.self) {
            s.rawState = f(client, sel, &err)
            s.enabled = s.rawState == 1
            s.suspended = s.rawState >= 2
        }
        if let (sel, f) = fn("getMCLLimitWithError:", ErrU8.self) {
            let v = Int(f(client, sel, &err)); if v > 0 { s.limit = v }
        }
        if let (sel, f) = fn("availableChargeLimitsWithError:", ErrObj.self),
           let arr = f(client, sel, &err) as? [NSNumber], !arr.isEmpty {
            s.available = arr.map(\.intValue).sorted()
        }
        if let (sel, f) = fn("isSmartChargingCurrentlyEnabled:", ErrU64.self) {
            s.optimizedChargingEnabled = f(client, sel, &err) == 1
        }
        return s
    }

    /// Active la limite native à `percent` (doit appartenir à `available`).
    /// Activation d'abord, valeur ensuite, puis relecture : on ne présume pas
    /// de ce que enableMCL: fait de la valeur précédemment enregistrée.
    func apply(percent: Int, enable: Bool) throws {
        guard let client, let (sel, f) = fn("setMCLLimit:error:", SetU8.self) else {
            throw NativeError.unavailable("setMCLLimit:error:")
        }
        if enable, !read().enabled { _ = try call("enableMCL:") }
        var err: NSError?
        let ok = f(client, sel, UInt8(clamping: percent), &err)
        if let err { throw err }
        guard ok else { throw NativeError.refused("setMCLLimit \(percent)") }
        let after = read()
        guard after.limit == percent else { throw NativeError.refused("limite relue \(after.limit) % au lieu de \(percent) %") }
    }

    func disable() throws {
        _ = try call("disableMCL:")
    }

    /// « Charger à 100 % une fois » : PowerUIAgent suspend la limite puis la
    /// réactive tout seul (MCLTempDisabledUntilDate).
    func chargeToFullOnce() throws {
        _ = try call("temporarilyDisableMCL:")
    }
}

enum NativeError: LocalizedError {
    case unavailable(String)
    case refused(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return "API PowerUI indisponible (\(s))"
        case .refused(let s): return "PowerUIAgent a refusé : \(s)"
        }
    }
}
