import SwiftUI
import AppKit
import BlueMuseCore

@main
struct BlueMuseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var manager = MuseManager()
    var body: some Scene {
        Window("BlueMuse", id: "main") {
            MainView(manager: manager)
                .frame(minWidth: 850, minHeight: 550)
                .background(WindowPersistence())
                .onAppear { delegate.setManager(manager); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }.defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Refresh Headsets") { manager.refresh() }.keyboardShortcut("r")
                Button("Start All") { manager.startAll() }.keyboardShortcut("s", modifiers: [.command,.shift])
                Button("Stop All") { manager.stopAll() }.keyboardShortcut(".")
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: MuseManager?
    private var pendingURLs: [URL] = []
    func setManager(_ manager: MuseManager) {
        self.manager = manager
        let urls = pendingURLs; pendingURLs.removeAll()
        urls.forEach { manager.command($0) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let manager { urls.forEach { manager.command($0) } } else { pendingURLs += urls }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
            let count = NSApp.windows.filter { $0.identifier?.rawValue == "BlueMuseMain" }.count
            EventLog.shared.write("Main window count after URL: \(count)")
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { manager?.stopAll(); return .terminateNow }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }; return true
    }
}
struct MainView: View {
    @ObservedObject var manager: MuseManager
    @State private var selected: UUID?
    @State private var settingsShown = false
    @State private var logsShown = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.path").font(.system(size: 30, weight: .semibold)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BlueMuse").font(.title2.bold())
                    Text("MUSE → LAB STREAMING LAYER").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(manager.bluetoothState).font(.callout).foregroundStyle(.secondary)
                Button { manager.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { settingsShown.toggle() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            }.padding(22)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("HEADSETS").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer(); Text("\(manager.devices.count)").font(.caption.monospacedDigit())
                    }.padding(16)
                    if manager.devices.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.cyan)
                            Text("Searching for your Muse").font(.headline)
                            Text("Turn on your headband and keep it near your Mac. Close other apps connected to it.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selected) {
                            ForEach(manager.devices, id: \.id) { device in
                                DeviceRow(device: device).tag(device.id)
                            }
                        }.listStyle(.sidebar)
                    }
                    Divider()
                    HStack { Button("Start All") { manager.startAll() }.buttonStyle(.borderedProminent); Button("Stop All") { manager.stopAll() } }.padding(16)
                    if manager.autoStart { Text("Automatically starting discovered headsets").font(.caption).foregroundStyle(.secondary).padding([.horizontal,.bottom], 16) }
                }.frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
                Group {
                    if let device = manager.devices.first(where: { $0.id == selected }) { DeviceDetail(device: device, manager: manager) }
                    else {
                        VStack(spacing: 18) {
                            Image(systemName: "waveform.path.ecg").font(.system(size: 65, weight: .ultraLight)).foregroundStyle(.cyan)
                            Text("Your signals, on your Mac.").font(.title2.bold())
                            Text("Select a headset to connect, stream, and inspect its sensor data.").foregroundStyle(.secondary)
                            HStack(spacing: 20) { ForEach(Sensor.allCases, id: \.self) { Text($0.rawValue).font(.caption).foregroundStyle(.secondary) } }
                        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 480)
                if settingsShown { SettingsPanel(manager: manager).frame(width: 290) }
            }
            Divider()
            HStack {
                Circle().fill(LSL.shared.handle == nil ? Color.orange : Color.green).frame(width: 7,height: 7)
                Text(LSL.shared.handle == nil ? "LSL library missing" : "LSL ready").font(.caption)
                Spacer()
                Text("Settings apply to newly opened streams").font(.caption).foregroundStyle(.secondary)
                Button("Logs") { logsShown = true }.buttonStyle(.plain).font(.caption)
            }.padding(.horizontal,20).padding(.vertical,10)
        }
        .onExitCommand { selected = nil }
        .onReceive(manager.$devices) { devices in if selected == nil, let first = devices.first { selected = first.id } }
        .alert("BlueMuse", isPresented: Binding(get: { manager.commandError != nil }, set: { if !$0 { manager.commandError = nil } })) { Button("OK") { manager.commandError = nil } } message: { Text(manager.commandError ?? "") }
        .sheet(isPresented: $logsShown) { LogView() }
    }
}
struct DeviceRow: View {
    @ObservedObject var device: MuseDevice
    var body: some View {
        HStack {
            Image(systemName: device.streaming ? "waveform" : "headphones").foregroundStyle(device.streaming ? Color.green : Color.cyan)
            VStack(alignment: .leading,spacing: 5) { Text(device.name).font(.headline); Text(device.status).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let battery = device.battery { Text("\(Int(battery))%").font(.caption.monospacedDigit()) }
        }.padding(.vertical,9)
    }
}
struct DeviceDetail: View {
    @ObservedObject var device: MuseDevice
    @ObservedObject var manager: MuseManager
    @State private var lslInfoShown = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading,spacing: 6) {
                        Text(device.name).font(.largeTitle.bold())
                        Text("\(device.model) · \(device.status)").foregroundStyle(.secondary)
                        Text(device.id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(device.wanted ? "Stop Stream" : "Start Stream") { if device.wanted { manager.stop(device) } else { manager.start(device) } }.buttonStyle(.borderedProminent)
                }
                HStack(spacing: 24) {
                    Label("\(device.rssi) dBm",systemImage:"antenna.radiowaves.left.and.right")
                    if let battery = device.battery { Label(String(format:"%.1f%%",battery),systemImage:"battery.75percent") }
                    Spacer()
                    Button("Disconnect") { manager.disconnect(device) }.disabled(!device.connectionActive)
                        .help("Stop streaming and release the Bluetooth connection")
                    Menu("Device") {
                        Button("Connect / Inspect") { manager.connect(device) }
                        Button("Refresh Device Information") { device.queryInfo() }.disabled(!device.ready || device.streaming || device.task != nil)
                        Button("Copy All Stream Info") {
                            copy(Sensor.allCases.compactMap { sensor in
                                guard let s = device.stats[sensor] else { return nil }
                                return "\(s.name)\nChannels: \(s.labels.joined(separator: ", "))\nValues: \(s.latest.map { String($0) }.joined(separator: ", "))\nTimestamp: \(s.timestamp)\nRate: \(s.rate) Hz"
                            }.joined(separator:"\n\n"))
                        }.disabled(device.stats.isEmpty)
                        Button("Copy Device ID") { copy(device.id.uuidString) }
                        Button("Reset Headset") { manager.reset(device) }.disabled(!device.ready || device.task != nil)
                    }
                }.font(.callout)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Four-channel LSL", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                        Button { lslInfoShown = true } label: { Image(systemName:"info.circle") }
                            .buttonStyle(.plain).help("About this LSL stream and building a receiver")
                            .accessibilityLabel("Four-channel LSL information")
                        Spacer()
                        Button(device.fourChannelEnabled ? "Stop MUSE_4CH" : "Start MUSE_4CH") {
                            if device.fourChannelEnabled { device.stopFourChannel() } else { manager.startFourChannel(device) }
                        }.buttonStyle(.borderedProminent)
                    }
                    Text("MUSE_4CH · TP9, AF7, AF8, TP10 · 256 Hz · float32").font(.caption.monospaced()).textSelection(.enabled)
                    if device.fourChannelEnabled {
                        HStack {
                            Circle().fill(device.fourChannelStreaming ? Color.green : .orange).frame(width:7,height:7)
                            Text(device.fourChannelStreaming ? "Publishing · \(device.fourChannelSamples) samples sent" : "Waiting for EEG…")
                        }.font(.caption)
                    }
                    Text("Press Start to connect and publish. Your classifier or LSL receiver can subscribe to MUSE_4CH; no Python script needed.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
                Text("Timestamp timing: \(device.streaming ? device.settings.timingBehavior.title : manager.settings.timingBehavior.title)").font(.caption).foregroundStyle(.secondary)
                if let error = device.error { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if device.stats.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName:"chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Ready when you are").font(.headline)
                        Text("Start the stream to publish enabled sensors to LSL. Use LabRecorder or your LSL client to receive the data.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(35).frame(maxWidth:.infinity).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
                }
                ForEach(Sensor.allCases,id:\.self) { sensor in
                    if let stat = device.stats[sensor] { StreamCard(stat: stat, active: device.streaming, display: device.signalDisplay, unit: sensor.unit(athena: device.athena)) }
                }
                if !device.deviceInfo.isEmpty || !device.controlStatus.isEmpty {
                    DisclosureGroup("Device information & control status") {
                        VStack(alignment:.leading,spacing:10) { Text(device.deviceInfo); Text(device.controlStatus) }.font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(.top,10)
                    }
                }
            }.padding(24)
        }
        .sheet(isPresented:$lslInfoShown) { LSLHelpView(deviceID:device.id.uuidString,primary:device.streaming ? device.settings.primary : manager.settings.primary,behavior:device.streaming ? device.settings.timingBehavior : manager.settings.timingBehavior) }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
}
struct StreamCard: View {
    let stat: StreamStats
    let active: Bool
    @ObservedObject var display: SignalDisplay
    let unit: String
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(stat.id.rawValue).font(.headline)
                Text("\(stat.labels.count) ch").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(stat.id == .telemetry ? String(format:"%.2f Hz · every %.0f s",stat.nominal,1/stat.nominal) : String(format:"%.2f / %.0f Hz",active ? stat.rate : 0,stat.nominal)).font(.system(.callout,design:.monospaced)).foregroundStyle(active ? .green : .secondary)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary,forType:.string) } label: { Image(systemName:"doc.on.doc") }.buttonStyle(.plain).help("Copy stream details")
            }
            Text(stat.name).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:100),alignment:.leading)],alignment:.leading,spacing:10) {
                ForEach(stat.labels.indices,id:\.self) { i in
                    VStack(alignment:.leading,spacing:4) {
                        Text(stat.labels[i]).font(.caption2).foregroundStyle(.secondary)
                        Text(i < stat.latest.count ? String(format:"%.3f",stat.latest[i]) : "—").font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                    }
                }
            }
            SignalGraph(sensor: stat.id, labels: stat.labels.filter { !$0.hasPrefix("Secondary Timestamp") }, unit: unit, display: display, active: active)
            Divider()
            HStack { Text("Latest timestamp"); Spacer(); Text(stat.timestamp == 0 ? "—" : String(format:"%.6f",stat.timestamp)).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
    }
    var summary: String { "\(stat.name)\n\(stat.labels.joined(separator:", "))\n\(stat.latest.map { String($0) }.joined(separator:", "))\nTimestamp: \(stat.timestamp)\nSample rate: \(stat.rate)" }
}
struct SettingsPanel: View {
    @ObservedObject var manager: MuseManager
    var body: some View {
        Form {
            Section("Sensor streams") {
                ForEach(Sensor.allCases,id:\.self) { sensor in
                    Toggle(sensor.rawValue,isOn:Binding(get:{ manager.settings.enabled.contains(sensor) },set:{ if $0 { manager.settings.enabled.insert(sensor) } else { manager.settings.enabled.remove(sensor) } }))
                }
            }
            Section("Timestamp timing") {
                Picker("Timing mode",selection:$manager.settings.timingBehavior) {
                    Text("Windows").tag(TimingBehavior.windowsCompatible)
                    Text("Smoothed").tag(TimingBehavior.smoothed)
                }.pickerStyle(.segmented).labelsHidden()
                Text(manager.settings.timingBehavior.title).font(.caption.bold())
                Text(manager.settings.timingBehavior.note).font(.caption).foregroundStyle(.secondary)
                Text("Applies after stopping and restarting streams. MUSE_4CH inherits the selected timing.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Timestamp clock") {
                Picker("Primary",selection:$manager.settings.primary) { ForEach(TimestampMode.allCases.filter { $0 != .none },id:\.self) { Text($0.title).tag($0) } }
                Picker("Secondary",selection:$manager.settings.secondary) { ForEach(TimestampMode.allCases,id:\.self) { Text($0.title).tag($0) } }
                Text("Choose an LSL clock for synchronization with other LSL streams. Unix epoch preserves calendar time.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sample format") { Picker("Precision",selection:$manager.settings.double64) { Text("64-bit float").tag(true); Text("32-bit float").tag(false) } }
            Section("Connection") {
                Toggle("Always connect",isOn:$manager.settings.alwaysPair)
                Text("Replaces Always Pair on macOS. macOS manages pairing; BlueMuse keeps discovered headsets connected for inspection.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Open Log Folder") { NSWorkspace.shared.open(EventLog.shared.directory) }
        }.formStyle(.grouped)
    }
}
struct LogView: View {
    @ObservedObject var log = EventLog.shared
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading) {
            HStack { Text("BlueMuse logs").font(.title2.bold()); Spacer(); Button("Open Folder") { NSWorkspace.shared.open(log.directory) }; Button("Done") { dismiss() } }
            ScrollView { Text(log.lines.joined(separator:"\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
        }.padding(20).frame(width:800,height:500)
    }
}

private struct WindowPersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowObserver() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private class WindowObserver: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("BlueMuseMain")
            guard window.frameAutosaveName.isEmpty else { return }
            window.setFrameAutosaveName("BlueMuseMainWindow")
            window.setFrameUsingName("BlueMuseMainWindow")
        }
    }
}
