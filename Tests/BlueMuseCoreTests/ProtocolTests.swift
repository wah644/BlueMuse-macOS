import XCTest
@testable import BlueMuseCore

final class ProtocolTests: XCTestCase {
    func pack(_ fields: [Int], bits: Int, little: Bool) -> [UInt8] {
        var b = Array(repeating: UInt8(0), count: (fields.count*bits+7)/8)
        for (i,v) in fields.enumerated() { for j in 0..<bits {
            let p = i*bits+j
            let bit = (v >> (little ? j : bits-j-1)) & 1
            b[p/8] |= UInt8(bit << (little ? p%8 : 7-p%8))
        } }; return b
    }
    func primary(_ tag: UInt8, payload: [UInt8], index: Int = 700, sub: [UInt8] = []) -> [UInt8] {
        var h = Array(repeating: UInt8(0),count:14); h[0] = UInt8(14+payload.count+sub.count); h[1] = UInt8(index&255); h[2] = UInt8(index>>8); h[9] = tag; h[10] = 3; return h+payload+sub
    }
    func testLegacyEEGAndPPGBitOrderAndScaling() throws {
        let eeg = try MuseWire.legacyChannel([0,0]+pack([0,2048,4095,1,3000,42,12,64,128,256,512,1024],bits:12,little:false))
        XCTAssertEqual(eeg[0],-1000); XCTAssertEqual(eeg[1],0); XCTAssertEqual(eeg[2],999.51171875)
        let ppg = try MuseWire.legacyChannel([0,1]+pack([1,0xffffff,256,65536,42,0],bits:24,little:false),ppg:true)
        XCTAssertEqual(ppg,[1,16777215,256,65536,42,0]); XCTAssertThrowsError(try MuseWire.legacyChannel([0]))
    }
    func testLegacySignedMotionAndTelemetry() throws {
        let motion = [0,0]+pack([32767,32768,65535,1,2,3,4,5,6],bits:16,little:false)
        let acc = try MuseWire.legacyMotion(motion,gyro:false)
        XCTAssertEqual(acc[0][1],-32768*0.0000610352,accuracy:1e-9)
        XCTAssertEqual(try MuseWire.legacyMotion(motion,gyro:true)[0][2],-0.0074768,accuracy:1e-9)
        XCTAssertEqual(try MuseWire.telemetry([0,0]+pack([51200,10,30,40],bits:16,little:false))[0],[100,22,30,40])
    }
    func testAthenaEEGLayoutsAndExtremes() throws {
        for (tag,channels,samples) in [(UInt8(0x11),4,4),(UInt8(0x12),8,2)] {
            let data = pack(Array(0..<16),bits:14,little:true)
            let packets = AthenaPacket.parse(primary(tag,payload:data))
            XCTAssertEqual(packets.count,1); XCTAssertEqual(packets[0].index,700)
            let decoded = try packets[0].decode()[0].1
            XCTAssertEqual(decoded.count,samples)
            XCTAssertEqual(decoded[1][3],Double(channels+3-8192)*1450/16383,accuracy:1e-9)
        }
        for v in [0,8192,16383] {
            let packet = AthenaPacket.parse(primary(0x11,payload:pack(Array(repeating:v,count:16),bits:14,little:true)))[0]
            XCTAssertEqual(try packet.decode()[0].1[0][0],Double(v-8192)*1450/16383,accuracy:1e-9)
        }
    }
    func testAthenaOpticsCanonicalChannels() throws {
        for (tag,channels,samples) in [(UInt8(0x34),4,3),(UInt8(0x35),8,2),(UInt8(0x36),16,1)] {
            let data = pack(Array(1...channels*samples),bits:20,little:true)
            let rows = try AthenaPacket.parse(primary(tag,payload:data))[0].decode()[0].1
            XCTAssertEqual(rows.count,samples); XCTAssertEqual(rows[0].count,16)
            let offset = tag == 0x34 ? 4 : 0
            XCTAssertEqual(rows[0][offset],1); XCTAssertEqual(rows[samples-1][offset+channels-1],Double(channels*samples))
            if tag == 0x34 { XCTAssertEqual(rows[0][0],0) }
        }
    }
    func testAthenaSignedIMUAndBattery() throws {
        let imu = pack([1,2,3,1000,64536,65535]+Array(repeating:0,count:12),bits:16,little:true)
        let streams = try AthenaPacket.parse(primary(0x47,payload:imu))[0].decode()
        XCTAssertEqual(streams[0].0,.accelerometer); XCTAssertEqual(streams[1].0,.gyroscope)
        XCTAssertEqual(streams[1].1[0][0],-7.4768,accuracy:1e-9); XCTAssertEqual(streams[1].1[0][1],7.4768,accuracy:1e-9)
        XCTAssertEqual(try AthenaPacket.parse(primary(0x88,payload:[0,200]))[0].decode()[0].1[0][0],100)
    }
    func testMultiplexedConcatenatedAndMalformedPackets() throws {
        let p = primary(0x11,payload:Array(repeating:0,count:28),sub:[0x47,2,0,0,0]+Array(repeating:0,count:36))
        let parsed = AthenaPacket.parse(p+primary(0x88,payload:[0,2],index:701))
        XCTAssertEqual(parsed.map(\.tag),[0x11,0x47,0x88]); XCTAssertEqual(parsed[1].block,2); XCTAssertEqual(parsed[1].index,700)
        XCTAssertEqual(AthenaPacket.parse(Array(p.dropLast())).count,0)
        XCTAssertEqual(AthenaPacket.parse(primary(0x11,payload:[0,0])).count,0)
        XCTAssertEqual(AthenaPacket.parse(primary(0x77,payload:[0,0])).count,0)
        for length in 0..<120 { _ = AthenaPacket.parse(Array(repeating:UInt8(length),count:length)) }
        XCTAssertThrowsError(try MuseWire.bits([0],0,9))
    }
    func testCommandAndURLCompatibility() throws {
        XCTAssertEqual(Array(MuseWire.command("dc001")),[6,100,99,48,48,49,10])
        let c = ProtocolCommand(URL(string:"bluemuse://setting?key=channel_data_type!value=float32")!)!
        XCTAssertEqual(c.action,"setting"); XCTAssertEqual(c.arguments["value"],"float32")
        XCTAssertEqual(ProtocolCommand(URL(string:"bluemuse://start?startall")!)!.arguments["startall"],"true")
        XCTAssertEqual(ProtocolCommand(URL(string:"bluemuse://start?addresses=Muse%20One,UUID")!)!.arguments["addresses"],"Muse One,UUID")
        XCTAssertNil(ProtocolCommand(URL(string:"https://example.com")!))
    }
    func testSettingsAndSecondaryTimestampPrecision() throws {
        var s = StreamSettings()
        XCTAssertFalse(s.set(key:"primary_timestamp_format",value:"NONE"))
        XCTAssertTrue(s.set(key:"channel_data_type",value:"float32")); XCTAssertTrue(s.set(key:"secondary_timestamp_format",value:"BLUEMUSE"))
        let time = 1793827301.123456
        let sample = s.sample([1],secondary:time).map(Float.init)
        XCTAssertEqual(Double(sample[1])+Double(sample[2]),time,accuracy:1e-5)
        XCTAssertTrue(s.set(key:"eeg_enabled",value:"false")); XCTAssertFalse(s.enabled.contains(.eeg))
        XCTAssertFalse(s.set(key:"ppg_enabled",value:"perhaps"))
        XCTAssertEqual(try JSONDecoder().decode(StreamSettings.self,from:JSONEncoder().encode(s)).secondary,.epoch)
    }
    func testTimestampPacketBoundariesStayMonotonicUnderBluetoothJitter() {
        for (rate, count) in [(256.0,12),(52.0,3),(64.0,6)] {
            let clock = TimestampFit(rate:rate,arrival:1000)
            var previous = -Double.infinity
            for packet in 0..<3000 {
                let jitter = [0.02,-0.02,0.005,0.0][packet%4]
                let rows = clock.timestamps(count:count,arrival:1000+Double(packet*count+count-1)/rate+jitter)
                for t in rows { XCTAssertGreaterThan(t,previous); previous = t }
            }
            XCTAssertLessThan(abs(previous-(1000+Double(3000*count-1)/rate)),0.15)
        }
    }
    func testGraphHistoryIsBoundedAndRetainsRawValuesAndGaps() {
        let h = SignalHistory(capacity:10)
        for i in 0..<20 { h.append(time:Double(i),values:[Double(i), .nan]) }
        let all = h.points(seconds:100)
        XCTAssertEqual(all.count,10); XCTAssertEqual(all.first?.time,10); XCTAssertEqual(all.last?.time,19)
        XCTAssertEqual(h.points(seconds:3).map(\.time),[16,17,18,19])
        XCTAssertTrue(all[0].values[1].isNaN)
        XCTAssertEqual(all.last?.values.first,19)
    }
    func testTimestampFitConvergesAndRemainsFinite() {
        let fit = TimestampFit(rate:256,arrival:1000)
        var ts: [Double] = []
        let realRate = 256/1.01
        for packet in 0..<2000 {
            let arrival = 1000+Double(packet*4+3)/realRate+Double(packet%3-1)*0.005
            ts = fit.timestamps(count:4,arrival:arrival)
            XCTAssertTrue(ts.allSatisfy(\.isFinite)); XCTAssertLessThan(ts[0],ts[3])
        }
        XCTAssertEqual(ts[1]-ts[0],1/realRate,accuracy:0.000001)
        XCTAssertEqual(ts[3],1000+7999/realRate,accuracy:0.01)
    }
}
