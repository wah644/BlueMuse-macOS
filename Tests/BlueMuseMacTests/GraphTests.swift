import XCTest
import SwiftUI
import BlueMuseCore
@testable import BlueMuseMac

final class GraphTests: XCTestCase {
    @MainActor func testGraphRendersRawChannelHistory() throws {
        _ = NSApplication.shared
        let display = SignalDisplay()
        display.points[.eeg] = (0..<1280).map { i in
            let t = Double(i)/256
            return SignalPoint(time:t,values:(0..<5).map { c in 100*sin(t*Double(c+1)*6.28)+20*sin(t*60)+Double(c)*200 })
        }
        for width in [460.0, 900.0] {
            let view = SignalGraph(sensor:.eeg,labels:["TP9","AF7","AF8","TP10","Right AUX"],unit:"microvolts",display:display,active:true)
                .padding(20).frame(width:width,height:420).background(Color(nsColor:.windowBackgroundColor))
            try render(view, width:width, height:420, name:"eeg-\(Int(width))")
        }
        let help = LSLHelpView(deviceID:"DEVICE_UUID",primary:.native,behavior:.windowsCompatible)
        try render(help,width:690,height:710,name:"lsl-help")
        display.points[.telemetry] = [SignalPoint(time:10,values:[50,3176.8,0,0])]
        let telemetry = SignalGraph(sensor:.telemetry,labels:["Battery","Unknown (fuel?)","ADC Voltage","Temperature"],unit:"",display:display,active:true)
            .padding(20).frame(width:600,height:350).background(Color(nsColor:.windowBackgroundColor))
        try render(telemetry,width:600,height:350,name:"telemetry")
    }
    @MainActor private func render<V: View>(_ view: V, width: Double, height: Double, name: String) throws {
        let host = NSHostingView(rootView:view)
        host.frame = NSRect(x:0,y:0,width:width,height:height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        XCTAssertGreaterThan(png.count,5000)
        try png.write(to:URL(fileURLWithPath:"/tmp/bluemuse-graph-\(name).png"))
    }
}
