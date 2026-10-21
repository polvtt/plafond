import Foundation
import IOKit

// Lecture de l'état batterie depuis l'IORegistry (classe AppleSmartBattery).
// Aucune autorisation requise. Les clés ont été relevées avec
// `ioreg -rn AppleSmartBattery -a` sur un MacBook Air M4 / macOS 27.

public struct BatterySnapshot: Sendable, Equatable {
    public var percent: Int = 0
    public var isCharging = false
    public var externalConnected = false     // alimentation utilisée par le système
    public var adapterPresent = false        // câble physiquement branché (AppleRaw…)
    public var fullyCharged = false
    public var cycleCount = 0
    public var designCycleCount = 1000
    public var designCapacity = 0            // mAh
    public var nominalCapacity = 0           // mAh
    public var fullChargeCapacity = 0        // mAh
    public var remainingCapacity = 0         // mAh
    public var voltage = 0                   // mV
    public var amperage = 0                  // mA (signé : > 0 en charge)
    public var timeToFull: Int?              // minutes
    public var timeToEmpty: Int?             // minutes
    public var notChargingReason = 0
    public var adapterName: String?
    public var adapterWatts: Int?
    public var systemPowerIn: Double?        // W fournis par l'adaptateur
    public var systemLoad: Double?           // W consommés par le Mac
    public var temperature: Double?          // °C (rempli par le SMC côté app)
    public var serial: String?

    /// Puissance batterie en W (signée : > 0 en charge).
    public var batteryPower: Double { Double(voltage) * Double(amperage) / 1_000_000 }

    /// « Capacité maximale » à la manière de Réglages Système.
    public var health: Double? {
        guard designCapacity > 0, nominalCapacity > 0 else { return nil }
        return min(1, Double(nominalCapacity) / Double(designCapacity))
    }

    public init() {}
}

public enum BatteryReader {
    public static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ d: [String: Any]?, _ k: String) -> Int? { (d?[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool { (props[k] as? NSNumber)?.boolValue ?? false }

        var s = BatterySnapshot()
        let data = props["BatteryData"] as? [String: Any]
        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        let charger = props["ChargerData"] as? [String: Any]
        let adapter = props["AdapterDetails"] as? [String: Any]

        s.percent = int(props, "CurrentCapacity") ?? 0
        s.isCharging = bool("IsCharging")
        s.externalConnected = bool("ExternalConnected")
        s.adapterPresent = (props["AppleRawExternalConnected"] as? NSNumber)?.boolValue ?? s.externalConnected
        s.fullyCharged = bool("FullyCharged")
        s.cycleCount = int(props, "CycleCount") ?? 0
        s.designCycleCount = int(props, "DesignCycleCount9C") ?? 1000
        s.designCapacity = int(data, "DesignCapacity") ?? int(props, "DesignCapacity") ?? 0
        s.nominalCapacity = int(data, "NominalChargeCapacity") ?? int(props, "NominalChargeCapacity") ?? 0
        s.fullChargeCapacity = int(data, "FullChargeCapacity") ?? int(props, "AppleRawMaxCapacity") ?? 0
        s.remainingCapacity = int(data, "RemainingCapacity") ?? int(props, "AppleRawCurrentCapacity") ?? 0
        s.voltage = int(props, "Voltage") ?? int(props, "AppleRawBatteryVoltage") ?? 0
        s.amperage = int(props, "InstantAmperage") ?? int(props, "Amperage") ?? 0
        if let t = int(props, "AvgTimeToFull"), t > 0, t < 65535 { s.timeToFull = t }
        if let t = int(props, "AvgTimeToEmpty"), t > 0, t < 65535 { s.timeToEmpty = t }
        s.notChargingReason = int(charger, "NotChargingReason") ?? 0
        s.serial = props["Serial"] as? String

        if s.adapterPresent, let adapter {
            s.adapterName = adapter["Name"] as? String ?? adapter["Description"] as? String
            s.adapterWatts = int(adapter, "Watts")
        }
        if let w = int(telemetry, "SystemPowerIn") { s.systemPowerIn = Double(w) / 1000 }
        if let w = int(telemetry, "SystemLoad") { s.systemLoad = Double(w) / 1000 }
        if let t = int(props, "Temperature") { s.temperature = Double(t) / 100 }
        return s
    }
}
