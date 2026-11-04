import SwiftUI
import BlueMuseCore

struct LSLHelpView: View {
    let deviceID: String
    let primary: TimestampMode
    let behavior: TimingBehavior
    @Environment(\.dismiss) var dismiss
    private var sourceID: String { "muse_4ch_bridge_BlueMuse:\(deviceID):EEG" }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Label("About MUSE_4CH",systemImage:"antenna.radiowaves.left.and.right").font(.title2.bold())
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text("Muse → BlueMuse → MUSE_4CH → your receiver").font(.headline)
                    Text("LSL (Lab Streaming Layer) makes this live stream discoverable to programs on your Mac and, where networking permits, your local network. There is no fixed destination or cloud upload. Start MUSE_4CH publishes; a separate receiver must subscribe.")
                    Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:8) {
                        GridRow { Text("Stream name").foregroundStyle(.secondary); Text("MUSE_4CH").monospaced() }
                        GridRow { Text("Type / format").foregroundStyle(.secondary); Text("EEG · 4 channels · float32 · microvolts") }
                        GridRow { Text("Channel order").foregroundStyle(.secondary); Text("TP9, AF7, AF8, TP10") }
                        GridRow { Text("Nominal rate").foregroundStyle(.secondary); Text("256 samples per second") }
                        GridRow { Text("Clock / timing").foregroundStyle(.secondary); Text("\(primary.title) · \(behavior.title)") }
                    }
                    Text("Source ID: \(sourceID)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("The four electrodes remain separate. AUX and secondary timestamp columns are excluded. This output does not save a CSV, train a model, or make predictions. The sample counter means published samples; it does not confirm a receiver is connected.").foregroundStyle(.secondary)
                    Divider()
                    Text("Build a receiver").font(.headline)
                    Text("1. Press Start MUSE_4CH in BlueMuse.\n2. In a separate Python environment, install pylsl: python3 -m pip install pylsl\n3. Run the example below. Replace print with buffering, preprocessing, classification, or recording.")
                    HStack {
                        Text("Python example").font(.subheadline.bold()); Spacer()
                        Button("Copy Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.receiverCode,forType:.string) }
                    }
                    Text(Self.receiverCode).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    Text("For several headsets, select by source_id rather than stream name; each headset has its own source ID. The public repository's examples/receive_muse.py supports --source-id and optional --csv recording.")
                    Divider()
                    Text("Timing and synchronization").font(.headline)
                    Text(behavior.note)
                    Text("The four-channel output preserves the EEG stream's timestamps. Select an LSL clock before starting if you need synchronization with other LSL streams. Unix epoch and LSL clock values have different origins. Smoothing is separate from clock synchronization; neither option is a timing calibration. Changes in Settings apply after a stream restart.").foregroundStyle(.secondary)
                }.font(.callout).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(24).frame(width:690,height:710).background(Color(nsColor:.windowBackgroundColor))
    }
    static let receiverCode = #"""
from pylsl import resolve_byprop, StreamInlet

streams = resolve_byprop("name", "MUSE_4CH", timeout=10)
if len(streams) != 1:
    raise RuntimeError("Start one MUSE_4CH stream, or select by source_id.")

inlet = StreamInlet(streams[0], processing_flags=0)
try:
    while True:
        sample, timestamp = inlet.pull_sample(timeout=1)
        if sample is not None:
            # sample order: TP9, AF7, AF8, TP10 (microvolts)
            print(timestamp, sample)
finally:
    inlet.close_stream()
"""#
}
