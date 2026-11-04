import XCTest
@testable import BlueMuseCore

final class TimingTests: XCTestCase {
    func testLegacyWindowsUsesPerPacketArrivalAndOriginalIntervals() {
        for sensor in Sensor.allCases {
            let clock = SampleTimestampClock(sensor:sensor,athena:false,behavior:.windowsCompatible,domain:.native)
            let count = sensor.chunkSize()
            let first = clock.timestamps(count:count,arrival:1000.123456)
            let interval = Double(Float(1000)/Float(sensor.rate))/1000
            for i in 0..<count { XCTAssertEqual(first[i],1000.123456-Double(count-i)*interval,accuracy:1e-12) }
            let second = clock.timestamps(count:count,arrival:1000.123457)
            XCTAssertEqual(second[0],1000.123457-Double(count)*interval,accuracy:1e-12)
            if count > 1 { XCTAssertLessThan(second[0],first.last!) } // compatibility intentionally permits overlap
        }
    }
    func testWindowsEpochMillisecondPrecisionAndTelemetryBackdating() {
        let clock = SampleTimestampClock(sensor:.eeg,athena:false,behavior:.windowsCompatible,domain:.epoch)
        XCTAssertEqual(clock.timestamps(count:12,arrival:1000.123999)[0],1000.123-12.0/256,accuracy:1e-12)
        let battery = SampleTimestampClock(sensor:.telemetry,athena:false,behavior:.windowsCompatible,domain:.native)
        XCTAssertEqual(battery.timestamps(count:1,arrival:1000),[990])
        let smooth = SampleTimestampClock(sensor:.telemetry,athena:false,behavior:.smoothed,domain:.native)
        XCTAssertEqual(smooth.timestamps(count:1,arrival:1000),[1000])
    }
    func testSmoothedModeRemainsMonotonicAcrossPacketBursts() {
        let clock = SampleTimestampClock(sensor:.eeg,athena:false,behavior:.smoothed,domain:.native)
        var previous = -Double.infinity
        for packet in 0..<2000 {
            let ts = clock.timestamps(count:12,arrival:1000+Double(packet*12)/256+Double(packet%3-1)*0.02)
            for t in ts { XCTAssertGreaterThan(t,previous); previous = t }
        }
    }
    struct TimestampFixture: Decodable {
        struct Block: Decodable { let count: Int; let arrival: Double; let expected: [Double] }
        let sensor: Sensor; let athena: Bool; let clock: TimestampMode; let blocks: [Block]
    }
    func testCompatibilityMatches1000OriginalCSharpTimestampBlocks() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"windows-timing-fixtures",withExtension:"json",subdirectory:"Fixtures"))
        let cases = try JSONDecoder().decode([TimestampFixture].self,from:Data(contentsOf:url))
        XCTAssertEqual(cases.reduce(0) { $0+$1.blocks.count },1000)
        for f in cases {
            let clock = SampleTimestampClock(sensor:f.sensor,athena:f.athena,behavior:.windowsCompatible,domain:f.clock)
            for block in f.blocks {
                let result = clock.timestamps(count:block.count,arrival:block.arrival)
                XCTAssertEqual(result.count,block.expected.count)
                for i in result.indices { XCTAssertEqual(result[i],block.expected[i],accuracy:1e-9,"\(f.sensor) Athena=\(f.athena) clock=\(f.clock)") }
            }
        }
    }
    func testExistingSettingsMigrateWithoutLosingOtherPreferences() throws {
        let old = #"{"primary":"LSL_LOCAL_CLOCK_NATIVE","secondary":"BLUEMUSE","double64":true,"enabled":["EEG"],"alwaysPair":true}"#
        var s = try JSONDecoder().decode(StreamSettings.self,from:Data(old.utf8))
        XCTAssertEqual(s.timingBehavior,.windowsCompatible); XCTAssertEqual(s.primary,.native)
        XCTAssertEqual(s.secondary,.epoch); XCTAssertTrue(s.double64); XCTAssertTrue(s.alwaysPair)
        XCTAssertEqual(s.enabled,[.eeg])
        XCTAssertTrue(s.set(key:"timestamp_behavior",value:"SMOOTHED"))
        let decoded = try JSONDecoder().decode(StreamSettings.self,from:JSONEncoder().encode(s))
        XCTAssertEqual(decoded.timingBehavior,.smoothed)
        XCTAssertFalse(s.set(key:"timestamp_behavior",value:"not-a-mode"))
    }
}
