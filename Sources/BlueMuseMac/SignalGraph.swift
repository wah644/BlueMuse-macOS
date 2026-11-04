import SwiftUI
import BlueMuseCore

struct SignalGraph: View {
    let sensor: Sensor
    let labels: [String]
    let unit: String
    @ObservedObject var display: SignalDisplay
    let active: Bool
    @State private var selectedSeconds: Double?
    private var seconds: Double { selectedSeconds ?? (sensor == .telemetry ? 60 : 5) }
    @State private var frozen: [SignalPoint]?
    private let colors: [Color] = [.cyan, .purple, .orange, .green, .pink, .blue, .mint, .yellow]
    var body: some View {
        let points = frozen ?? display.points[sensor] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("RAW SIGNAL").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Text(frozen != nil ? "Paused view" : active ? "Live" : "Stopped").font(.caption).foregroundStyle(frozen != nil ? Color.orange : active ? .green : .secondary)
                Spacer()
                HStack(spacing: 8) {
                    Text("Time window").font(.caption).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Picker("Time window", selection: Binding(get: { seconds }, set: { selectedSeconds = $0 })) {
                        if sensor == .telemetry { Text("30 s").tag(30.0); Text("60 s").tag(60.0); Text("120 s").tag(120.0) }
                        else { Text("2 s").tag(2.0); Text("5 s").tag(5.0); Text("10 s").tag(10.0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: sensor == .telemetry ? 170 : 150)
                }.fixedSize(horizontal: true, vertical: false)
                Button { if frozen == nil { frozen = display.points[sensor] ?? [] } else { frozen = nil } } label: { Image(systemName: frozen == nil ? "pause.fill" : "play.fill") }.buttonStyle(.borderless).help("Pause the graph while LSL keeps streaming")
            }
            Canvas { context, size in
                draw(context: &context, size: size, points: points)
            }
            .frame(height: CGFloat(labels.count)*57+24)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Live \(sensor.rawValue) signal plot: \(labels.joined(separator: ", ")). \(seconds.formatted()) seconds, each channel automatically scaled.")
            Text("Each channel auto-scaled · raw \(unit.isEmpty ? "values" : unit) · no display filters").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func draw(context: inout GraphicsContext, size: CGSize, points: [SignalPoint]) {
        let left = 75.0, right = 9.0, bottom = 22.0
        let width = max(1, size.width-left-right)
        let laneHeight = (size.height-bottom)/CGFloat(max(1,labels.count))
        let end = points.last?.time ?? 0
        let start = end-seconds
        let visible = points.filter { $0.time >= start && $0.time <= end }
        for tick in 0...5 {
            let x = left+Double(tick)*width/5
            var grid = Path(); grid.move(to: CGPoint(x:x,y:0)); grid.addLine(to: CGPoint(x:x,y:size.height-bottom))
            context.stroke(grid, with:.color(.secondary.opacity(0.12)), style:StrokeStyle(lineWidth:1,dash:[2,4]))
            let label = String(format:"%.0f s",-seconds+Double(tick)*seconds/5)
            context.draw(Text(label).font(.system(size:9,design:.monospaced)).foregroundColor(.secondary),at:CGPoint(x:x,y:size.height-9),anchor:.center)
        }
        for channel in labels.indices {
            let color = colors[channel%colors.count]
            let top = CGFloat(channel)*laneHeight, mid = top+laneHeight/2
            let values = visible.compactMap { p -> Double? in guard channel < p.values.count, p.values[channel].isFinite else { return nil }; return p.values[channel] }
            let lo = values.min() ?? -1, hi = values.max() ?? 1
            let span = max(hi-lo, max(abs(hi)*0.001,0.001))
            let center = (hi+lo)/2
            context.draw(Text(labels[channel]).font(.system(size:10,weight:.medium)).foregroundColor(color),at:CGPoint(x:8,y:mid-7),anchor:.leading)
            context.draw(Text(String(format:"Δ %.1f",hi-lo)).font(.system(size:8,design:.monospaced)).foregroundColor(.secondary),at:CGPoint(x:8,y:mid+9),anchor:.leading)
            var baseline = Path(); baseline.move(to:CGPoint(x:left,y:mid)); baseline.addLine(to:CGPoint(x:size.width-right,y:mid))
            context.stroke(baseline,with:.color(.secondary.opacity(0.15)),lineWidth:0.5)
            // Min/max buckets preserve narrow peaks when more samples than screen pixels arrive.
            var buckets: [Int: (lo:Double,hi:Double,first:Double,last:Double)] = [:]
            for p in visible where channel < p.values.count {
                let value = p.values[channel]; guard value.isFinite else { continue }
                let pixel = min(Int(width),max(0,Int((p.time-start)/seconds*width)))
                if let old = buckets[pixel] { buckets[pixel] = (min(old.lo,value),max(old.hi,value),old.first,value) }
                else { buckets[pixel] = (value,value,value,value) }
            }
            func y(_ v:Double) -> CGFloat { mid-CGFloat((v-center)/span)*laneHeight*0.76 }
            var trace = Path(); var first = true; var previousPixel = -100; var previousValue = 0.0
            for pixel in buckets.keys.sorted() {
                guard let b = buckets[pixel] else { continue }
                let x = left+Double(pixel)
                if first || (sensor != .telemetry && pixel-previousPixel > max(4,Int(width/seconds*0.2))) { trace.move(to:CGPoint(x:x,y:y(b.first))); first = false }
                else {
                    if sensor == .telemetry { trace.addLine(to:CGPoint(x:x,y:y(previousValue))) }
                    trace.addLine(to:CGPoint(x:x,y:y(b.first)))
                }
                trace.addLine(to:CGPoint(x:x,y:y(b.lo))); trace.addLine(to:CGPoint(x:x,y:y(b.hi))); trace.addLine(to:CGPoint(x:x,y:y(b.last))); previousPixel = pixel; previousValue = b.last
                if sensor == .telemetry || buckets.count < 5 {
                    context.fill(Path(ellipseIn:CGRect(x:x-2.5,y:y(b.last)-2.5,width:5,height:5)),with:.color(color))
                }
            }
            context.stroke(trace,with:.color(color),style:StrokeStyle(lineWidth:1.1,lineJoin:.round))
            if values.isEmpty { context.draw(Text("Waiting for samples").font(.caption2).foregroundColor(.secondary),at:CGPoint(x:left+width/2,y:mid)) }
        }
    }
}
