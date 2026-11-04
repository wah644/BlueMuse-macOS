import Foundation

public enum Sensor: String, CaseIterable, Codable {
    case eeg = "EEG", accelerometer = "Accelerometer", gyroscope = "Gyroscope", ppg = "PPG", telemetry = "Telemetry"
    public var rate: Double { switch self { case .eeg: return 256; case .accelerometer, .gyroscope: return 52; case .ppg: return 64; case .telemetry: return 0.1 } }
    public func chunkSize(athena: Bool = false) -> Int {
        switch self { case .eeg: return athena ? 4 : 12; case .ppg: return athena ? 1 : 6; case .accelerometer, .gyroscope: return 3; case .telemetry: return 1 }
    }
    public var settingKey: String { rawValue.lowercased() + "_enabled" }
    public func labels(athena: Bool = false, aux: Bool = false) -> [String] {
        switch self {
        case .eeg: return ["TP9", "AF7", "AF8", "TP10"] + (aux ? ["Right AUX"] : [])
        case .accelerometer, .gyroscope: return ["X", "Y", "Z"]
        case .ppg: return athena ? (0..<16).map { "OPTICS\($0)" } : ["PPG1", "PPG2", "PPG3"]
        case .telemetry: return athena ? ["Battery"] : ["Battery", "Unknown (fuel?)", "ADC Voltage", "Temperature"]
        }
    }
    public func unit(athena: Bool = false) -> String {
        switch self { case .eeg: return "microvolts"; case .accelerometer: return "g"; case .gyroscope: return "dps"; case .ppg: return athena ? "counts" : "mmHg"; case .telemetry: return athena ? "percent" : "Various" }
    }
}
public enum WireError: Error { case truncated }
public enum MuseWire {
    public static func command(_ s: String) -> Data { Data([UInt8(s.utf8.count + 1)] + Array(s.utf8) + [10]) }
    public static func bits(_ b: [UInt8], _ offset: Int, _ count: Int, little: Bool = false) throws -> Int {
        guard offset >= 0, count > 0, count <= 24, offset + count <= b.count * 8 else { throw WireError.truncated }
        var v = 0
        for i in 0..<count { let p = offset + i; let bit = Int((b[p / 8] >> (little ? p % 8 : 7 - p % 8)) & 1); if little { v |= bit << i } else { v = v * 2 + bit } }
        return v
    }
    public static func legacyChannel(_ b: [UInt8], ppg: Bool = false) throws -> [Double] {
        try (0..<(ppg ? 6 : 12)).map { i in
            let v = try bits(b, 16 + i * (ppg ? 24 : 12), ppg ? 24 : 12)
            return ppg ? Double(v) : Double(v - 2048) * 0.48828125
        }
    }
    public static func legacyMotion(_ b: [UInt8], gyro: Bool) throws -> [[Double]] {
        try (0..<3).map { s in try (0..<3).map { c in
            let u = try bits(b, 16 + (s * 3 + c) * 16, 16)
            return Double(Int16(bitPattern: UInt16(u))) * (gyro ? 0.0074768 : 0.0000610352)
        } }
    }
    public static func telemetry(_ b: [UInt8]) throws -> [[Double]] {
        var row = try (0..<4).map { Double(try bits(b, 16 + $0 * 16, 16)) }; row[0] /= 512; row[1] *= 2.2; return [row]
    }
}
public struct AthenaPacket {
    public let tag: UInt8
    public let index: Int
    public let block: Int
    public let payload: [UInt8]
    public static func shape(_ tag: UInt8) -> (channels: Int, samples: Int, bytes: Int)? {
        switch tag { case 0x11: return (4,4,28); case 0x12: return (8,2,28); case 0x34: return (4,3,30); case 0x35: return (8,2,40); case 0x36: return (16,1,40); case 0x47: return (6,3,36); case 0x53: return (0,0,24); case 0x88: return (1,1,0); case 0x98: return (1,1,20); default: return nil }
    }
    public static func parse(_ b: [UInt8]) -> [AthenaPacket] {
        var result: [AthenaPacket] = []; var o = 0
        while o + 14 <= b.count {
            let end = o + Int(b[o]); guard end >= o + 14, end <= b.count else { break }
            let index = Int(b[o+1]) | Int(b[o+2]) << 8
            var p = o + 14; var tag = b[o+9]; var block = Int(b[o+10])
            while let shape = shape(tag) {
                let n = shape.bytes == 0 ? end - p : shape.bytes
                guard n > 0, p + n <= end else { break }
                result.append(.init(tag: tag, index: index, block: block, payload: Array(b[p..<p+n])))
                p += n; guard p + 5 <= end else { break }; tag = b[p]; block = Int(b[p+1]); p += 5
            }
            o = end
        }
        return result
    }
    public func decode() throws -> [(Sensor, [[Double]])] {
        guard let sh = Self.shape(tag) else { return [] }
        switch tag {
        case 0x11, 0x12:
            return [(.eeg, try (0..<sh.samples).map { s in try (0..<4).map { c in Double(try MuseWire.bits(payload, (s*sh.channels+c)*14, 14, little: true) - 8192) * 1450 / 16383 } })]
        case 0x34, 0x35, 0x36:
            return [(.ppg, try (0..<sh.samples).map { s in
                var row = Array(repeating: 0.0, count: 16)
                for c in 0..<sh.channels { row[c + (tag == 0x34 ? 4 : 0)] = Double(try MuseWire.bits(payload, (s*sh.channels+c)*20, 20, little: true)) }; return row
            })]
        case 0x47:
            let rows = try (0..<3).map { s in try (0..<6).map { c in
                let raw = try MuseWire.bits(payload, (s*6+c)*16, 16, little: true)
                return Double(Int16(bitPattern: UInt16(raw))) * (c < 3 ? 0.0000610352 : -0.0074768)
            } }
            return [(.accelerometer, rows.map { Array($0[0..<3]) }), (.gyroscope, rows.map { Array($0[3..<6]) })]
        case 0x88, 0x98: return [(.telemetry, [[Double(try MuseWire.bits(payload, 0, 16, little: true))/512]])]
        default: return []
        }
    }
}
// Stable host-anchored recursive least squares. A positive denominator keeps covariance positive.
public final class TimestampFit {
    private let anchor: Double
    private var slope: Double
    private var covariance = 1e-4
    private var index = 0
    private var lastTimestamp: Double?
    public init(rate: Double, arrival: Double) { anchor = arrival; slope = 1/rate }
    public func timestamps(count: Int, arrival: Double) -> [Double] {
        guard count > 0 else { return [] }
        let x = Double(index + count - 1)
        let gain = covariance * x / (1 + covariance*x*x)
        slope += gain * (arrival - anchor - x*slope)
        covariance /= 1 + covariance*x*x
        let spacing = max(slope, Double.ulpOfOne)
        var first = anchor + Double(index)*spacing
        if let lastTimestamp, first <= lastTimestamp { first = lastTimestamp + spacing }
        let result = (0..<count).map { first + Double($0)*spacing }
        lastTimestamp = result.last
        index += count; return result
    }
}
public enum TimestampMode: String, CaseIterable, Codable {
    case epoch = "BLUEMUSE", host = "LSL_LOCAL_CLOCK_BLUEMUSE", native = "LSL_LOCAL_CLOCK_NATIVE", none = "NONE"
    public var title: String { switch self { case .epoch: return "Unix epoch"; case .host: return "LSL clock · host"; case .native: return "LSL clock · native"; case .none: return "None" } }
}
public struct StreamSettings: Codable {
    public var timingBehavior: TimingBehavior = .windowsCompatible
    public var primary: TimestampMode = .epoch
    public var secondary: TimestampMode = .none
    public var double64 = false
    public var enabled = Set(Sensor.allCases.filter { $0 != .telemetry })
    public var alwaysPair = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case timingBehavior, primary, secondary, double64, enabled, alwaysPair }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        timingBehavior = try values.decodeIfPresent(TimingBehavior.self,forKey:.timingBehavior) ?? .windowsCompatible
        primary = try values.decodeIfPresent(TimestampMode.self,forKey:.primary) ?? .epoch
        secondary = try values.decodeIfPresent(TimestampMode.self,forKey:.secondary) ?? .none
        double64 = try values.decodeIfPresent(Bool.self,forKey:.double64) ?? false
        enabled = try values.decodeIfPresent(Set<Sensor>.self,forKey:.enabled) ?? Set(Sensor.allCases.filter { $0 != .telemetry })
        alwaysPair = try values.decodeIfPresent(Bool.self,forKey:.alwaysPair) ?? false
    }
    public mutating func set(key: String, value: String) -> Bool {
        let key = key.lowercased()
        switch key {
        case "timestamp_behavior": guard let b = TimingBehavior(rawValue:value.uppercased()) else { return false }; timingBehavior = b
        case "primary_timestamp_format": guard let m = TimestampMode(rawValue: value.uppercased()), m != .none else { return false }; primary = m
        case "secondary_timestamp_format": guard let m = TimestampMode(rawValue: value.uppercased()) else { return false }; secondary = m
        case "channel_data_type": guard ["float32", "double64"].contains(value.lowercased()) else { return false }; double64 = value.lowercased() == "double64"
        default:
            guard ["true","false"].contains(value.lowercased()) else { return false }
            if key == "always_pair" { alwaysPair = value.lowercased() == "true" }
            else if let s = Sensor.allCases.first(where: { $0.settingKey == key }) { if value.lowercased() == "true" { enabled.insert(s) } else { enabled.remove(s) } }
            else { return false }
        }; return true
    }
    public func sample(_ row: [Double], secondary time: Double) -> [Double] {
        guard secondary != .none else { return row }
        if double64 { return row + [time] }
        let base = Double(Float(time)); return row + [base, time-base]
    }
}
public struct ProtocolCommand {
    public let action: String
    public let arguments: [String: String]
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "bluemuse" else { return nil }
        action = (url.host ?? "").lowercased()
        var args: [String: String] = [:]
        for item in (url.query ?? "").replacingOccurrences(of: "!", with: "&").split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            args[String(pair[0]).lowercased()] = pair.count > 1 ? String(pair[1]).removingPercentEncoding ?? String(pair[1]) : "true"
        }; arguments = args
    }
}

public struct SignalPoint {
    public let time: Double
    public let values: [Double]
    public init(time: Double, values: [Double]) { self.time = time; self.values = values }
}
/// Bounded raw signal history for visualization, independent of the LSL outlet.
public final class SignalHistory {
    private var storage: [SignalPoint?]
    private var next = 0
    private var count = 0
    public init(capacity: Int) { storage = Array(repeating: nil, count: max(1, capacity)) }
    public func append(time: Double, values: [Double]) {
        storage[next] = SignalPoint(time: time, values: values)
        next = (next + 1) % storage.count; count = min(count+1, storage.count)
    }
    public func points(seconds: Double = 10) -> [SignalPoint] {
        guard count > 0, let latest = storage[(next+storage.count-1)%storage.count] else { return [] }
        let first = (next-count+storage.count)%storage.count
        return (0..<count).compactMap { storage[(first+$0)%storage.count] }.filter { $0.time >= latest.time-seconds }
    }
}

/// Reassembles command JSON across BLE notifications, including nested objects and
/// braces inside quoted strings. Malformed messages are ignored without crashing.
public struct ControlMessageBuffer {
    private var bytes: [UInt8] = []
    public init() {}
    public mutating func append(_ fragment: [UInt8]) -> [Data] {
        bytes += fragment
        if bytes.count > 16384 { bytes.removeAll(); return [] }
        var messages: [Data] = []; var start: Int?; var depth = 0
        var quoted = false; var escaped = false; var consumed = 0
        for (i,b) in bytes.enumerated() {
            if start == nil { if b == 123 { start = i; depth = 1 } else { consumed = i+1 }; continue }
            if quoted {
                if escaped { escaped = false } else if b == 92 { escaped = true } else if b == 34 { quoted = false }
            } else if b == 34 { quoted = true }
            else if b == 123 { depth += 1 }
            else if b == 125 {
                depth -= 1
                if depth == 0, let first = start {
                    let data = Data(bytes[first...i])
                    if (try? JSONSerialization.jsonObject(with:data)) != nil { messages.append(data) }
                    consumed = i+1; start = nil
                }
            }
        }
        if consumed > 0 { bytes.removeFirst(consumed) }
        return messages
    }
}
public struct MuseProfile {
    public let model: String
    public let deviceMetadata: String
    public let athena: Bool
    public let aux: Bool
    public let ppg: Bool
    public static func detect(name: String, characteristics: Set<Int>, museSSpecial: Bool = false) -> MuseProfile {
        if characteristics.contains(0x13) { return .init(model:"Muse S Athena",deviceMetadata:"Muse S Athena EEG Headset",athena:true,aux:false,ppg:true) }
        if name.uppercased().contains("SMXT") || name.uppercased().contains("SMTX") { return .init(model:"Smith Lowdown Focus",deviceMetadata:"Smith Lowdown Focus",athena:false,aux:false,ppg:false) }
        if name.contains("MuseS") || museSSpecial { return .init(model:"Muse S",deviceMetadata:"Muse S EEG Headset",athena:false,aux:false,ppg:true) }
        if characteristics.contains(0xf) { return .init(model:"Muse 2",deviceMetadata:"Muse 2 EEG Headset",athena:false,aux:true,ppg:true) }
        return .init(model:"Muse 2016",deviceMetadata:"Muse EEG Headset",athena:false,aux:true,ppg:false)
    }
}
