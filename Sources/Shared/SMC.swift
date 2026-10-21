import Foundation
import IOKit

// Accès bas niveau au System Management Controller via le user-client AppleSMC.
//
// Le pilote expose un seul sélecteur (2 = kSMCHandleYPCEvent) qui prend et rend
// une structure C de 80 octets (SMCKeyData_t). Plutôt que de dépendre de la
// disposition mémoire d'une struct Swift, on manipule un tampon brut aux
// offsets calculés selon les règles d'alignement C :
//
//   0  key            UInt32 (FourCC)
//   4  vers           6 o  (+2 o de bourrage)
//   12 pLimitData     16 o
//   28 keyInfo.dataSize   UInt32
//   32 keyInfo.dataType   UInt32 (FourCC : ui8 , ui32, flt , sp78, hex_…)
//   36 keyInfo.dataAttributes UInt8 (+3 o de bourrage)
//   40 result UInt8 · 41 status UInt8 · 42 data8 (commande) UInt8
//   44 data32 UInt32
//   48 bytes[32]
//
// Lecture : possible sans privilèges. Écriture : root obligatoire
// (kIOReturnNotPrivileged sinon) → c'est le rôle du helper.

public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case smcResult(String, UInt8)
    case badSize(String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .driverNotFound: return "pilote AppleSMC introuvable"
        case .openFailed(let kr): return "IOServiceOpen a échoué (0x\(String(UInt32(bitPattern: kr), radix: 16)))"
        case .callFailed(let kr):
            if kr == kIOReturnNotPrivileged { return "écriture SMC refusée : privilèges root requis" }
            return "IOConnectCallStructMethod a échoué (0x\(String(UInt32(bitPattern: kr), radix: 16)))"
        case .keyNotFound(let k): return "clé SMC \(k) absente"
        case .smcResult(let k, let r): return "SMC a répondu \(r) pour \(k)"
        case .badSize(let k, let e, let g): return "taille inattendue pour \(k) : \(g) au lieu de \(e)"
        }
    }
}

public struct SMCKeyInfo: Sendable {
    public let size: Int
    public let type: String
}

public final class SMC {
    private enum Cmd: UInt8 { case read = 5, write = 6, keyFromIndex = 8, keyInfo = 9 }
    private static let kSMCKeyNotFound: UInt8 = 132
    private static let bufSize = 80

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
    }

    deinit { IOServiceClose(conn) }

    // MARK: FourCC

    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func string(_ v: UInt32) -> String {
        let b = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        return String(decoding: b, as: UTF8.self)
    }

    // MARK: Appel brut

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var inBuf = input
        var outBuf = [UInt8](repeating: 0, count: Self.bufSize)
        var outSize = Self.bufSize
        let kr = IOConnectCallStructMethod(conn, 2, &inBuf, Self.bufSize, &outBuf, &outSize)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        return outBuf
    }

    private static func put32(_ v: UInt32, _ buf: inout [UInt8], at off: Int) {
        withUnsafeBytes(of: v) { for i in 0..<4 { buf[off + i] = $0[i] } }  // ordre natif
    }

    private static func get32(_ buf: [UInt8], at off: Int) -> UInt32 {
        buf[off..<off + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    // MARK: API

    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        let k = Self.fourCC(key)
        if let cached = infoCache[k] { return cached }
        var input = [UInt8](repeating: 0, count: Self.bufSize)
        Self.put32(k, &input, at: 0)
        input[42] = Cmd.keyInfo.rawValue
        let out = try call(input)
        if out[40] == Self.kSMCKeyNotFound { throw SMCError.keyNotFound(key) }
        guard out[40] == 0 else { throw SMCError.smcResult(key, out[40]) }
        let info = SMCKeyInfo(size: Int(Self.get32(out, at: 28)),
                              type: Self.string(Self.get32(out, at: 32)))
        infoCache[k] = info
        return info
    }

    public func exists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    public func read(_ key: String) throws -> [UInt8] {
        let info = try keyInfo(key)
        var input = [UInt8](repeating: 0, count: Self.bufSize)
        Self.put32(Self.fourCC(key), &input, at: 0)
        Self.put32(UInt32(info.size), &input, at: 28)
        input[42] = Cmd.read.rawValue
        let out = try call(input)
        if out[40] == Self.kSMCKeyNotFound { throw SMCError.keyNotFound(key) }
        guard out[40] == 0 else { throw SMCError.smcResult(key, out[40]) }
        return Array(out[48..<48 + min(info.size, 32)])
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard info.size == bytes.count else { throw SMCError.badSize(key, expected: info.size, got: bytes.count) }
        var input = [UInt8](repeating: 0, count: Self.bufSize)
        Self.put32(Self.fourCC(key), &input, at: 0)
        Self.put32(UInt32(info.size), &input, at: 28)
        input[42] = Cmd.write.rawValue
        for (i, b) in bytes.enumerated() { input[48 + i] = b }
        let out = try call(input)
        guard out[40] == 0 else { throw SMCError.smcResult(key, out[40]) }
    }

    public func keyCount() throws -> Int {
        let b = try read("#KEY")
        return b.prefix(4).reduce(0) { ($0 << 8) | Int($1) }  // ui32 big-endian
    }

    public func key(at index: Int) throws -> String {
        var input = [UInt8](repeating: 0, count: Self.bufSize)
        input[42] = Cmd.keyFromIndex.rawValue
        Self.put32(UInt32(index), &input, at: 44)
        let out = try call(input)
        guard out[40] == 0 else { throw SMCError.smcResult("#\(index)", out[40]) }
        return Self.string(Self.get32(out, at: 0))
    }

    // MARK: Décodage des types courants

    /// Sur Apple Silicon, les clés batterie/charge en ui16/ui32/flt sont en
    /// little-endian (B0AV = f6 2c → 11510 mV), alors que les clés « classiques »
    /// héritées d'Intel (#KEY…) restent en big-endian.
    public static func decode(_ bytes: [UInt8], type: String, littleEndian: Bool = true) -> Double? {
        func uint(_ n: Int) -> UInt64 {
            let b = littleEndian ? bytes.prefix(n).reversed() : Array(bytes.prefix(n))
            return b.reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "ui8 ", "si8 ":
            guard let b = bytes.first else { return nil }
            return type == "si8 " ? Double(Int8(bitPattern: b)) : Double(b)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(uint(2))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(uint(2))))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(uint(4))
        case "sp78":  // virgule fixe signée 8.8, big-endian
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "flt ":  // float32 little-endian sur Apple Silicon
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        default:
            return nil
        }
    }

    public func readNumber(_ key: String) throws -> Double? {
        let info = try keyInfo(key)
        return Self.decode(try read(key), type: info.type)
    }
}
