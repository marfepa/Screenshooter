import XCTest
@testable import Screenshooter

final class ScrollCaptureDebugDumpTests: XCTestCase {
    func testLogLineFormat() {
        let line = ScrollCaptureDebugDump.logLine(index: 3, time: 1.23456, outcome: "appended(40)", height: 900, fixedTop: 12, fixedBottom: 0)
        XCTAssertEqual(line, "0003 t=1.235 outcome=appended(40) height=900 fixedTop=12 fixedBottom=0")
    }

    func testOutcomeDescriptions() {
        XCTAssertEqual(ScrollCaptureDebugDump.describe(nil), "first")
        XCTAssertEqual(ScrollCaptureDebugDump.describe(.unchanged), "unchanged")
        XCTAssertEqual(ScrollCaptureDebugDump.describe(.noOverlap), "noOverlap")
        XCTAssertEqual(ScrollCaptureDebugDump.describe(.limitReached), "limitReached")
    }

    func testDisabledByDefault() {
        let defaults = UserDefaults(suiteName: "dump-test-\(UUID().uuidString)")!
        XCTAssertNil(ScrollCaptureDebugDump(now: 0, defaults: defaults))
    }
}
