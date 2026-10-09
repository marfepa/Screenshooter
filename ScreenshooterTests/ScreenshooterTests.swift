import XCTest
import AppKit
@testable import Screenshooter

final class ScreenshooterTests: XCTestCase {
    
    func testCoordinateConversionFromAppKitToDisplay() {
        // Pantalla simulada de 1440x900
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        
        // Selección en la parte superior: x: 100, y: 800, w: 200, h: 50
        let appKitRect = CGRect(x: 100, y: 800, width: 200, height: 50)
        
        let localX = appKitRect.origin.x - screenFrame.origin.x
        let localY = screenFrame.height - (appKitRect.origin.y - screenFrame.origin.y + appKitRect.height)
        
        XCTAssertEqual(localX, 100)
        XCTAssertEqual(localY, 50, "En coordenadas de display, el origen (0,0) está arriba a la izquierda")
    }
    
    func testClipboardServiceWritesImage() {
        // Crear una CGImage de prueba de 10x10 px
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 40,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("No se pudo crear contexto gráfico de prueba")
            return
        }
        
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        guard let testImage = context.makeImage() else {
            XCTFail("No se pudo generar CGImage")
            return
        }
        
        // Usar un pasteboard aislado para no contaminar el portapapeles del sistema del usuario
        let testPasteboard = NSPasteboard.withUniqueName()
        let copied = ClipboardService.shared.copy(
            cgImage: testImage,
            logicalSize: CGSize(width: 10, height: 10),
            playSound: false,
            pasteboard: testPasteboard
        )
        XCTAssertTrue(copied, "La imagen debe ser transferida al portapapeles con éxito")
        
        let types = testPasteboard.types ?? []
        XCTAssertTrue(types.contains(.tiff) || types.contains(.png), "El portapapeles debe contener tipos de imagen estándar")
    }
    
    @MainActor
    func testSelectionOverlayWindowInitialization() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        
        let window = SelectionOverlayWindow(screen: screen)
        XCTAssertNotNil(window.selectionView, "SelectionView debe inicializarse correctamente en SelectionOverlayWindow")
        XCTAssertTrue(window.canBecomeKey, "La ventana overlay debe poder ser keyWindow para recibir eventos de teclado (ESC)")
        XCTAssertTrue(window.canBecomeMain, "La ventana overlay debe poder ser mainWindow")
        let expectedLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        XCTAssertEqual(window.level, expectedLevel, "La ventana debe situarse por encima de popUpMenu pero por debajo de alertas del sistema")
    }
    
    @MainActor
    func testTendederoItemAndCaching() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 20,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 80,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("No se pudo crear contexto gráfico")
            return
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        guard let cgImg = context.makeImage() else {
            XCTFail("No se pudo crear CGImage")
            return
        }
        
        guard let savedURL = TendederoManager.shared.saveToCache(cgImage: cgImg) else {
            XCTFail("No se pudo guardar la imagen en caché del Tendedero")
            return
        }
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        
        let item = TendederoItem(url: savedURL, cgImage: cgImg)
        XCTAssertEqual(item.pixelSize.width, 20)
        XCTAssertEqual(item.pixelSize.height, 20)
        XCTAssertFalse(item.isFalling)
        XCTAssertFalse(item.isFlying)
        
        // Limpiar archivo de prueba
        try? FileManager.default.removeItem(at: savedURL)
    }
    
    @MainActor
    func testLaunchAtLoginManagerAvailability() {
        // Verificar que el manager se inicialice sin errores de runtime
        let manager = LaunchAtLoginManager.shared
        _ = manager.isEnabled
        XCTAssertNotNil(manager)
    }
    
    // MARK: - Tendedero: Papelera y arrastre
    
    @MainActor
    private func makeTestImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return context.makeImage()
    }
    
    @MainActor
    func testEvictionSendsOldestToTrashInsteadOfDeleting() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        let originalSound = manager.playsTrashSound
        var trashed: [URL] = []
        manager.trasher = { trashed.append($0) }
        manager.playsTrashSound = false
        defer {
            manager.clear()
            manager.trasher = originalTrasher
            manager.playsTrashSound = originalSound
        }
        manager.clear()
        trashed.removeAll()
        
        let image = try XCTUnwrap(makeTestImage())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-evict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        var urls: [URL] = []
        for i in 0...manager.maxItems {
            let url = dir.appendingPathComponent("c\(i).png")
            try Data([0]).write(to: url)
            urls.append(url)
            manager.hang(url: url, cgImage: image)
        }
        
        XCTAssertEqual(manager.items.count, manager.maxItems)
        XCTAssertEqual(trashed, [urls[0]], "La captura más antigua debe ir a la Papelera")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path), "No debe borrarse de forma definitiva (removeItem)")
    }
    
    @MainActor
    func testTrashItemRemovesItFromStrip() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        let originalSound = manager.playsTrashSound
        var trashed: [URL] = []
        manager.trasher = { trashed.append($0) }
        manager.playsTrashSound = false
        defer {
            manager.clear()
            manager.trasher = originalTrasher
            manager.playsTrashSound = originalSound
        }
        manager.clear()
        
        let image = try XCTUnwrap(makeTestImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-trash-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        manager.hang(url: url, cgImage: image)
        let id = try XCTUnwrap(manager.items.first?.id)
        
        manager.trash(itemID: id)
        
        XCTAssertFalse(manager.items.contains { $0.id == id })
        XCTAssertEqual(trashed, [url])
    }
    
    @MainActor
    func testTrashFailureKeepsItem() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        manager.trasher = { _ in throw CocoaError(.fileWriteNoPermission) }
        defer {
            manager.trasher = { _ in }
            manager.clear()
            manager.trasher = originalTrasher
        }
        manager.clear()
        
        let image = try XCTUnwrap(makeTestImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-fail-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        manager.hang(url: url, cgImage: image)
        let id = try XCTUnwrap(manager.items.first?.id)
        
        manager.trash(itemID: id)
        
        XCTAssertTrue(manager.items.contains { $0.id == id }, "Si falla la Papelera el item permanece")
    }
    
    func testInboxIgnoresHiddenAndNonImageFiles() {
        XCTAssertFalse(InboxManager.shouldConsider(filename: ".Captura de pantalla 2026.png"))
        XCTAssertTrue(InboxManager.shouldConsider(filename: "Captura de pantalla 2026.png"))
        XCTAssertFalse(InboxManager.shouldConsider(filename: "notas.txt"))
        XCTAssertTrue(InboxManager.shouldConsider(filename: "foto.HEIC"))
    }
    
    func testInboxDirectoryIsSubfolderOfScreenshotsDirectory() {
        let inbox = TendederoManager.inboxDirectory.standardizedFileURL
        let cache = TendederoManager.screenshotsDirectory.standardizedFileURL
        XCTAssertNotEqual(inbox, cache)
        XCTAssertEqual(inbox.deletingLastPathComponent(), cache)
    }
    
    @MainActor
    func testHangSameURLTwiceKeepsSingleItem() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        let originalSound = manager.playsTrashSound
        manager.trasher = { _ in }
        manager.playsTrashSound = false
        defer {
            manager.clear()
            manager.trasher = originalTrasher
            manager.playsTrashSound = originalSound
        }
        manager.clear()
        
        let image = try XCTUnwrap(makeTestImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-dup-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        
        manager.hang(url: url, cgImage: image)
        manager.hang(url: url, cgImage: image)
        
        XCTAssertEqual(manager.items.count, 1)
    }
    
    func testDragEndDecision() {
        typealias M = TendederoManager
        XCTAssertEqual(M.dragEndDecision(operation: .delete, fileExists: true), .trash)
        XCTAssertEqual(M.dragEndDecision(operation: .move, fileExists: false), .remove)
        XCTAssertEqual(M.dragEndDecision(operation: .move, fileExists: true), .keep)
        XCTAssertEqual(M.dragEndDecision(operation: .copy, fileExists: false), .keep)
        XCTAssertEqual(M.dragEndDecision(operation: [], fileExists: true), .keep)
    }
    
    // MARK: - RevealState
    
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    
    private func revealed() -> RevealState {
        var st = RevealState()
        st.didReveal()
        return st
    }
    
    func testRevealRequiresDwell() {
        var st = RevealState()
        XCTAssertEqual(st.tick(now: t0, inMenuBar: true, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.2), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.25), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .reveal)
    }
    
    func testLeavingMenuBarResetsDwell() {
        var st = RevealState()
        _ = st.tick(now: t0, inMenuBar: true, inZone: false, fullScreen: false, busy: false)
        _ = st.tick(now: t0.addingTimeInterval(0.2), inMenuBar: false, inZone: false, fullScreen: false, busy: false)
        XCTAssertNil(st.hotZoneSince)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.3), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.5), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.55), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .reveal)
    }
    
    func testMenuBarClickSuppressesUntilPointerLeavesBand() {
        var st = RevealState()
        XCTAssertEqual(st.menuBarClicked(), .none)
        XCTAssertEqual(st.tick(now: t0, inMenuBar: true, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(1), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .none)
        _ = st.tick(now: t0.addingTimeInterval(1.1), inMenuBar: false, inZone: false, fullScreen: false, busy: false)
        XCTAssertFalse(st.menuBarSuppressed)
        _ = st.tick(now: t0.addingTimeInterval(2), inMenuBar: true, inZone: false, fullScreen: false, busy: false)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(2.3), inMenuBar: true, inZone: false, fullScreen: false, busy: false), .reveal)
    }
    
    func testMenuBarClickRetractsWhenRevealed() {
        var st = revealed()
        st.pin()
        XCTAssertEqual(st.menuBarClicked(), .retract)
        XCTAssertFalse(st.pinned)
    }
    
    func testFullScreenBlocksReveal() {
        var st = RevealState()
        _ = st.tick(now: t0, inMenuBar: true, inZone: false, fullScreen: true, busy: false)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(5), inMenuBar: true, inZone: false, fullScreen: true, busy: false), .none)
    }
    
    func testRetractsAfterHalfSecondAway() {
        var st = revealed()
        XCTAssertEqual(st.tick(now: t0, inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.4), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.5), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .retract)
        st.didRetract()
        XCTAssertFalse(st.isRevealed)
    }
    
    func testReturningToZoneResetsAwayTimer() {
        var st = revealed()
        _ = st.tick(now: t0, inMenuBar: false, inZone: false, fullScreen: false, busy: false)
        _ = st.tick(now: t0.addingTimeInterval(0.4), inMenuBar: false, inZone: true, fullScreen: false, busy: false)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(0.6), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
    }
    
    func testPinnedDoesNotRetractUntilPointerEntersZone() {
        var st = revealed()
        st.pin()
        XCTAssertEqual(st.tick(now: t0, inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(10), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        _ = st.tick(now: t0.addingTimeInterval(11), inMenuBar: false, inZone: true, fullScreen: false, busy: false)
        XCTAssertFalse(st.pinned)
        _ = st.tick(now: t0.addingTimeInterval(12), inMenuBar: false, inZone: false, fullScreen: false, busy: false)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(12.5), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .retract)
    }
    
    func testPeekPreventsRetractUntilExpired() {
        var st = revealed()
        st.peek(until: t0.addingTimeInterval(4))
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(1), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(3.9), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(4.1), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(4.6), inMenuBar: false, inZone: false, fullScreen: false, busy: false), .retract)
    }
    
    func testBusyPreventsRetract() {
        var st = revealed()
        XCTAssertEqual(st.tick(now: t0, inMenuBar: false, inZone: false, fullScreen: false, busy: true), .none)
        XCTAssertEqual(st.tick(now: t0.addingTimeInterval(5), inMenuBar: false, inZone: false, fullScreen: false, busy: true), .none)
    }
    
    func testDidRetractClearsPinAndPeek() {
        var st = revealed()
        st.pin()
        st.peek(until: t0.addingTimeInterval(100))
        st.didRetract()
        XCTAssertFalse(st.pinned)
        XCTAssertEqual(st.peekUntil, .distantPast)
    }

    // MARK: - StripMotion (lógica pura de la tira)

    private func assertTransform(_ a: CATransform3D, equals b: CATransform3D, accuracy: CGFloat = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        let x = [a.m11, a.m12, a.m13, a.m14, a.m21, a.m22, a.m23, a.m24, a.m31, a.m32, a.m33, a.m34, a.m41, a.m42, a.m43, a.m44]
        let y = [b.m11, b.m12, b.m13, b.m14, b.m21, b.m22, b.m23, b.m24, b.m31, b.m32, b.m33, b.m34, b.m41, b.m42, b.m43, b.m44]
        for (i, (u, v)) in zip(x, y).enumerated() {
            XCTAssertEqual(u, v, accuracy: accuracy, "elemento \(i)", file: file, line: line)
        }
    }

    func testCardTransformWithUnitScaleIsPureRotation() {
        assertTransform(StripMotion.cardTransform(tilt: 2.5, scale: 1),
                        equals: CATransform3DMakeRotation(2.5 * .pi / 180, 0, 0, 1))
    }

    func testCardTransformWithZeroTiltIsPureScale() {
        assertTransform(StripMotion.cardTransform(tilt: 0, scale: 1.035),
                        equals: CATransform3DMakeScale(1.035, 1.035, 1))
    }

    func testCardTransformComposesScaleOverTiltWithoutJump() {
        // Una sola matriz: el giro se conserva al escalar (sin saltos entre reposo y hover).
        let rest = StripMotion.cardTransform(tilt: -2, scale: 1)
        let hover = StripMotion.cardTransform(tilt: -2, scale: 1.035)
        XCTAssertEqual(hover.m11 / rest.m11, 1.035, accuracy: 1e-9)
        XCTAssertEqual(hover.m12 / rest.m12, 1.035, accuracy: 1e-9)
    }

    func testCardTransformKeepsTopCenterFixed() {
        let height: CGFloat = 104
        let t = StripMotion.cardTransform(tilt: 2.5, scale: 1.035, anchoredAtTopOfHeight: height)
        // Punto superior central respecto al centro de la capa: (0, h/2).
        let p = CGPoint(x: 0, y: height / 2)
        let x = t.m11 * p.x + t.m21 * p.y + t.m41
        let y = t.m12 * p.x + t.m22 * p.y + t.m42
        XCTAssertEqual(x, 0, accuracy: 1e-9)
        XCTAssertEqual(y, height / 2, accuracy: 1e-9)
    }

    func testRopeSagIsCappedAndProportional() {
        XCTAssertEqual(StripMotion.ropeSag(width: 600), 5, accuracy: 1e-9)
        XCTAssertEqual(StripMotion.ropeSag(width: 3000), 10, accuracy: 1e-9)
    }

    func testRopeYIsZeroAtEndsAndMaxInCenter() {
        let w: CGFloat = 1440
        XCTAssertEqual(StripMotion.ropeY(x: 0, width: w), 0, accuracy: 1e-9)
        XCTAssertEqual(StripMotion.ropeY(x: w, width: w), 0, accuracy: 1e-9)
        XCTAssertEqual(StripMotion.ropeY(x: w / 2, width: w), StripMotion.ropeSag(width: w), accuracy: 1e-9)
    }

    func testCardFramesAreCenteredWithGap() {
        let w: CGFloat = 1440
        for count in 1...8 {
            let frames = StripMotion.cardFrames(count: count, width: w)
            XCTAssertEqual(frames.count, count)
            let midpoint = (frames.first!.minX + frames.last!.maxX) / 2
            XCTAssertEqual(midpoint, w / 2, accuracy: 1e-9, "\(count) tarjetas")
            for pair in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(pair.1.minX - pair.0.maxX, StripMotion.gap, accuracy: 1e-9)
            }
        }
        XCTAssertTrue(StripMotion.cardFrames(count: 0, width: w).isEmpty)
    }

    func testCardFramesRespectMinimumLeadingOnNarrowStrip() {
        let frames = StripMotion.cardFrames(count: 8, width: 600)
        XCTAssertEqual(frames.first!.minX, StripMotion.minLeading, accuracy: 1e-9)
    }

    func testCentralCardHangsLowerThanEdges() {
        let frames = StripMotion.cardFrames(count: 5, width: 1440)
        XCTAssertGreaterThan(frames[2].minY, frames[0].minY)
        XCTAssertGreaterThan(frames[2].minY, frames[4].minY)
        XCTAssertEqual(frames[0].minY, frames[4].minY, accuracy: 1e-9)
    }

    func testMotionStyleWithReduceMotionHasNoSpringsOrRotations() {
        let reduced = MotionStyle.current(reduceMotion: true)
        XCTAssertTrue(reduced.reduceMotion)
        XCTAssertFalse(reduced.usesSprings)
        XCTAssertEqual(reduced.fadeDuration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(reduced.revealDuration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(reduced.fallDuration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(reduced.hoverScale, 1)
        XCTAssertEqual(reduced.pressScale, 1)
        XCTAssertEqual(reduced.arrivalSwingDegrees, 0)
        XCTAssertEqual(reduced.swayDegrees, 0)
        XCTAssertEqual(reduced.fallMaxRotation, 0)
    }

    func testMotionStyleDefaultUsesSpringsAndSpecValues() {
        let full = MotionStyle.current(reduceMotion: false)
        XCTAssertTrue(full.usesSprings)
        XCTAssertEqual(full.revealSpring, SpringSpec(response: 0.42, dampingRatio: 0.82))
        XCTAssertEqual(full.hoverScale, 1.035, accuracy: 1e-9)
        XCTAssertEqual(full.pressScale, 0.95, accuracy: 1e-9)
        XCTAssertEqual(full.retractDuration, 0.22, accuracy: 1e-9)
        XCTAssertEqual(full.arrivalSwingDegrees, 10)
        XCTAssertLessThan(full.fallMaxRotation, 22.0001)
    }

    func testSpringSpecPhysicalParameters() {
        let s = SpringSpec(response: 0.5, dampingRatio: 1)
        XCTAssertEqual(s.stiffness, pow(2 * Double.pi / 0.5, 2), accuracy: 1e-9)
        XCTAssertEqual(s.damping, 2 * s.stiffness.squareRoot(), accuracy: 1e-9)
    }

    @MainActor
    func testAccessibilityLabelForPresentAndMissingCapture() throws {
        let cg = try XCTUnwrap(makeTestImage())
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 14, minute: 32)))
        let item = TendederoItem(url: URL(fileURLWithPath: "/tmp/x.png"), cgImage: cg,
                                 pixelSize: CGSize(width: 1440, height: 900), createdAt: date)
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: false), "Captura, 14:32, 1440 por 900")
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: true), "Captura no encontrada, 14:32")
        XCTAssertEqual(StripMotion.metaText(for: item), "14:32 · 1440×900")
        XCTAssertEqual(StripMotion.positionText(index: 1, count: 8), "2 de 8")
    }

    func testAspectFitCentersImageInsideRect() {
        let r = StripMotion.aspectFit(imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 140, height: 94))
        XCTAssertEqual(r.width, 140, accuracy: 1e-9)
        XCTAssertEqual(r.height, 70, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 47, accuracy: 1e-9)
    }
}
