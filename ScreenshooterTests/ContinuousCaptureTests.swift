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

    // MARK: - Fin del scroll pasante

    private let origin = CGPoint(x: 500, y: 400)

    func testTrackerDoesNotEndWithoutScroll() {
        let tracker = ScrollPassthroughTracker()
        XCTAssertFalse(tracker.shouldEnd(at: 100, pointer: CGPoint(x: 0, y: 0)))
    }

    func testTrackerEndsAfterSilence() {
        var tracker = ScrollPassthroughTracker(quietInterval: 1.2)
        tracker.noteScroll(at: 10.0, pointer: origin)
        XCTAssertFalse(tracker.shouldEnd(at: 11.0, pointer: origin))
        XCTAssertTrue(tracker.shouldEnd(at: 11.21, pointer: origin))
    }

    func testTrackerSurvivesTheGapBetweenTwoSwipes() {
        // El primer gesto lo recibe el overlay; el segundo, ~0,5 s después, debe encontrar el modo vivo
        var tracker = ScrollPassthroughTracker(quietInterval: 1.2)
        tracker.noteScroll(at: 10.0, pointer: origin)
        XCTAssertFalse(tracker.shouldEnd(at: 10.5, pointer: origin))
    }

    func testTrackerEndsWhenThePointerMoves() {
        var tracker = ScrollPassthroughTracker(quietInterval: 1.2, pointerTolerance: 6)
        tracker.noteScroll(at: 10.0, pointer: origin)
        XCTAssertFalse(tracker.shouldEnd(at: 10.1, pointer: CGPoint(x: 503, y: 404)))
        XCTAssertTrue(tracker.shouldEnd(at: 10.1, pointer: CGPoint(x: 510, y: 400)))
    }

    func testEachScrollReanchorsThePointer() {
        // Una rueda de ratón que tiembla al girar no saca del modo
        var tracker = ScrollPassthroughTracker(quietInterval: 1.2, pointerTolerance: 6)
        var x: CGFloat = 500
        var t = 10.0
        while t < 11.0 {
            tracker.noteScroll(at: t, pointer: CGPoint(x: x, y: 400))
            x += 3
            t += 0.016
            XCTAssertFalse(tracker.shouldEnd(at: t, pointer: CGPoint(x: x, y: 400)))
        }
    }

    func testTrackerReset() {
        var tracker = ScrollPassthroughTracker()
        tracker.noteScroll(at: 1, pointer: origin)
        tracker.reset()
        XCTAssertNil(tracker.lastScroll)
        XCTAssertFalse(tracker.shouldEnd(at: 5, pointer: .zero))
    }
}
