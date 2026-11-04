import Foundation
import Darwin
import BlueMuseCore

// Use the official C ABI; a runtime load also lets the UI explain a missing library.
final class LSL {
    static let shared = LSL()
    let handle: UnsafeMutableRawPointer?
    let path: String
    let error: String?
    init() {
        let candidates = [ProcessInfo.processInfo.environment["BLUEMUSE_LSL_LIBRARY"], Bundle.main.privateFrameworksPath.map { $0 + "/lsl.framework/lsl" }, Bundle.main.privateFrameworksPath.map { $0 + "/liblsl.dylib" }, "/Library/Frameworks/lsl.framework/lsl", "/opt/homebrew/lib/liblsl.dylib", "/usr/local/lib/liblsl.dylib", FileManager.default.currentDirectoryPath + "/Vendor/lsl.framework/lsl"].compactMap { $0 }
        var loaded: UnsafeMutableRawPointer?; var found = ""
        for p in candidates { if let h = dlopen(p, RTLD_NOW | RTLD_LOCAL) { loaded = h; found = p; break } }
        let symbols = ["lsl_local_clock", "lsl_create_streaminfo", "lsl_destroy_streaminfo", "lsl_get_desc", "lsl_append_child", "lsl_append_child_value", "lsl_create_outlet", "lsl_destroy_outlet", "lsl_push_sample_dt", "lsl_push_sample_ft"]
        if let h = loaded, symbols.contains(where: { dlsym(h, $0) == nil }) { dlclose(h); loaded = nil }
        handle = loaded; path = found; error = loaded == nil ? "LSL library unavailable. Run scripts/build-app.sh to bundle the macOS library." : nil
    }
    func symbol<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(handle!, name), to: T.self) }
    func clock() -> Double { guard handle != nil else { return ProcessInfo.processInfo.systemUptime }; return symbol("lsl_local_clock", (@convention(c) () -> Double).self)() }
    func now(_ mode: TimestampMode) -> Double {
        switch mode { case .epoch: return Date().timeIntervalSince1970; case .native: return clock(); case .host: return clock(); case .none: return 0 }
    }
}
struct StreamFailure: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }
final class Outlet {
    let pointer: UnsafeMutableRawPointer
    let settings: StreamSettings
    let labels: [String]
    let name: String
    let rate: Double
    let lsl = LSL.shared
    init(device: String, id: String, model: String, sensor: Sensor, athena: Bool, aux: Bool, settings: StreamSettings, fourChannel: Bool = false) throws {
        guard LSL.shared.handle != nil else { throw StreamFailure(LSL.shared.error!) }
        var settings = settings
        if fourChannel { settings.double64 = false; settings.secondary = .none }
        self.settings = settings
        var labels = sensor.labels(athena: athena, aux: fourChannel ? false : aux)
        if settings.secondary != .none { labels += settings.double64 ? ["Secondary Timestamp"] : ["Secondary Timestamp (Base)", "Secondary Timestamp (Remainder)"] }
        self.labels = labels
        name = fourChannel ? "MUSE_4CH" : "\(device) (\(id)) \(sensor.rawValue)"
        rate = athena && sensor == .telemetry ? 1 : sensor.rate
        typealias CreateInfo = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, Double, Int32, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
        let create = lsl.symbol("lsl_create_streaminfo", CreateInfo.self)
        guard let info = create(name, sensor.rawValue, Int32(labels.count), rate, settings.double64 ? 2 : 1, fourChannel ? "muse_4ch_bridge_BlueMuse:\(id):EEG" : "BlueMuse:\(id):\(sensor.rawValue)") else { throw StreamFailure("Cannot create LSL stream info") }
        let destroy = lsl.symbol("lsl_destroy_streaminfo", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        defer { destroy(info) }
        let desc = lsl.symbol("lsl_get_desc", (@convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer).self)(info)
        let child = lsl.symbol("lsl_append_child", (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> UnsafeMutableRawPointer).self)
        let value = lsl.symbol("lsl_append_child_value", (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer).self)
        _ = value(desc, "manufacturer", model == "Smith Lowdown Focus" ? "Smith" : "Interaxon")
        _ = value(desc, "device", model); _ = value(desc, "type", sensor.rawValue)
        _ = value(desc, "timestamp_behavior", settings.timingBehavior.rawValue)
        _ = value(desc, "primary_timestamp_format", settings.primary.rawValue); _ = value(desc, "secondary_timestamp_format", settings.secondary.rawValue)
        if fourChannel {
            _ = value(desc, "original_stream_name", "\(device) (\(id)) EEG")
            _ = value(desc, "channel_order", "TP9,AF7,AF8,TP10")
        }
        let channels = child(desc, "channels")
        for (i,label) in labels.enumerated() {
            let c = child(channels, "channel"); let timestamp = i >= sensor.labels(athena: athena, aux: aux).count
            _ = value(c, "label", label); _ = value(c, "unit", timestamp ? "seconds" : sensor.unit(athena: athena)); _ = value(c, "type", timestamp ? "timestamp" : sensor.rawValue)
        }
        guard let outlet = lsl.symbol("lsl_create_outlet", (@convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> UnsafeMutableRawPointer?).self)(info, fourChannel ? 0 : Int32(sensor.chunkSize(athena:athena)), 360) else { throw StreamFailure("Cannot open LSL outlet") }
        pointer = outlet
    }
    func push(_ row: [Double], timestamp: Double, secondary: Double) throws {
        let values = settings.sample(row, secondary: secondary)
        guard values.count == labels.count else { throw StreamFailure("LSL channel count mismatch") }
        let result: Int32
        if settings.double64 {
            result = values.withUnsafeBufferPointer { lsl.symbol("lsl_push_sample_dt", (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<Double>, Double) -> Int32).self)(pointer, $0.baseAddress!, timestamp) }
        } else {
            result = values.map(Float.init).withUnsafeBufferPointer { lsl.symbol("lsl_push_sample_ft", (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<Float>, Double) -> Int32).self)(pointer, $0.baseAddress!, timestamp) }
        }
        if result != 0 { throw StreamFailure("LSL push failed (\(result))") }
    }
    deinit { lsl.symbol("lsl_destroy_outlet", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(pointer) }
}

/// Native equivalent of the Python MUSE_4CH republisher; no second BLE connection.
final class FourChannelStream {
    let outlet: Outlet
    private(set) var sampleCount = 0
    init(device: String, id: String, model: String, primary: TimestampMode, behavior: TimingBehavior = .windowsCompatible) throws {
        var settings = StreamSettings(); settings.primary = primary; settings.timingBehavior = behavior
        outlet = try Outlet(device:device,id:id,model:model,sensor:.eeg,athena:false,aux:false,settings:settings,fourChannel:true)
    }
    func push(_ row: [Double], timestamp: Double) throws {
        guard row.count >= 4 else { throw StreamFailure("MUSE_4CH requires four EEG electrode values") }
        try outlet.push(Array(row.prefix(4)),timestamp:timestamp,secondary:0)
        sampleCount += 1
    }
}
