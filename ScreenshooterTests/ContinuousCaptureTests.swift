import XCTest
@testable import Screenshooter

final class ContinuousCaptureTests: XCTestCase {

    private func run(_ events: [ContinuousCaptureEvent], from state: ContinuousCaptureState = .idle) -> ContinuousCaptureState {
        events.reduce(state) { ContinuousCaptureMachine.next($0, on: $1) }
    }

    // MARK: - Máquina de estados

    func testHotKeyStartsSelectingAndTogglesNavigate() {
        XCTAssertEqual(run([.hotKey]), .selecting)
        XCTAssertEqual(run([.hotKey, .hotKey]), .navigating)
        XCTAssertEqual(run([.hotKey, .hotKey, .hotKey]), .selecting)
    }

    func testScrollPassthroughReturnsToSelecting() {
        XCTAssertEqual(run([.hotKey, .scrollBegan]), .scrollPassthrough)
        XCTAssertEqual(run([.hotKey, .scrollBegan, .scrollEnded]), .selecting)
    }

    func testHotKeyDuringScrollGoesToNavigate() {
        XCTAssertEqual(run([.hotKey, .scrollBegan, .hotKey]), .navigating)
    }

    func testScrollOutsideSelectingIsIgnored() {
        XCTAssertEqual(run([.scrollBegan]), .idle)
        XCTAssertEqual(run([.hotKey, .hotKey, .scrollBegan]), .navigating)
        XCTAssertEqual(run([.hotKey, .selectionCompleted, .scrollBegan]), .processing)
        XCTAssertEqual(run([.hotKey, .scrollEnded]), .selecting)
    }

    func testCaptureCycleKeepsTheModeAlive() {
        XCTAssertEqual(run([.hotKey, .selectionCompleted]), .processing)
        XCTAssertEqual(run([.hotKey, .selectionCompleted, .captureFinished]), .selecting)
    }

    func testHotKeyWhileProcessingIsIgnored() {
        XCTAssertEqual(run([.hotKey, .selectionCompleted, .hotKey]), .processing)
    }

    func testSelectionOnlyCountsWhileSelecting() {
        XCTAssertEqual(run([.hotKey, .scrollBegan, .selectionCompleted]), .scrollPassthrough)
        XCTAssertEqual(run([.hotKey, .hotKey, .selectionCompleted]), .navigating)
    }

    func testCancelEndsTheModeFromAnyState() {
        let states: [ContinuousCaptureState] = [.idle, .selecting, .scrollPassthrough, .processing, .navigating]
        for state in states {
            XCTAssertEqual(ContinuousCaptureMachine.next(state, on: .cancel), .idle, "\(state)")
        }
    }

    func testIsActive() {
        XCTAssertFalse(ContinuousCaptureState.idle.isActive)
        XCTAssertTrue(ContinuousCaptureState.navigating.isActive)
        XCTAssertTrue(ContinuousCaptureState.scrollPassthrough.isActive)
    }

    // MARK: - Fin del scroll por silencio

    func testScrollTrackerIsNotQuietWithoutScroll() {
        let tracker = ScrollQuietTracker(quietInterval: 0.35)
        XCTAssertFalse(tracker.isQuiet(at: 100))
    }

    func testScrollTrackerWaitsForSilence() {
        var tracker = ScrollQuietTracker(quietInterval: 0.35)
        tracker.noteScroll(at: 10.0)
        XCTAssertFalse(tracker.isQuiet(at: 10.2))
        XCTAssertTrue(tracker.isQuiet(at: 10.36))
    }

    func testMomentumEventsExtendTheGesture() {
        var tracker = ScrollQuietTracker(quietInterval: 0.35)
        // Gesto + inercia: un evento cada ~16 ms durante 1 s
        var t = 10.0
        while t < 11.0 {
            tracker.noteScroll(at: t)
            XCTAssertFalse(tracker.isQuiet(at: t + 0.016))
            t += 0.016
        }
        XCTAssertTrue(tracker.isQuiet(at: t + 0.35))
    }

    func testScrollTrackerReset() {
        var tracker = ScrollQuietTracker()
        tracker.noteScroll(at: 1)
        tracker.reset()
        XCTAssertNil(tracker.lastScroll)
        XCTAssertFalse(tracker.isQuiet(at: 5))
    }
}
