import Foundation

public enum TimingBehavior: String, CaseIterable, Codable {
    case windowsCompatible = "WINDOWS_COMPATIBLE"
    case smoothed = "SMOOTHED"
    public var title: String { self == .windowsCompatible ? "Windows compatible" : "Smoothed sample clock" }
    public var note: String {
        self == .windowsCompatible
        ? "Uses the original BlueMuse timestamp rules. Bluetooth arrival jitter can produce uneven or backwards times. This matches the software rules, not identical timing across operating systems."
        : "Fits a steady sample clock and keeps timestamps increasing. Changes timestamps only, not sensor values. More accurate acquisition timing has not been established."
    }
}
/// One independent clock per sensor and timestamp channel. Recreate at stream start.
public final class SampleTimestampClock {
    private let sensor: Sensor
    private let athena: Bool
    private let rate: Double
    private let behavior: TimingBehavior
    private let domain: TimestampMode
    private var smooth: TimestampFit?
    private var originalAthena: OriginalAthenaClock?
    public init(sensor: Sensor, athena: Bool, behavior: TimingBehavior, domain: TimestampMode) {
        self.sensor = sensor; self.athena = athena; self.behavior = behavior; self.domain = domain
        rate = athena && sensor == .telemetry ? 1 : sensor.rate
    }
    public func timestamps(count: Int, arrival: Double) -> [Double] {
        guard count > 0 else { return [] }
        if behavior == .windowsCompatible {
            // Windows GetNow().ToUnixTimeMilliseconds() discards sub-millisecond time.
            let arrival = domain == .epoch ? floor(arrival*1000)/1000 : arrival
            if athena {
                if sensor == .telemetry { return Array(repeating:arrival,count:count) }
                if originalAthena == nil { originalAthena = OriginalAthenaClock(rate:rate,arrival:arrival) }
                return originalAthena!.timestamps(count:count,arrival:arrival)
            }
            // Preserve the original float32 millisecond sample-interval constants.
            let interval = Double(Float(1000)/Float(rate))/1000
            return (0..<count).map { arrival-Double(count-$0)*interval }
        }
        if sensor == .telemetry { return Array(repeating:arrival,count:count) }
        if smooth == nil { smooth = TimestampFit(rate:rate,arrival:athena ? arrival : arrival-Double(count)/rate) }
        return smooth!.timestamps(count:count,arrival:athena ? arrival : arrival-1/rate)
    }
}
/// Literal port of the supplied C# AthenaTimestampCorrector, including its covariance rule.
private final class OriginalAthenaClock {
    let anchor: Double
    var slope: Double
    var p = 1e-4
    var sampleIndex = 0
    init(rate: Double, arrival: Double) { anchor = arrival; slope = 1/rate }
    func timestamps(count: Int, arrival: Double) -> [Double] {
        let lastIndex = Double(sampleIndex+count-1)
        let squared = lastIndex*lastIndex
        let denominator = 1-p*squared
        if denominator != 0 {
            p = p-((p*p)*squared)/denominator
            slope = slope+p*lastIndex*(arrival-anchor-lastIndex*slope)
        }
        let result = (0..<count).map { anchor+Double(sampleIndex+$0)*slope }
        sampleIndex += count
        return result
    }
}
