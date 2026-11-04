import XCTest
@testable import BlueMuseCore

final class WindowsParityTests: XCTestCase {
    struct Fixture: Decodable { let kind: String; let tag: Int; let hex: String; let expected: [[Double]] }
    func testValuesMatch1300OriginalWindowsDecoderFixtures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"windows-decoder-fixtures",withExtension:"json",subdirectory:"Fixtures"))
        let fixtures = try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:url))
        XCTAssertEqual(fixtures.count,1300)
        for (number,f) in fixtures.enumerated() {
            var bytes: [UInt8] = []; var i = f.hex.startIndex
            while i < f.hex.endIndex { let end = f.hex.index(i,offsetBy:2); bytes.append(try XCTUnwrap(UInt8(f.hex[i..<end],radix:16))); i = end }
            let decoded: [[Double]]
            switch f.kind {
            case "eeg": decoded = [try MuseWire.legacyChannel(bytes)]
            case "ppg": decoded = [try MuseWire.legacyChannel(bytes,ppg:true)]
            case "accelerometer": decoded = try MuseWire.legacyMotion(bytes,gyro:false)
            case "gyroscope": decoded = try MuseWire.legacyMotion(bytes,gyro:true)
            case "telemetry": decoded = try MuseWire.telemetry(bytes)
            default:
                var header = Array(repeating:UInt8(0),count:14); header[0] = UInt8(bytes.count+14); header[9] = UInt8(f.tag)
                let packets = AthenaPacket.parse(header+bytes)
                let streams = try XCTUnwrap(packets.first).decode()
                if f.tag == 0x47 { decoded = zip(streams[0].1,streams[1].1).map { $0+$1 } }
                else { decoded = try XCTUnwrap(streams.first).1 }
            }
            XCTAssertEqual(decoded.count,f.expected.count,"Fixture \(number)")
            for r in f.expected.indices {
                XCTAssertEqual(decoded[r].count,f.expected[r].count)
                for c in f.expected[r].indices { XCTAssertEqual(decoded[r][c],f.expected[r][c],accuracy:1e-9,"Fixture \(number): \(f.kind), tag \(f.tag), row \(r), channel \(c)") }
            }
        }
    }
    func testEveryModelProfileAndOriginalMetadata() {
        let cases: [(String,Set<Int>,Bool,String,Bool,Bool)] = [
            ("Muse-2016",[7],false,"Muse EEG Headset",true,false),
            ("Muse-2",[7,15],false,"Muse 2 EEG Headset",true,true),
            ("MuseS-1234",[7,15],false,"Muse S EEG Headset",false,true),
            ("Muse-Unknown",[15],true,"Muse S EEG Headset",false,true),
            ("MuseS-Athena",[0x13,0x14],false,"Muse S Athena EEG Headset",false,true),
            ("SMXT-1234",[7],false,"Smith Lowdown Focus",false,false)
        ]
        for (name,chars,special,metadata,aux,ppg) in cases {
            let p = MuseProfile.detect(name:name,characteristics:chars,museSSpecial:special)
            XCTAssertEqual(p.deviceMetadata,metadata); XCTAssertEqual(p.aux,aux); XCTAssertEqual(p.ppg,ppg)
        }
        XCTAssertEqual(Sensor.allCases.map { $0.chunkSize() },[12,3,3,6,1])
        XCTAssertEqual(Sensor.allCases.map { $0.chunkSize(athena:true) },[4,3,3,1,1])
        XCTAssertEqual(Sensor.allCases.map(\.rate),[256,52,52,64,0.1])
        XCTAssertEqual(Sensor.telemetry.unit(),"Various")
        XCTAssertEqual(Sensor.telemetry.unit(athena:true),"percent")
    }
    func testNestedFragmentedControlJSONAndQuotedBraces() throws {
        var parser = ControlMessageBuffer()
        let message = #"noise{"versions":{"fw":"x"},"note":"a } brace and \" quote"}{"status":true}"#
        let bytes = Array(message.utf8)
        var messages: [Data] = []
        for i in stride(from:0,to:bytes.count,by:3) { messages += parser.append(Array(bytes[i..<min(bytes.count,i+3)])) }
        XCTAssertEqual(messages.count,2)
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with:messages[0]) as? [String:Any])
        XCTAssertNotNil(first["versions"])
        XCTAssertEqual(first["note"] as? String,"a } brace and \" quote")
        XCTAssertEqual(parser.append(Array("{bad}{\"ok\":1}".utf8)).count,1)
    }
    func testOriginalSettingKeysAndDefaults() {
        var s = StreamSettings()
        XCTAssertEqual(s.primary,.epoch); XCTAssertEqual(s.secondary,.none); XCTAssertFalse(s.double64); XCTAssertFalse(s.alwaysPair)
        XCTAssertEqual(s.enabled,Set([.eeg,.accelerometer,.gyroscope,.ppg]))
        for key in ["primary_timestamp_format","secondary_timestamp_format"] {
            for mode in TimestampMode.allCases where mode != .none || key.hasPrefix("secondary") { XCTAssertTrue(s.set(key:key,value:mode.rawValue)) }
        }
        for sensor in Sensor.allCases { for enabled in ["true","false"] { XCTAssertTrue(s.set(key:sensor.settingKey.uppercased(),value:enabled)) } }
        XCTAssertTrue(s.set(key:"always_pair",value:"true"))
        for precision in ["float32","double64"] { XCTAssertTrue(s.set(key:"channel_data_type",value:precision)) }
    }
}
