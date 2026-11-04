import XCTest
import BlueMuseCore
@testable import BlueMuseMac

final class LSLTests: XCTestCase {
    func testRealOutletToInletBothPrecisionsAndTimestampLayouts() throws {
        let lsl = LSL.shared
        XCTAssertNotNil(lsl.handle, lsl.error ?? "")
        guard lsl.handle != nil else { return }
        let resolve = lsl.symbol("lsl_resolve_byprop", (@convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>, UInt32, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, Double) -> Int32).self)
        let createInlet = lsl.symbol("lsl_create_inlet", (@convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32) -> UnsafeMutableRawPointer?).self)
        let destroyInfo = lsl.symbol("lsl_destroy_streaminfo", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        let destroyInlet = lsl.symbol("lsl_destroy_inlet", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        let open = lsl.symbol("lsl_open_stream", (@convention(c) (UnsafeMutableRawPointer, Double, UnsafeMutablePointer<Int32>) -> Void).self)
        let pull = lsl.symbol("lsl_pull_sample_d", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Double>, Int32, Double, UnsafeMutablePointer<Int32>) -> Double).self)
        for fourChannel in [false,true] { for double64 in [true,false] { for secondary in [TimestampMode.none,.epoch] {
            var settings = StreamSettings(); settings.double64 = double64; settings.primary = .native; settings.secondary = secondary
            let id = UUID().uuidString
            let native = fourChannel ? try FourChannelStream(device:"BlueMuse TEST ONLY",id:id,model:"Muse 2",primary:settings.primary) : nil
            let outlet = try native?.outlet ?? Outlet(device:"BlueMuse TEST ONLY",id:id,model:"Muse 2",sensor:.eeg,athena:false,aux:false,settings:settings)
            var infos = Array<UnsafeMutableRawPointer?>(repeating:nil,count:4)
            let found = resolve(&infos,4,"source_id",fourChannel ? "muse_4ch_bridge_BlueMuse:\(id):EEG" : "BlueMuse:\(id):EEG",1,5)
            XCTAssertGreaterThan(found,0)
            guard found > 0, let info = infos[0] else { continue }
            defer { for i in 0..<Int(found) { if let ptr = infos[i] { destroyInfo(ptr) } } }
            let count = lsl.symbol("lsl_get_channel_count", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)(info)
            XCTAssertEqual(Int(count),4+(fourChannel || secondary == .none ? 0 : double64 ? 1 : 2))
            let format = lsl.symbol("lsl_get_channel_format", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)(info)
            XCTAssertEqual(format,!fourChannel && double64 ? 2 : 1)
            let inlet = try XCTUnwrap(createInlet(info,10,0,0)); defer { destroyInlet(inlet) }
            var ec: Int32 = 0; open(inlet,5,&ec); XCTAssertEqual(ec,0)
            // wait_for_consumers avoids pushing before the subscription is active.
            let wait = lsl.symbol("lsl_wait_for_consumers", (@convention(c) (UnsafeMutableRawPointer, Double) -> Int32).self)
            XCTAssertEqual(wait(outlet.pointer,5),1)
            let timestamp = lsl.clock(), second = 1793827301.123456
            if let native {
                XCTAssertEqual(outlet.name,"MUSE_4CH")
                XCTAssertEqual(outlet.labels,["TP9","AF7","AF8","TP10"])
                XCTAssertThrowsError(try native.push([1,2,3],timestamp:timestamp))
                try native.push([1.25,-2.5,3.75,4,9999,second],timestamp:timestamp)
                XCTAssertEqual(native.sampleCount,1)
            } else { for sample in 0..<12 { try outlet.push([1.25,-2.5,3.75,4],timestamp:timestamp+Double(sample)/256,secondary:second+Double(sample)/256) } }
            var row = Array(repeating:0.0,count:Int(count))
            let receivedTime = pull(inlet,&row,count,5,&ec)
            XCTAssertEqual(ec,0); XCTAssertEqual(receivedTime,timestamp,accuracy:1e-6)
            XCTAssertEqual(Array(row.prefix(4)),[1.25,-2.5,3.75,4])
            if !fourChannel && secondary != .none { XCTAssertEqual(row[4]+(double64 ? 0 : row[5]),second,accuracy:1e-5) }
        } } }
    }
    func testAllSensorOutletShapesAndMetadata() throws {
        guard LSL.shared.handle != nil else { XCTFail("Missing framework"); return }
        for athena in [true,false] { for sensor in Sensor.allCases {
            let outlet = try Outlet(device:"BlueMuse TEST ONLY",id:UUID().uuidString,model:athena ? "Muse S Athena EEG Headset" : "Muse EEG Headset",sensor:sensor,athena:athena,aux:!athena,settings:StreamSettings())
            XCTAssertEqual(outlet.labels,sensor.labels(athena:athena,aux:!athena))
            let lsl = LSL.shared
            let info = try XCTUnwrap(lsl.symbol("lsl_get_info", (@convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?).self)(outlet.pointer))
            defer { lsl.symbol("lsl_destroy_streaminfo", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(info) }
            let xmlPointer = try XCTUnwrap(lsl.symbol("lsl_get_xml", (@convention(c) (UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?).self)(info))
            let xml = String(cString:xmlPointer)
            lsl.symbol("lsl_destroy_string", (@convention(c) (UnsafeMutablePointer<CChar>) -> Void).self)(xmlPointer)
            XCTAssertTrue(xml.contains("<manufacturer>Interaxon</manufacturer>"))
            XCTAssertTrue(xml.contains("<device>\(athena ? "Muse S Athena EEG Headset" : "Muse EEG Headset")</device>"))
            XCTAssertTrue(xml.contains("<unit>\(sensor.unit(athena:athena))</unit>"))
            for label in sensor.labels(athena:athena,aux:!athena) { XCTAssertTrue(xml.contains("<label>\(label)</label>")) }

            try outlet.push(Array(repeating:0,count:outlet.labels.count),timestamp:LSL.shared.clock(),secondary:0)
            XCTAssertThrowsError(try outlet.push([],timestamp:1,secondary:0))
        } }
        XCTAssertLessThan(abs(LSL.shared.now(.host)-LSL.shared.now(.native)),0.01)
    }
}
