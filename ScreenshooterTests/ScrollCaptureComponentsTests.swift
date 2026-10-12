import XCTest
import AppKit
@testable import Screenshooter

/// Lo comprobable sin pantalla de la captura larga: recorte, colocación de la vista previa, píldora y teclas del marco.
@MainActor
final class ScrollCaptureComponentsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LocalizedTestSupport.use("en")
    }

    override func tearDown() {
        LocalizedTestSupport.reset()
        super.tearDown()
    }

    // MARK: - Recorte (ScreenCaptureEngine.cropRect)

    func testCropRectOnPrimaryRetinaScreen() {
        let r = ScreenCaptureEngine.cropRect(
            for: CGRect(x: 100, y: 200, width: 300, height: 150),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 2, imageSize: CGSize(width: 2880, height: 1800)
        )
        // localY = 900 - (200 + 150) = 550 pt
        XCTAssertEqual(r, CGRect(x: 200, y: 1100, width: 600, height: 300))
    }

    func testCropRectOnSecondaryScreenWithShiftedOriginAndScale2() {
        let r = ScreenCaptureEngine.cropRect(
            for: CGRect(x: 1540, y: -100, width: 200, height: 100),
            screenFrame: CGRect(x: 1440, y: -300, width: 1280, height: 720),
            scale: 2, imageSize: CGSize(width: 2560, height: 1440)
        )
        // localX = 100 pt; localY = 720 - (-100 + 300 + 100) = 420 pt
        XCTAssertEqual(r, CGRect(x: 200, y: 840, width: 400, height: 200))
    }

    func testCropRectClampsToImageBounds() {
        let r = ScreenCaptureEngine.cropRect(
            for: CGRect(x: 1400, y: -50, width: 200, height: 200),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 1, imageSize: CGSize(width: 1440, height: 900)
        )
        XCTAssertEqual(r.minX, 1400)
        XCTAssertEqual(r.width, 40)
        XCTAssertEqual(r.maxY, 900)
        XCTAssertGreaterThanOrEqual(r.minY, 0)
    }

    func testCropRectNeverEmpty() {
        let r = ScreenCaptureEngine.cropRect(
            for: CGRect(x: 5000, y: 5000, width: 10, height: 10),
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1, imageSize: CGSize(width: 100, height: 100)
        )
        XCTAssertGreaterThanOrEqual(r.width, 1)
        XCTAssertGreaterThanOrEqual(r.height, 1)
    }

    // MARK: - Colocación de la vista previa

    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)

    func testPreviewGoesRightWithGap() {
        let rect = CGRect(x: 100, y: 100, width: 600, height: 400)
        let f = ScrollCapturePreviewWindow.previewFrame(for: rect, in: visible)
        XCTAssertEqual(f, CGRect(x: 714, y: 100, width: 122, height: 400))
    }

    func testPreviewGoesLeftWhenRightDoesNotFit() {
        let rect = CGRect(x: 800, y: 100, width: 600, height: 400)
        let f = ScrollCapturePreviewWindow.previewFrame(for: rect, in: visible)
        XCTAssertEqual(f, CGRect(x: 800 - 14 - 122, y: 100, width: 122, height: 400))
    }

    func testPreviewIsNilWhenItFitsNowhere() {
        let rect = CGRect(x: 20, y: 100, width: 1400, height: 400)
        XCTAssertNil(ScrollCapturePreviewWindow.previewFrame(for: rect, in: visible))
    }

    func testPreviewHeightIsClampedToVisibleFrame() {
        let rect = CGRect(x: 100, y: 0, width: 600, height: 900)
        let f = ScrollCapturePreviewWindow.previewFrame(for: rect, in: visible)
        XCTAssertEqual(f?.height, 860)
        XCTAssertEqual(f?.minY, 0)
    }

    func testPreviewImageDrawRectAlignsTopOrShowsBottom() {
        let bounds = CGRect(x: 0, y: 0, width: 110, height: 300)
        // Corta: 110x100 escalada a 110 de ancho = 100 de alto, pegada arriba.
        XCTAssertEqual(ScrollCapturePreviewImageView.drawRect(imageSize: CGSize(width: 110, height: 100), in: bounds),
                       CGRect(x: 0, y: 200, width: 110, height: 100))
        // Alta: 220x1000 -> 500 de alto > 300: se ancla abajo (lo último cosido).
        let tall = ScrollCapturePreviewImageView.drawRect(imageSize: CGSize(width: 220, height: 1000), in: bounds)
        XCTAssertEqual(tall, CGRect(x: 0, y: 0, width: 110, height: 500))
    }

    // MARK: - Píldora

    func testPillTextsPerDisplay() {
        let pill = ScrollCapturePillWindow()
        pill.update(display: .capturing, pixelHeight: 1300)
        XCTAssertEqual(pill.titleText, "Long capture")
        XCTAssertEqual(pill.hintText, "Scroll down")
        XCTAssertEqual(pill.counterText, "1300 px")
        XCTAssertEqual(pill.secondaryButtonTitle, "Cancel")
        XCTAssertEqual(pill.primaryButtonTitle, "Done")
        XCTAssertTrue(pill.buttonsAreEnabled)

        pill.update(display: .warnTooFast, pixelHeight: 1300)
        XCTAssertEqual(pill.hintText, "Slow down: go back up a little")
        pill.update(display: .atEnd, pixelHeight: 1300)
        XCTAssertEqual(pill.hintText, "You've reached the end")
        pill.update(display: .limitReached, pixelHeight: 30_000)
        XCTAssertEqual(pill.hintText, "You've reached the maximum height")
        XCTAssertEqual(pill.counterText, "30000 px")
        pill.update(display: .endingSoon(seconds: 10), pixelHeight: 1300)
        XCTAssertEqual(pill.titleText, "Ending in 10 s")
    }

    func testPillConfirmingCancelSwapsButtonsAndHidesCounter() {
        let pill = ScrollCapturePillWindow()
        pill.update(display: .confirmingCancel, pixelHeight: 1300)
        XCTAssertEqual(pill.titleText, "Discard the long capture?")
        XCTAssertEqual(pill.hintText, "What you've captured will be lost.")
        XCTAssertNil(pill.counterText)
        XCTAssertEqual(pill.secondaryButtonTitle, "Discard")
        XCTAssertEqual(pill.primaryButtonTitle, "Keep going")
        XCTAssertTrue(pill.secondaryIsDestructive)

        var discarded = 0, kept = 0, cancelled = 0, finished = 0
        pill.onDiscard = { discarded += 1 }
        pill.onKeepGoing = { kept += 1 }
        pill.onCancel = { cancelled += 1 }
        pill.onFinish = { finished += 1 }
        pill.performSecondaryForTesting()
        pill.performPrimaryForTesting()
        XCTAssertEqual([discarded, kept, cancelled, finished], [1, 1, 0, 0])

        pill.update(display: .capturing, pixelHeight: 10)
        XCTAssertFalse(pill.secondaryIsDestructive)
        pill.performSecondaryForTesting()
        pill.performPrimaryForTesting()
        XCTAssertEqual([discarded, kept, cancelled, finished], [1, 1, 1, 1])
    }

    func testPillStitchingShowsSpinnerAndDisablesButtons() {
        let pill = ScrollCapturePillWindow()
        pill.update(display: .stitching, pixelHeight: 1300)
        XCTAssertEqual(pill.titleText, "Stitching…")
        XCTAssertTrue(pill.isShowingSpinner)
        XCTAssertFalse(pill.buttonsAreEnabled)
        pill.update(display: .capturing, pixelHeight: 1300)
        XCTAssertFalse(pill.isShowingSpinner)
        XCTAssertTrue(pill.buttonsAreEnabled)
    }

    func testPillSpanishTexts() {
        LocalizedTestSupport.use("es")
        let pill = ScrollCapturePillWindow()
        pill.update(display: .capturing, pixelHeight: 1300)
        XCTAssertEqual(pill.titleText, "Captura larga")
        XCTAssertEqual(pill.hintText, "Desplázate hacia abajo")
        XCTAssertEqual(pill.primaryButtonTitle, "Listo")
        pill.update(display: .confirmingCancel, pixelHeight: 0)
        XCTAssertEqual(pill.titleText, "¿Descartar la captura larga?")
        XCTAssertEqual(pill.primaryButtonTitle, "Seguir")
        XCTAssertEqual(pill.secondaryButtonTitle, "Descartar")
    }

    // MARK: - Marco

    func testFrameWindowKeysAndMouseTransparency() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sin pantalla") }
        let frame = ScrollCaptureFrameWindow(rect: CGRect(x: 100, y: 100, width: 300, height: 200), screen: screen)
        XCTAssertTrue(frame.ignoresMouseEvents)
        XCTAssertTrue(frame.canBecomeKey)
        var esc = 0, ret = 0
        frame.onEscape = { esc += 1 }
        frame.onReturn = { ret += 1 }
        frame.handleKey(53)
        frame.handleKey(36)
        frame.handleKey(76)
        frame.handleKey(0)
        XCTAssertEqual(esc, 1)
        XCTAssertEqual(ret, 2)
        XCTAssertEqual(frame.holeRectForTesting.size, CGSize(width: 300, height: 200))
        frame.setWarning(true)
        XCTAssertTrue(frame.isWarningForTesting)
    }
}

// MARK: - Cableado: selección con ⇧, menú

@MainActor
final class ScrollCaptureWiringTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LocalizedTestSupport.use("en")
    }

    override func tearDown() {
        LocalizedTestSupport.reset()
        super.tearDown()
    }

    func testDecisionDependsOnShiftOrForcing() {
        XCTAssertFalse(SelectionView.isScrollCapture(flags: [], forces: false))
        XCTAssertFalse(SelectionView.isScrollCapture(flags: [.command, .option, .capsLock], forces: false))
        XCTAssertTrue(SelectionView.isScrollCapture(flags: [.shift], forces: false))
        XCTAssertTrue(SelectionView.isScrollCapture(flags: [], forces: true))
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// Arrastra 100×80 y suelta; devuelve (captura normal, captura larga) recibidas.
    private func drag(flags: NSEvent.ModifierFlags, forces: Bool, size: CGFloat = 100) throws -> (normal: Int, long: Int) {
        let screen = try XCTUnwrap(NSScreen.screens.first, "sin pantalla")
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), screen: screen)
        view.helpDefaults = UserDefaults(suiteName: "SelectionViewTests-\(UUID().uuidString)")!
        view.forcesScrollCapture = forces
        var normal = 0, long = 0
        view.onSelectionCompleted = { _, _ in normal += 1 }
        view.onScrollCaptureSelected = { _, _ in long += 1 }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 10), flags: []))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 10 + size, y: 10 + size), flags: flags))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 10 + size, y: 10 + size), flags: flags))
        return (normal, long)
    }

    func testReleaseWithoutShiftKeepsNormalCapture() throws {
        let r = try drag(flags: [], forces: false)
        XCTAssertEqual(r.normal, 1)
        XCTAssertEqual(r.long, 0)
    }

    func testReleaseWithShiftStartsLongCapture() throws {
        let r = try drag(flags: [.shift], forces: false)
        XCTAssertEqual(r.normal, 0)
        XCTAssertEqual(r.long, 1)
    }

    func testForcedViewStartsLongCaptureWithoutShift() throws {
        let r = try drag(flags: [], forces: true)
        XCTAssertEqual(r.normal, 0)
        XCTAssertEqual(r.long, 1)
    }

    func testTinySelectionIsDiscardedInBothModes() throws {
        for shift in [false, true] {
            let r = try drag(flags: shift ? [.shift] : [], forces: false, size: 2)
            XCTAssertEqual(r.normal + r.long, 0)
        }
    }

    func testMenuHasLongCaptureRightAfterCaptureItem() {
        let controller = StatusBarController(createsStatusItem: false)
        let titles = controller.menuForTesting.items.map(\.title)
        let capture = titles.firstIndex(of: "Capture Selected Area...")
        XCTAssertEqual(capture, 0)
        XCTAssertEqual(titles[1], "Long Capture…")
        XCTAssertEqual(controller.menuForTesting.items[1].keyEquivalent, "")
    }
}
