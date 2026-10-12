import XCTest
import AppKit
@testable import Screenshooter

final class ScrollCaptureModelTests: XCTestCase {

    private func model() -> ScrollCaptureModel { ScrollCaptureModel(startedAt: 0) }

    /// Modelo con un fotograma añadido en t=1 (acceptedFrames == 2).
    private func modelWithFrames() -> ScrollCaptureModel {
        var m = model()
        m.apply(.appended(rows: 100), at: 1)
        return m
    }

    // MARK: - Outcomes

    func testInitialState() {
        let m = model()
        XCTAssertEqual(m.phase, .capturing)
        XCTAssertEqual(m.acceptedFrames, 1)
    }

    func testAppendedCountsFramesAndStaysCapturing() {
        var m = model()
        m.apply(.appended(rows: 50), at: 1)
        m.apply(.appended(rows: 50), at: 2)
        XCTAssertEqual(m.acceptedFrames, 3)
        XCTAssertEqual(m.phase, .capturing)
    }

    func testNoOverlapWarnsAndAppendedClearsIt() {
        var m = model()
        m.apply(.noOverlap, at: 1)
        XCTAssertEqual(m.phase, .warnTooFast)
        m.apply(.appended(rows: 10), at: 2)
        XCTAssertEqual(m.phase, .capturing)
    }

    func testUnchangedClearsWarnOnly() {
        var m = model()
        m.apply(.noOverlap, at: 1)
        m.apply(.unchanged, at: 2)
        XCTAssertEqual(m.phase, .capturing)
        m.apply(.unchanged, at: 3)
        XCTAssertEqual(m.phase, .capturing)
        XCTAssertEqual(m.acceptedFrames, 1)
    }

    func testLimitReachedIsTerminalAgainstOutcomes() {
        var m = modelWithFrames()
        m.apply(.limitReached, at: 2)
        XCTAssertEqual(m.phase, .limitReached)
        for o: ScrollStitcher.Outcome in [.appended(rows: 5), .unchanged, .noOverlap] {
            m.apply(o, at: 3)
            XCTAssertEqual(m.phase, .limitReached)
        }
        XCTAssertEqual(m.acceptedFrames, 2)
    }

    func testLimitReachedChangedByCancelAndStitching() {
        var m = modelWithFrames()
        m.apply(.limitReached, at: 2)
        XCTAssertEqual(m.requestCancel(), .askConfirmation)
        XCTAssertEqual(m.phase, .confirmingCancel)
        m.dismissCancel()
        XCTAssertEqual(m.phase, .limitReached)
        m.beginStitching()
        XCTAssertEqual(m.phase, .stitching)
    }

    // MARK: - Final del contenido

    func testAtEndBoundary() {
        var m = modelWithFrames()
        m.noteScrollAttempt(towardEnd: true, at: 10)
        m.noteScrollAttempt(towardEnd: true, at: 11.49)
        m.tick(at: 11.49)
        XCTAssertEqual(m.phase, .capturing)
        m.noteScrollAttempt(towardEnd: true, at: 11.5)
        m.tick(at: 11.5)
        XCTAssertEqual(m.phase, .atEnd)
    }

    func testAtEndNeedsFreshAttempt() {
        var m = modelWithFrames()
        m.noteScrollAttempt(towardEnd: true, at: 10)
        m.noteScrollAttempt(towardEnd: true, at: 11)
        m.tick(at: 11.6)   // último intento hace 0,6 s > 0,5
        XCTAssertEqual(m.phase, .capturing)
        m.tick(at: 11.5)   // hace 0,5 s: límite inclusivo
        XCTAssertEqual(m.phase, .atEnd)
    }

    func testNoAttemptsNeverAtEnd() {
        var m = modelWithFrames()
        m.tick(at: 1000)
        XCTAssertEqual(m.phase, .capturing)
    }

    func testAtEndNeedsMoreThanOneFrame() {
        var m = model()
        m.noteScrollAttempt(towardEnd: true, at: 10)
        m.noteScrollAttempt(towardEnd: true, at: 12)
        m.tick(at: 12)
        XCTAssertEqual(m.phase, .capturing)
    }

    func testUpwardAttemptsDoNotCount() {
        var m = modelWithFrames()
        m.noteScrollAttempt(towardEnd: false, at: 10)
        m.noteScrollAttempt(towardEnd: false, at: 12)
        m.tick(at: 12)
        XCTAssertEqual(m.phase, .capturing)
        // Y no inician la ventana: la primera hacia el final es en 12
        m.noteScrollAttempt(towardEnd: true, at: 12)
        m.tick(at: 12)
        XCTAssertEqual(m.phase, .capturing)
    }

    func testAppendedAfterAtEndReturnsToCapturingAndResetsWindow() {
        var m = modelWithFrames()
        m.noteScrollAttempt(towardEnd: true, at: 10)
        m.noteScrollAttempt(towardEnd: true, at: 11.6)
        m.tick(at: 11.6)
        XCTAssertEqual(m.phase, .atEnd)
        m.apply(.appended(rows: 20), at: 11.7)   // scroll infinito
        XCTAssertEqual(m.phase, .capturing)
        m.noteScrollAttempt(towardEnd: true, at: 11.8)
        m.tick(at: 11.8)   // la ventana empezó en 11,8
        XCTAssertEqual(m.phase, .capturing)
    }

    // MARK: - Inactividad

    func testInactivityBoundaries() {
        let m = model()
        XCTAssertEqual(m.inactivity(at: 50), .none)
        XCTAssertEqual(m.inactivity(at: 109.9), .none)
        XCTAssertEqual(m.inactivity(at: 110), .warning(secondsLeft: 10))
        XCTAssertEqual(m.inactivity(at: 119.9), .warning(secondsLeft: 1))
        XCTAssertEqual(m.inactivity(at: 120), .expired)
        XCTAssertEqual(m.inactivity(at: 500), .expired)
    }

    func testAppendedResetsInactivity() {
        var m = model()
        m.apply(.appended(rows: 5), at: 100)
        XCTAssertEqual(m.inactivity(at: 209.9), .none)
        XCTAssertEqual(m.inactivity(at: 215.5), .warning(secondsLeft: 5))
    }

    func testUnchangedAndNoOverlapDoNotResetInactivity() {
        var m = model()
        m.apply(.unchanged, at: 100)
        m.apply(.noOverlap, at: 110)
        m.apply(.unchanged, at: 115)
        XCTAssertEqual(m.inactivity(at: 119.9), .warning(secondsLeft: 1))
        XCTAssertEqual(m.inactivity(at: 120), .expired)
    }

    // MARK: - Cancelación

    func testCancelWithOneFrameIsImmediate() {
        var m = model()
        XCTAssertEqual(m.requestCancel(), .cancelNow)
        XCTAssertEqual(m.phase, .capturing)
    }

    func testCancelWithTwoFramesAsksAndDismissRestoresPhase() {
        var m = modelWithFrames()
        m.apply(.noOverlap, at: 2)
        XCTAssertEqual(m.requestCancel(), .askConfirmation)
        XCTAssertEqual(m.phase, .confirmingCancel)
        m.dismissCancel()
        XCTAssertEqual(m.phase, .warnTooFast)
    }

    func testOutcomesIgnoredWhileConfirmingCancel() {
        var m = modelWithFrames()
        _ = m.requestCancel()
        m.apply(.appended(rows: 5), at: 2)
        m.apply(.noOverlap, at: 3)
        m.apply(.limitReached, at: 4)
        XCTAssertEqual(m.phase, .confirmingCancel)
        XCTAssertEqual(m.acceptedFrames, 2)
        m.dismissCancel()
        XCTAssertEqual(m.phase, .capturing)
    }

    func testOutcomesIgnoredWhileStitching() {
        var m = modelWithFrames()
        m.beginStitching()
        m.apply(.appended(rows: 5), at: 2)
        m.apply(.noOverlap, at: 3)
        m.apply(.limitReached, at: 4)
        m.tick(at: 100)
        XCTAssertEqual(m.phase, .stitching)
        XCTAssertEqual(m.acceptedFrames, 2)
    }

    // MARK: - Ayuda y modificadores

    func testHelpHintShowsForFirstThreeUses() throws {
        let name = "ScrollCaptureModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for _ in 0..<ScrollCaptureHelpHint.maxUses {
            XCTAssertTrue(ScrollCaptureHelpHint.shouldShow(defaults: defaults))
            ScrollCaptureHelpHint.recordUse(defaults: defaults)
        }
        XCTAssertFalse(ScrollCaptureHelpHint.shouldShow(defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: ScrollCaptureHelpHint.defaultsKey), 3)
    }

    func testWantsScrollCapture() {
        XCTAssertTrue(ScrollCaptureModel.wantsScrollCapture([.shift]))
        XCTAssertTrue(ScrollCaptureModel.wantsScrollCapture([.shift, .capsLock]))
        XCTAssertFalse(ScrollCaptureModel.wantsScrollCapture([]))
        XCTAssertFalse(ScrollCaptureModel.wantsScrollCapture([.capsLock]))
        XCTAssertFalse(ScrollCaptureModel.wantsScrollCapture([.command, .option]))
    }
}
