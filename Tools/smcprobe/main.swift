import Foundation

// Sonde SMC en lecture seule (aucun privilège requis).
//   smcprobe              → clés de contrôle batterie connues + valeurs
//   smcprobe --all PREFIX → énumère toutes les clés commençant par PREFIX
//   smcprobe KEY…         → lit des clés précises

let smc: SMC
do { smc = try SMC() } catch { print("ERREUR : \(error)"); exit(1) }

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

func dump(_ key: String) {
    do {
        let info = try smc.keyInfo(key)
        let bytes = try smc.read(key)
        let num = SMC.decode(bytes, type: info.type).map { String(format: "%.2f", $0) } ?? ""
        print(String(format: "  %@  %@ %2d o  [%@]  %@", key, info.type, info.size, hex(bytes), num))
    } catch {
        print("  \(key)  — \(error)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--all" {
    let prefix = args.count > 1 ? args[1] : ""
    let n = (try? smc.keyCount()) ?? 0
    print("#KEY = \(n)")
    for i in 0..<n {
        guard let k = try? smc.key(at: i), k.hasPrefix(prefix) else { continue }
        dump(k)
    }
} else if !args.isEmpty {
    args.forEach(dump)
} else {
    print("#KEY = \((try? smc.keyCount()) ?? -1)")
    let groups: [(String, [String])] = [
        ("Charge (inhibition)", ["CH0B", "CH0C", "CHTE", "BCLM", "CHWA", "CH0K"]),
        ("Adaptateur (décharge forcée)", ["CH0I", "CHIE", "CH0J"]),
        ("LED MagSafe", ["ACLC", "MSLD"]),
        ("Mesures", ["BRSC", "BUIC", "B0CM", "B0UC", "B0AC", "B0AV", "TB0T", "TB1T", "TB2T", "PSTR", "PDTR", "PPBR", "AC-W", "ACIN", "CHSC", "CHDB", "CHCC", "CHNC", "BSIn", "BFCL"]),
    ]
    for (title, keys) in groups {
        print("\n[\(title)]")
        keys.forEach(dump)
    }
}
