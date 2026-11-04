import AppKit
import CoreBluetooth
import Combine
import BlueMuseCore

func museUUID(_ number: Int) -> CBUUID { CBUUID(string: String(format: "273e%04x-4c4d-454d-96be-f03bac821358", number)) }
let museService = CBUUID(string: "FE8D")

final class EventLog: ObservableObject {
    static let shared = EventLog()
    let directory: URL
    let file: URL
    @Published var lines: [String] = []
    init() {
        directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/BlueMuse")
        file = directory.appendingPathComponent("BlueMuse-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-" )).log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
    }
    func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)"
        lines.append(line); if lines.count > 300 { lines.removeFirst() }
        if let f = try? FileHandle(forWritingTo: file) { defer { try? f.close() }; _ = try? f.seekToEnd(); try? f.write(contentsOf: Data((line + "\n").utf8)) }
    }
}
final class SignalDisplay: ObservableObject {
    @Published var points: [Sensor: [SignalPoint]] = [:]
    func clear() { points.removeAll() }
}
struct StreamStats: Identifiable {
    var id: Sensor
    var name: String
    var labels: [String]
    var nominal: Double
    var rate: Double = 0
    var timestamp: Double = 0
    var latest: [Double] = []
    var received = 0
    var recent: [(Double, Int)] = []
}
struct ChannelBlock {
    var channels: [Int: [Double]] = [:]
    let arrival: Double
    let primary: Double
    let secondary: Double
}
final class MuseDevice: NSObject, ObservableObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    var id: UUID { peripheral.identifier }
    @Published var name: String
    @Published var status = "Discovered"
    @Published var model = "Detecting…"
    @Published var rssi = 0
    @Published var battery: Double?
    @Published var deviceInfo = ""
    @Published var controlStatus = ""
    @Published var streaming = false
    @Published var connectionActive = false
    @Published var fourChannelEnabled = false
    @Published var fourChannelStreaming = false
    @Published var fourChannelSamples = 0
    var fourChannelStream: FourChannelStream?
    func closeFourChannel() { fourChannelStream = nil; fourChannelStreaming = false }
    func stopFourChannel() { fourChannelEnabled = false; closeFourChannel(); log("MUSE_4CH stopped") }
    @Published var stats: [Sensor: StreamStats] = [:]
    @Published var error: String?
    weak var manager: MuseManager?
    var wanted = false
    var lastSeen = ProcessInfo.processInfo.systemUptime
    var characteristics: [CBUUID: CBCharacteristic] = [:]
    var athena = false
    var aux = true
    var supportsPPG = false
    var ready = false
    var settings = StreamSettings()
    let signalDisplay = SignalDisplay()
    var histories: [Sensor: SignalHistory] = [:]
    var lastStatsUpdate = 0.0
    var outlets: [Sensor: Outlet] = [:]
    var fits: [String: SampleTimestampClock] = [:]
    var eegBuffer: [Int: ChannelBlock] = [:]
    var ppgBuffer: [Int: ChannelBlock] = [:]
    var started = 0.0
    var lastPacket = 0.0
    var lastInfo = 0.0
    var activity: NSObjectProtocol?
    func endActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil } }
    var controlBuffer = ControlMessageBuffer()
    var lastControlKind = "info"
    var deviceMetadata = "Muse EEG Headset"
    var task: Task<Void, Never>?
    var writeWaiter: CheckedContinuation<Void, Error>?
    var writeTimeout: DispatchWorkItem?
    var pendingNotify = Set<CBUUID>()
    var notifyWaiter: CheckedContinuation<Void, Error>?
    var notifyTimeout: DispatchWorkItem?
    init(_ peripheral: CBPeripheral, name: String) { self.peripheral = peripheral; self.name = name; super.init(); peripheral.delegate = self }
    func log(_ s: String) { EventLog.shared.write("\(name): \(s)") }
    func fail(_ e: Error) {
        error = e.localizedDescription; status = "Error"; log(e.localizedDescription)
        task?.cancel(); task = nil; endActivity(); closeFourChannel(); outlets.removeAll(); streaming = false; ready = false
        if peripheral.state != .disconnected { manager?.central.cancelPeripheralConnection(peripheral) }
    }
    func connected() {
        connectionActive = true
        ready = false; error = nil; status = "Discovering services…"; characteristics.removeAll(); peripheral.discoverServices([museService])
    }
    func disconnected() {
        connectionActive = false
        closeFourChannel()
        endActivity()
        task?.cancel(); task = nil
        completeWrite(.failure(StreamFailure("Bluetooth disconnected")))
        completeNotify(.failure(StreamFailure("Bluetooth disconnected")))
        ready = false; streaming = false; outlets.removeAll(); fits.removeAll(); eegBuffer.removeAll(); ppgBuffer.removeAll(); characteristics.removeAll()
        status = wanted ? "Reconnecting…" : "Disconnected"
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == museService }) else { fail(StreamFailure("Muse service FE8D missing")); return }
        peripheral.discoverCharacteristics(nil, for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail(error); return }
        for c in service.characteristics ?? [] { characteristics[c.uuid] = c }
        guard characteristics[museUUID(1)] != nil else { fail(StreamFailure("Muse command characteristic missing")); return }
        let profile = MuseProfile.detect(name:name,characteristics:Set((1...0x14).filter { characteristics[museUUID($0)] != nil }),museSSpecial:characteristics[CBUUID(string:"00002902-0000-1000-8000-00805f9b34fb")] != nil)
        athena = profile.athena; supportsPPG = profile.ppg; model = profile.model
        deviceMetadata = profile.deviceMetadata; aux = profile.aux
        ready = true; status = "Connected"; log("Detected \(model)")
        if wanted { begin() } else { queryInfo() }
    }
    func completeWrite(_ result: Result<Void, Error>) {
        writeTimeout?.cancel(); writeTimeout = nil
        let waiter = writeWaiter; writeWaiter = nil; waiter?.resume(with: result)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == museUUID(1) else { return }; completeWrite(error.map { .failure($0) } ?? .success(()))
    }
    func write(_ text: String) async throws {
        try Task.checkCancellation()
        if text == "v1" || text == "v6" { lastControlKind = "info" } else if text == "s" { lastControlKind = "status" }
        guard peripheral.state == .connected, let c = characteristics[museUUID(1)] else { throw StreamFailure("Muse is disconnected") }
        guard writeWaiter == nil else { throw StreamFailure("A command is already in progress") }
        if c.properties.contains(.write) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeWaiter = continuation
                let timeout = DispatchWorkItem { [weak self] in self?.completeWrite(.failure(StreamFailure("Muse command timed out"))) }
                writeTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now()+5, execute: timeout)
                peripheral.writeValue(MuseWire.command(text), for: c, type: .withResponse)
            }
        } else if c.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(MuseWire.command(text), for: c, type: .withoutResponse)
        } else { throw StreamFailure("Muse command characteristic is not writable") }
    }
    func completeNotify(_ result: Result<Void, Error>) {
        notifyTimeout?.cancel(); notifyTimeout = nil; pendingNotify.removeAll()
        let waiter = notifyWaiter; notifyWaiter = nil; waiter?.resume(with: result)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard pendingNotify.contains(characteristic.uuid) else { return }
        if let error { completeNotify(.failure(error)); return }
        guard characteristic.isNotifying else { completeNotify(.failure(StreamFailure("Muse refused notifications"))); return }
        pendingNotify.remove(characteristic.uuid); if pendingNotify.isEmpty { completeNotify(.success(())) }
    }
    func subscribe(_ numbers: [Int]) async throws {
        let cs = try numbers.map { n -> CBCharacteristic in
            guard let c = characteristics[museUUID(n)], c.properties.contains(.notify) || c.properties.contains(.indicate) else { throw StreamFailure(String(format: "Required characteristic %04x unavailable", n)) }; return c
        }.filter { !$0.isNotifying }
        guard !cs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingNotify = Set(cs.map(\.uuid)); notifyWaiter = continuation
            let timeout = DispatchWorkItem { [weak self] in self?.completeNotify(.failure(StreamFailure("Notification subscription timed out"))) }
            notifyTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now()+8, execute: timeout)
            cs.forEach { peripheral.setNotifyValue(true, for: $0) }
        }
    }
    func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds*1e9)); try Task.checkCancellation() }
    func queryInfo() {
        guard ready, !streaming, task == nil else { return }
        controlBuffer = ControlMessageBuffer()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil; if self.wanted && !self.streaming && self.ready { self.begin() } }
            do { try await self.subscribe([1]); try await self.write(self.athena ? "v6" : "v1"); try await self.pause(0.8); try await self.write("s"); try await self.pause(0.8) }
            catch { if !Task.isCancelled { self.fail(error) } }
        }
    }
    func begin() {
        guard wanted, ready, task == nil, !streaming else { return }
        controlBuffer = ControlMessageBuffer()
        settings = manager?.settings ?? StreamSettings(); if fourChannelEnabled { settings.enabled.insert(.eeg) }; fourChannelSamples = 0; closeFourChannel(); error = nil; status = "Starting…"
        eegBuffer.removeAll(); ppgBuffer.removeAll(); fits.removeAll(); stats.removeAll(); liveStats.removeAll(); histories.removeAll(); signalDisplay.clear(); lastPacket = 0; started = ProcessInfo.processInfo.systemUptime
        task = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.task = nil }
            do {
                var numbers = [1]
                if self.athena { numbers += [0x13] }
                else {
                    if self.settings.enabled.contains(.eeg) { numbers += Array(3...(self.aux ? 7 : 6)) }
                    if self.settings.enabled.contains(.accelerometer) { numbers.append(0xa) }
                    if self.settings.enabled.contains(.gyroscope) { numbers.append(9) }
                    if self.settings.enabled.contains(.ppg) && self.supportsPPG { numbers += [0xf,0x10,0x11] }
                    numbers.append(0xb)
                }
                for sensor in Sensor.allCases where self.settings.enabled.contains(sensor) && (sensor != .ppg || self.supportsPPG) {
                    try self.open(sensor)
                }
                try await self.subscribe(numbers)
                if self.athena, self.characteristics[museUUID(0x14)] != nil {
                    do { try await self.subscribe([0x14]) }
                    catch { self.log("Optional Athena DATA_2 notification unavailable; continuing with DATA_1: \(error.localizedDescription)") }
                }
                if self.athena {
                    for cmd in ["v6","s","h","p1041","s"] { try await self.write(cmd); try await self.pause(0.2) }
                    try await self.write("dc001"); try await self.pause(0.05); try await self.write("dc001"); try await self.pause(0.1); try await self.write("L1"); try await self.pause(0.3); try await self.write("s"); try await self.pause(0.2)
                } else {
                    try await self.write("v1"); try await self.pause(0.8); try await self.write("s"); try await self.pause(0.3)
                    try await self.write("h"); try await self.pause(0.2)
                    try await self.write(self.model == "Smith Lowdown Focus" ? "p21" : self.supportsPPG ? "p50" : "p20"); try await self.pause(0.2)
                    try await self.write("d")
                }
                try Task.checkCancellation(); self.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Streaming Muse sensor data over LSL"); self.streaming = true; self.status = "Streaming"; self.log("Streaming started"); self.lastInfo = ProcessInfo.processInfo.systemUptime
            } catch { if !Task.isCancelled { self.fail(error) } }
        }
    }
    func stop(disconnect: Bool = false) {
        stopFourChannel()
        endActivity()
        wanted = false
        if peripheral.state == .disconnected { status = "Disconnected"; return }
        // Disconnect cancels in-flight GATT operations safely, including a start handshake.
        task?.cancel(); task = nil; endActivity(); outlets.removeAll(); streaming = false; status = "Stopping…"
        if writeWaiter != nil || notifyWaiter != nil || !ready { manager?.central.cancelPeripheralConnection(peripheral); return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.task = nil }
            do { try await self.write("h"); self.log("Streaming stopped") } catch { self.log(error.localizedDescription) }
            if disconnect { self.manager?.central.cancelPeripheralConnection(self.peripheral) }
            else {
                for c in self.characteristics.values where c.uuid != museUUID(1) && c.isNotifying { self.peripheral.setNotifyValue(false,for:c) }
                self.eegBuffer.removeAll(); self.ppgBuffer.removeAll(); self.status = "Connected"; self.log("Streaming stopped; Bluetooth remains connected")
            }
        }
    }
    func open(_ sensor: Sensor) throws {
        guard outlets[sensor] == nil else { return }
        let outlet = try Outlet(device: name, id: id.uuidString, model: deviceMetadata, sensor: sensor, athena: athena, aux: aux, settings: settings)
        outlets[sensor] = outlet
        stats[sensor] = StreamStats(id: sensor, name: outlet.name, labels: outlet.labels, nominal: outlet.rate)
    }
    func emit(_ sensor: Sensor, rows: [[Double]], primary: Double, secondary: Double) throws {
        if sensor == .telemetry { battery = rows.last?.first }
        guard wanted, settings.enabled.contains(sensor), !rows.isEmpty else { return }
        try open(sensor); guard let outlet = outlets[sensor] else { return }
        let count = rows.count
        func timestamps(_ key: String, _ arrival: Double, _ domain: TimestampMode) -> [Double] {
            if fits[key] == nil { fits[key] = SampleTimestampClock(sensor:sensor,athena:athena,behavior:settings.timingBehavior,domain:domain) }
            return fits[key]!.timestamps(count:count,arrival:arrival)
        }
        let ts = timestamps(sensor.rawValue,primary,settings.primary)
        let ts2 = settings.secondary == .none ? Array(repeating:0.0,count:count) : timestamps(sensor.rawValue+"2",secondary,settings.secondary)
        for i in rows.indices { try outlet.push(rows[i], timestamp: ts[i], secondary: ts2[i]) }
        if sensor == .eeg && fourChannelEnabled {
            if fourChannelStream == nil {
                fourChannelStream = try FourChannelStream(device:name,id:id.uuidString,model:deviceMetadata,primary:settings.primary,behavior:settings.timingBehavior)
                log("MUSE_4CH publishing TP9, AF7, AF8, TP10 as float32")
            }
            for i in rows.indices { try fourChannelStream!.push(rows[i],timestamp:ts[i]) }
            if !fourChannelStreaming { fourChannelStreaming = true }
        }
        if histories[sensor] == nil { histories[sensor] = SignalHistory(capacity: max(120, Int(outlet.rate*12))) }
        for i in rows.indices { histories[sensor]!.append(time: ProcessInfo.processInfo.systemUptime-Double(count-1-i)/outlet.rate, values: rows[i]) }
        let now = ProcessInfo.processInfo.systemUptime
        var stat = liveStats[sensor] ?? stats[sensor]!
        stat.latest = settings.sample(rows.last!, secondary: ts2.last!); stat.timestamp = ts.last!; stat.received += count
        stat.recent.append((now,count)); stat.recent.removeAll { now-$0.0 > 5 }
        let elapsed = min(5, now-started)
        stat.rate = elapsed > 0.5 ? Double(stat.recent.reduce(0) { $0+$1.1 })/elapsed : 0
        // Publish at the UI timer rate; packet processing remains on the Bluetooth serial queue.
        liveStats[sensor] = stat
    }
    var liveStats: [Sensor: StreamStats] = [:]
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail(error); return }
        guard let value = characteristic.value else { return }
        let b = Array(value)
        if characteristic.uuid == museUUID(1) { receiveControl(b); return }
        guard wanted, ready, streaming || task != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime; lastPacket = now
        let primary = LSL.shared.now(settings.primary), secondary = LSL.shared.now(settings.secondary)
        do {
            if athena {
                for packet in AthenaPacket.parse(b) { for (sensor, rows) in try packet.decode() { try emit(sensor, rows: rows, primary: primary, secondary: secondary) } }; return
            }
            guard b.count >= 2 else { throw WireError.truncated }
            let index = Int(b[0])*256+Int(b[1])
            if let c = (3...7).first(where: { characteristic.uuid == museUUID($0) }) {
                var block = eegBuffer[index] ?? ChannelBlock(arrival: now, primary: primary, secondary: secondary)
                block.channels[c-3] = try MuseWire.legacyChannel(b); eegBuffer[index] = block
                try flush(now)
            } else if let c = (0xf...0x11).first(where: { characteristic.uuid == museUUID($0) }) {
                var block = ppgBuffer[index] ?? ChannelBlock(arrival: now, primary: primary, secondary: secondary)
                block.channels[c-0xf] = try MuseWire.legacyChannel(b, ppg: true); ppgBuffer[index] = block; try flush(now)
            } else if characteristic.uuid == museUUID(9) || characteristic.uuid == museUUID(0xa) {
                let gyro = characteristic.uuid == museUUID(9)
                try emit(gyro ? .gyroscope : .accelerometer, rows: MuseWire.legacyMotion(b, gyro: gyro), primary: primary, secondary: secondary)
            } else if characteristic.uuid == museUUID(0xb) { try emit(.telemetry, rows: MuseWire.telemetry(b), primary: primary, secondary: secondary) }
        } catch { if error is WireError { log("Dropped truncated sensor packet") } else { fail(error) } }
    }
    func flush(_ now: Double) throws {
        do {
            for (key,block) in eegBuffer.sorted(by: { $0.value.arrival < $1.value.arrival }) {
                let channels = aux ? 5 : 4
                guard block.channels.count >= channels || now-block.arrival > 0.5 else { break }
                let rows = (0..<12).map { s in (0..<channels).map { block.channels[$0]?[s] ?? .nan } }
                try emit(.eeg, rows: rows, primary: block.primary, secondary: block.secondary); eegBuffer.removeValue(forKey: key)
            }
        }
        for (key,block) in ppgBuffer.sorted(by: { $0.value.arrival < $1.value.arrival }) {
            guard block.channels.count == 3 || now-block.arrival > 0.5 else { break }
            let rows = (0..<6).map { s in (0..<3).map { block.channels[$0]?[s] ?? .nan } }
            try emit(.ppg, rows: rows, primary: block.primary, secondary: block.secondary); ppgBuffer.removeValue(forKey: key)
        }
    }
    func receiveControl(_ b: [UInt8]) {
        guard let n = b.first, b.count >= Int(n)+1 else { return }
        for data in controlBuffer.append(Array(b.dropFirst().prefix(Int(n)))) {
            guard let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { continue }
            let formatted = (try? JSONSerialization.data(withJSONObject:json, options:[.prettyPrinted,.sortedKeys])) ?? data
            let text = String(data:formatted,encoding:.utf8) ?? ""
            if json["fw"] != nil || json["hw"] != nil || json["sn"] != nil || lastControlKind == "info" { deviceInfo = text }
            else { controlStatus = text }
        }
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now-lastStatsUpdate >= 0.5 {
        lastStatsUpdate = now
        if let fourChannelStream { fourChannelSamples = fourChannelStream.sampleCount }
        for (sensor,var stat) in liveStats {
            stat.recent.removeAll { now-$0.0 > 5 }; stat.rate = streaming ? Double(stat.recent.reduce(0) { $0+$1.1 }) / max(0.5,min(5,now-started)) : 0; liveStats[sensor] = stat; stats[sensor] = stat
        }
        }
        if streaming {
            for (sensor, history) in histories { signalDisplay.points[sensor] = history.points(seconds: sensor == .telemetry ? 120 : 10) }
            do { try flush(now) } catch { fail(error) }
            if now - max(lastPacket, started) > 15 { lastPacket = now; fail(StreamFailure("No sensor data for 15 seconds; reconnecting")) }
        }
        if ready && wanted && !streaming && task == nil { begin() }
        if ready && !streaming && !wanted && now-lastInfo > 4 && task == nil { lastInfo = now; queryInfo() }
    }
}

final class MuseManager: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var devices: [MuseDevice] = []
    @Published var bluetoothState = "Starting Bluetooth…"
    @Published var settings: StreamSettings { didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") } } }
    @Published var autoStart = false
    @Published var commandError: String?
    var central: CBCentralManager!
    var timer: Timer?
    var requested = Set<String>()
    var firstRequested = false
    var excluded = Set<UUID>()
    override init() {
        settings = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(StreamSettings.self, from: $0) } ?? StreamSettings()
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.devices.forEach { $0.tick() } }
        EventLog.shared.write("BlueMuse macOS started; LSL: \(LSL.shared.path)")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        EventLog.shared.write("Bluetooth state: \(central.state.rawValue), authorization: \(CBManager.authorization.rawValue)")
        switch central.state { case .poweredOn: bluetoothState = "Bluetooth on · scanning"; refresh(); case .poweredOff: bluetoothState = "Bluetooth is off. Turn it on in System Settings."; case .unauthorized: bluetoothState = "Bluetooth access denied. Allow BlueMuse in System Settings → Privacy & Security → Bluetooth."; case .unsupported: bluetoothState = "Bluetooth LE is unavailable"; case .resetting: bluetoothState = "Bluetooth is resetting…"; default: bluetoothState = "Waiting for Bluetooth…" }
        if central.state != .poweredOn { devices.forEach { $0.disconnected() } }
    }
    func refresh() {
        guard central.state == .poweredOn else { return }; central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        for p in central.retrieveConnectedPeripherals(withServices: [museService]) { discover(p, name: p.name ?? "Muse", rssi: 0) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard ["MUSE","SMXT","SMTX"].contains(where: { name.uppercased().contains($0) }) || services.contains(museService) else { return }
        discover(peripheral, name: name.isEmpty ? "Muse" : name, rssi: RSSI.intValue)
    }
    func discover(_ p: CBPeripheral, name: String, rssi: Int) {
        let device: MuseDevice
        if let existing = devices.first(where: { $0.id == p.identifier }) { device = existing } else { device = MuseDevice(p, name: name); device.manager = self; devices.append(device); EventLog.shared.write("Discovered \(name) (\(p.identifier))") }
        device.rssi = rssi; device.lastSeen = ProcessInfo.processInfo.systemUptime
        if device.wanted || (autoStart && !excluded.contains(p.identifier)) || requested.contains(name.lowercased()) || requested.contains(p.identifier.uuidString.lowercased()) || firstRequested {
            if firstRequested { firstRequested = false }; start(device)
        } else if settings.alwaysPair && !excluded.contains(device.id) && p.state == .disconnected { connect(device) }
    }
    func connect(_ d: MuseDevice) { excluded.remove(d.id); guard central.state == .poweredOn, d.peripheral.state == .disconnected else { return }; d.connectionActive = true; d.status = "Connecting…"; central.connect(d.peripheral); let id = d.id
        DispatchQueue.main.asyncAfter(deadline: .now()+20) { [weak self] in
            guard let self, let d = self.devices.first(where: { $0.id == id }), d.peripheral.state == .connecting else { return }; d.error = "Connection timed out; ensure your Muse is awake and nearby"; self.central.cancelPeripheralConnection(d.peripheral)
        }
    }
    func start(_ d: MuseDevice) {
        guard LSL.shared.handle != nil else { commandError = LSL.shared.error; return }
        excluded.remove(d.id); d.wanted = true
        if d.ready { d.begin() } else { connect(d) }
    }
    func startFourChannel(_ d: MuseDevice) {
        if (d.streaming || d.wanted) && !d.settings.enabled.contains(.eeg) { d.stop(disconnect:true) }
        d.fourChannelSamples = 0
        d.fourChannelEnabled = true
        start(d)
    }
    func stop(_ d: MuseDevice) { excluded.insert(d.id); requested.remove(d.name.lowercased()); requested.remove(d.id.uuidString.lowercased()); d.stop() }
    func disconnect(_ d: MuseDevice) { excluded.insert(d.id); requested.remove(d.name.lowercased()); requested.remove(d.id.uuidString.lowercased()); d.stop(disconnect:true); d.log("Disconnect requested; automatic connection suppressed until an explicit connect or start") }
    func startAll() { excluded.removeAll(); autoStart = true; devices.forEach(start) }
    func stopAll() { autoStart = false; requested.removeAll(); firstRequested = false; devices.forEach { $0.stop() } }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { devices.first { $0.id == peripheral.identifier }?.connected() }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { lost(peripheral, error: error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { lost(peripheral, error: error) }
    func lost(_ p: CBPeripheral, error: Error?) {
        guard let d = devices.first(where: { $0.id == p.identifier }) else { return }
        d.disconnected(); if let error { d.error = error.localizedDescription; d.log(error.localizedDescription) }
        if d.wanted { DispatchQueue.main.asyncAfter(deadline: .now()+2) { [weak self, weak d] in if let d, d.wanted { self?.connect(d) } } }
    }
    func reset(_ d: MuseDevice) {
        guard d.ready, d.task == nil else { return }
        excluded.insert(d.id); requested.remove(d.name.lowercased()); requested.remove(d.id.uuidString.lowercased())
        d.stopFourChannel(); d.wanted = false; d.task = Task { @MainActor in
            defer { d.task = nil }
            do { try await d.write("*1"); central.cancelPeripheralConnection(d.peripheral) } catch { d.fail(error) }
        }
    }
    func command(_ url: URL) {
        guard let cmd = ProtocolCommand(url) else { return }; let a = cmd.arguments
        EventLog.shared.write("URL command: \(cmd.action)")
        switch cmd.action {
        case "", "refresh": refresh()
        case "shutdown": stopAll(); DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { NSApp.terminate(nil) }
        case "start":
            if a["startall"] != nil { startAll() }
            else if a["streamfirst"]?.lowercased() == "true" { if let d = devices.first(where: { $0.peripheral.state == .connected || ProcessInfo.processInfo.systemUptime-$0.lastSeen < 10 }) { start(d) } else { firstRequested = true } }
            else if let names = a["addresses"] { requested.formUnion(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }); for d in devices where requested.contains(d.name.lowercased()) || requested.contains(d.id.uuidString.lowercased()) { start(d) } }
        case "stop":
            if a["stopall"] != nil { stopAll() }
            else if let names = a["addresses"] { let set = Set(names.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }); requested.subtract(set); for d in devices where set.contains(d.name.lowercased()) || set.contains(d.id.uuidString.lowercased()) { stop(d) } }
        case "setting": if let key = a["key"], let value = a["value"] { if !settings.set(key: key, value: value) { commandError = "Invalid setting: \(key)=\(value)" } } else { commandError = "Setting command requires key and value" }
        default: commandError = "Unknown command: \(cmd.action)"
        }
    }
}
