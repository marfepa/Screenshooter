import XCTest
import AppKit
import UniformTypeIdentifiers
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
        let originalDefaults = manager.defaults
        let originalCapacity = manager.capacity
        var trashed: [URL] = []
        manager.trasher = { trashed.append($0) }
        manager.playsTrashSound = false
        let suite = "tendedero-evict-\(UUID().uuidString)"
        manager.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            manager.clear()
            manager.trasher = originalTrasher
            manager.playsTrashSound = originalSound
            manager.setCapacity(originalCapacity) // aún en la suite de pruebas: no toca los ajustes reales
            manager.defaults.removePersistentDomain(forName: suite)
            manager.defaults = originalDefaults
        }
        manager.clear()
        manager.setCapacity(8)
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
    func testLoweringCapacityTrashesOldestAndPersists() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        let originalDefaults = manager.defaults
        let originalCapacity = manager.capacity
        var trashed: [URL] = []
        manager.trasher = { trashed.append($0) }
        let suite = "tendedero-lower-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        manager.defaults = defaults
        defer {
            manager.clear()
            manager.trasher = originalTrasher
            manager.setCapacity(originalCapacity)
            defaults.removePersistentDomain(forName: suite)
            manager.defaults = originalDefaults
        }
        manager.clear()
        manager.setCapacity(16)
        trashed.removeAll()

        let image = try XCTUnwrap(makeTestImage())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-lower-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for i in 0..<12 {
            let url = dir.appendingPathComponent("c\(i).png")
            try Data([0]).write(to: url)
            urls.append(url)
            manager.hang(url: url, cgImage: image)
        }
        XCTAssertEqual(manager.items.count, 12)
        XCTAssertTrue(trashed.isEmpty)

        manager.setCapacity(8)

        XCTAssertEqual(manager.items.count, 8)
        XCTAssertEqual(trashed, Array(urls[0..<4]), "Las 4 más antiguas van a la Papelera, de más antigua a menos")
        XCTAssertEqual(manager.items.map { $0.url }, Array(urls[4...].reversed()), "Quedan las más recientes, la última primero")
        XCTAssertEqual(defaults.object(forKey: "stripCapacity") as? Int, 8)
    }

    @MainActor
    func testUnlimitedCapacityNeverEvicts() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        let originalDefaults = manager.defaults
        let originalCapacity = manager.capacity
        var trashed: [URL] = []
        manager.trasher = { trashed.append($0) }
        let suite = "tendedero-unlimited-\(UUID().uuidString)"
        manager.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            manager.clear()
            manager.trasher = originalTrasher
            manager.setCapacity(originalCapacity)
            manager.defaults.removePersistentDomain(forName: suite)
            manager.defaults = originalDefaults
        }
        manager.clear()
        manager.setCapacity(0)
        trashed.removeAll()
        let image = try XCTUnwrap(makeTestImage())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-unl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<40 {
            let url = dir.appendingPathComponent("c\(i).png")
            try Data([0]).write(to: url)
            manager.hang(url: url, cgImage: image)
        }
        XCTAssertEqual(manager.items.count, 40)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(manager.capacity, 0)
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
    func testRemoveFromStripDoesNotTouchTrash() throws {
        let manager = TendederoManager.shared
        let originalTrasher = manager.trasher
        var trashed: [URL] = []
        manager.trasher = { trashed.append($0) }
        defer {
            manager.clear()
            manager.trasher = originalTrasher
        }
        manager.clear()
        trashed.removeAll()

        let image = try XCTUnwrap(makeTestImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-missing-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        manager.hang(url: url, cgImage: image)
        let id = try XCTUnwrap(manager.items.first?.id)
        try FileManager.default.removeItem(at: url)

        manager.removeFromStrip(itemID: id)

        XCTAssertFalse(manager.items.contains { $0.id == id })
        XCTAssertTrue(trashed.isEmpty, "Un archivo no encontrado se quita de la tira sin pasar por la Papelera")
    }

    @MainActor
    func testCardDetectsMissingFile() throws {
        let image = try XCTUnwrap(makeTestImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tendedero-card-\(UUID().uuidString).png")
        try Data([0]).write(to: url)
        let card = TendederoCardView(item: TendederoItem(url: url, cgImage: image))
        XCTAssertFalse(card.isMissing)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(card.refreshMissingState())
        XCTAssertTrue(card.isMissing)
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
        let es = Locale(identifier: "es_ES")
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: false, locale: es), "Captura, 14:32, 1440 por 900")
        XCTAssertEqual(StripMotion.accessibilityLabel(for: item, missing: true, locale: es), "Captura no encontrada, 14:32")
        XCTAssertEqual(StripMotion.metaText(for: item, locale: es), "14:32 · 1440×900")
        XCTAssertEqual(StripMotion.positionText(index: 1, count: 8), "2 de 8")
    }

    func testTimeTextFollowsLocaleClockStyle() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 14, minute: 32)))
        XCTAssertEqual(StripMotion.timeText(date, locale: Locale(identifier: "es_ES")), "14:32")
        XCTAssertTrue(StripMotion.timeText(date, locale: Locale(identifier: "en_US")).contains("2:32"))
    }

    @MainActor
    func testCardHoverAndTiltKeepTopCenterFixedInParent() throws {
        let image = try XCTUnwrap(makeTestImage())
        let url = URL(fileURLWithPath: "/tmp/anchor-test.png")
        let card = TendederoCardView(item: TendederoItem(url: url, cgImage: image, tilt: 2.5))
        card.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(card.cardBodyLayerForTesting)
        // Punto de la capa en coordenadas del padre con el anchorPoint REAL: pos + T·(p − anchor·size).
        func inParent(_ p: CGPoint) -> CGPoint {
            let a = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
            let t = layer.transform
            let v = CGPoint(x: p.x - a.x, y: p.y - a.y)
            return CGPoint(x: layer.position.x + t.m11 * v.x + t.m21 * v.y + t.m41,
                           y: layer.position.y + t.m12 * v.x + t.m22 * v.y + t.m42)
        }
        XCTAssertEqual(layer.bounds.height, StripMotion.cardSize.height, accuracy: 0.001)
        let top = CGPoint(x: layer.bounds.midX, y: layer.bounds.maxY)

        layer.transform = CATransform3DIdentity
        let base = inParent(top)

        card.setHovered(true)   // fuera de ventana: se aplica sin animar
        let hovered = inParent(top)
        XCTAssertEqual(hovered.x, base.x, accuracy: 1e-6)
        XCTAssertEqual(hovered.y, base.y, accuracy: 1e-6)

        card.setHovered(false)
        let rest = inParent(top)
        XCTAssertEqual(rest.x, base.x, accuracy: 1e-6)
        XCTAssertEqual(rest.y, base.y, accuracy: 1e-6)
        XCTAssertFalse(CATransform3DIsIdentity(layer.transform), "La inclinación se mantiene en reposo")
    }

    func testAspectFitCentersImageInsideRect() {
        let r = StripMotion.aspectFit(imageSize: CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 140, height: 94))
        XCTAssertEqual(r.width, 140, accuracy: 1e-9)
        XCTAssertEqual(r.height, 70, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 47, accuracy: 1e-9)
    }

    // MARK: - Marcación

    private func makePNG(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, at url: URL) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testReloadFromDiskPicksUpNewContentAndSize() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.png")
        try makePNG(width: 4, height: 4, r: 255, g: 0, b: 0, at: url)
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        var item = TendederoItem(url: url, cgImage: CGImageSourceCreateImageAtIndex(src, 0, nil)!)
        XCTAssertEqual(item.pixelSize, CGSize(width: 4, height: 4))

        try makePNG(width: 6, height: 3, r: 0, g: 0, b: 255, at: url)
        XCTAssertTrue(item.reloadFromDisk())

        XCTAssertEqual(item.pixelSize, CGSize(width: 6, height: 3))
        XCTAssertEqual(item.logicalSize, CGSize(width: 3, height: 1.5))
        XCTAssertEqual(item.image.size, item.logicalSize)
        let rep = NSBitmapImageRep(cgImage: item.cgImage)
        let c = rep.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(c.blueComponent, 1, accuracy: 0.02)
        XCTAssertEqual(c.redComponent, 0, accuracy: 0.02)
    }

    func testResolveEditedCases() {
        let original = URL(fileURLWithPath: "/tmp/orig.png")
        let other = URL(fileURLWithPath: "/tmp/other/edited.png")
        if case .sameFile = MarkupService.resolveEdited(items: [original as NSURL], original: original) {} else { XCTFail("sameFile") }
        if case .sameFile = MarkupService.resolveEdited(items: [URL(fileURLWithPath: "/tmp/x/../orig.png")], original: original) {} else { XCTFail("sameFile estandarizada") }
        if case .replace(let u) = MarkupService.resolveEdited(items: [other], original: original) { XCTAssertEqual(u, other) } else { XCTFail("replace") }
        if case .image = MarkupService.resolveEdited(items: [NSImage(size: NSSize(width: 1, height: 1))], original: original) {} else { XCTFail("image") }
        if case .none = MarkupService.resolveEdited(items: [], original: original) {} else { XCTFail("none") }
        if case .none = MarkupService.resolveEdited(items: ["texto"], original: original) {} else { XCTFail("none texto") }
        if case .provider = MarkupService.resolveEdited(items: [NSItemProvider()], original: original) {} else { XCTFail("provider") }
    }

    /// Marcación (macOS 14+) devuelve un NSItemProvider: su PNG debe acabar sobre el original.
    func testWriteProviderWritesEditedPNGOverOriginal() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("orig.png")
        try makePNG(width: 4, height: 4, r: 255, g: 0, b: 0, at: original)
        let editedURL = dir.appendingPathComponent("edited.png")
        try makePNG(width: 6, height: 3, r: 0, g: 0, b: 255, at: editedURL)
        let edited = try Data(contentsOf: editedURL)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(edited, nil); return nil
        }
        let written = expectation(description: "escrito")
        MarkupService.writeProvider(provider, to: original) { ok in
            XCTAssertTrue(ok); written.fulfill()
        }
        wait(for: [written], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: original), edited)
    }

    func testReplaceAtomicallyKeepsOriginalPathWithNewContent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("orig.png")
        let edited = dir.appendingPathComponent("edited.png")
        try Data("old".utf8).write(to: original)
        try Data("new-content".utf8).write(to: edited)

        XCTAssertTrue(MarkupService.replaceAtomically(original: original, with: edited))

        XCTAssertEqual(try Data(contentsOf: original), Data("new-content".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited.path), "La copia de origen no se toca")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["edited.png", "orig.png"], "Sin temporales sobrantes")
    }

    // MARK: - Desplazamiento de la tira (física pura)

    func testStripMetricsMatchCardFramesWhenEverythingFits() {
        let m = StripScroll.Metrics(count: 3, viewWidth: 900)
        XCTAssertFalse(m.isScrollable)
        XCTAssertEqual(m.maxOffset, 0)
        let frames = StripMotion.cardFrames(count: 3, width: 900)
        for i in 0..<3 { XCTAssertEqual(m.slotX(i), frames[i].minX, accuracy: 1e-9) }
    }

    func testStripMetricsBecomeScrollableWithPaddingBothSides() {
        let m = StripScroll.Metrics(count: 10, viewWidth: 800)
        XCTAssertTrue(m.isScrollable)
        XCTAssertEqual(m.start, 24)
        XCTAssertEqual(m.contentWidth, 10 * 150 + 9 * 14 + 48)
        XCTAssertEqual(m.maxOffset, m.contentWidth - 800)
    }

    func testFrictionDependsOnDtNotOnFrameRate() {
        let one = StripScroll.decayedVelocity(1000, dt: 1.0 / 60, friction: 0.95)
        XCTAssertEqual(one, 950, accuracy: 1e-6)
        let twoHalves = StripScroll.decayedVelocity(StripScroll.decayedVelocity(1000, dt: 1.0 / 120, friction: 0.95), dt: 1.0 / 120, friction: 0.95)
        XCTAssertEqual(twoHalves, one, accuracy: 1e-6)
    }

    func testInertiaCoastsAndStopsInsideRange() {
        var s = StripScroller()
        s.maxOffset = 5000
        s.offset = 1000
        s.fling(2000)
        var frames = 0
        while s.tick(1.0 / 60), frames < 2000 { frames += 1 }
        XCTAssertEqual(s.mode, .idle)
        XCTAssertGreaterThan(s.offset, 1000 + 200)
        XCTAssertLessThan(s.offset, 5000)
        XCTAssertEqual(s.velocity, 0)
    }

    func testRubberBandDampensOutwardPushAndDecreasesWithStretch() {
        // Dentro del rango: sin resistencia. Empujando hacia fuera en el borde: ×0,55.
        XCTAssertEqual(StripScroll.rubberDelta(10, offset: 100, maxOffset: 500, reduceMotion: false), 10)
        XCTAssertEqual(StripScroll.rubberDelta(-10, offset: 0, maxOffset: 500, reduceMotion: false), -5.5, accuracy: 1e-9)
        let near = abs(StripScroll.rubberDelta(-10, offset: -20, maxOffset: 500, reduceMotion: false))
        let far = abs(StripScroll.rubberDelta(-10, offset: -120, maxOffset: 500, reduceMotion: false))
        XCTAssertLessThan(far, near)
        // Volviendo hacia dentro desde fuera no se frena.
        XCTAssertEqual(StripScroll.rubberDelta(10, offset: -50, maxOffset: 500, reduceMotion: false), 10)
        // Final por la derecha.
        XCTAssertEqual(StripScroll.rubberDelta(10, offset: 500, maxOffset: 500, reduceMotion: false), 5.5, accuracy: 1e-9)
    }

    func testRubberBandIsHardClampWithReduceMotion() {
        XCTAssertEqual(StripScroll.rubberDelta(-30, offset: 10, maxOffset: 500, reduceMotion: true), -10)
        XCTAssertEqual(StripScroll.rubberDelta(40, offset: 490, maxOffset: 500, reduceMotion: true), 10)
    }

    func testSpringReturnsFromOverscrollToTheEdge() {
        var s = StripScroller()
        s.maxOffset = 1000
        s.offset = -120
        s.boundsChanged()
        XCTAssertEqual(s.mode, .free)
        var t = 0.0
        while s.tick(1.0 / 60), t < 5 { t += 1.0 / 60 }
        XCTAssertEqual(s.offset, 0, accuracy: 1e-9)
        XCTAssertLessThan(t, 3, "El muelle casi crítico no tarda más de unos segundos")
    }

    func testFlingPastTheEdgeBouncesBackWithoutLeavingRange() {
        var s = StripScroller()
        s.maxOffset = 1000
        s.fling(-3000)
        var minOffset: CGFloat = 0
        var frames = 0
        while s.tick(1.0 / 60), frames < 1000 { minOffset = min(minOffset, s.offset); frames += 1 }
        XCTAssertLessThan(minOffset, -1, "Hay rebote visible")
        XCTAssertGreaterThanOrEqual(minOffset, -StripScroll.rubberMax * 1.5)
        XCTAssertEqual(s.offset, 0, accuracy: 1e-9)
    }

    func testReduceMotionHasShortInertiaAndNoBounce() {
        var normal = StripScroller(); normal.maxOffset = 100000; normal.fling(2000)
        var reduced = StripScroller(); reduced.maxOffset = 100000; reduced.reduceMotion = true; reduced.fling(2000)
        while normal.tick(1.0 / 60) {}
        while reduced.tick(1.0 / 60) {}
        XCTAssertLessThan(reduced.offset, normal.offset / 2)

        var edge = StripScroller(); edge.maxOffset = 500; edge.reduceMotion = true; edge.fling(-3000)
        var minOffset: CGFloat = 0
        while edge.tick(1.0 / 60) { minOffset = min(minOffset, edge.offset) }
        XCTAssertEqual(minOffset, 0, "Con Reducir movimiento no hay rebote")
        XCTAssertEqual(edge.offset, 0)
    }

    func testProgrammaticAnimationReachesTargetAndIsNotTilted() {
        var s = StripScroller()
        s.maxOffset = 2000
        XCTAssertFalse(s.animate(to: 800, duration: 0.4))
        XCTAssertTrue(s.isProgrammatic)
        XCTAssertEqual(s.targetOffset, 800)
        var t: CGFloat = 0
        while s.tick(1.0 / 60), t < 3 { t += 1.0 / 60 }
        XCTAssertEqual(s.offset, 800, accuracy: 1e-9)
        XCTAssertEqual(s.mode, .idle)
        XCTAssertFalse(s.isProgrammatic)
        _ = s.animate(to: 9999, duration: 0.4)
        XCTAssertEqual(s.targetOffset, 2000, "El destino se limita al rango")
    }

    func testAnimateJumpsInstantlyWithReduceMotion() {
        var s = StripScroller()
        s.maxOffset = 2000
        s.reduceMotion = true
        XCTAssertTrue(s.animate(to: 500, duration: 0.4))
        XCTAssertEqual(s.offset, 500)
        XCTAssertEqual(s.mode, .idle)
    }

    func testSystemDrivenWheelFollowsDeltasAndStopsWithoutOwnInertia() {
        var s = StripScroller()
        s.maxOffset = 5000
        for _ in 0..<10 {
            s.wheel(delta: 30, systemDriven: true)
            s.tick(1.0 / 60)
        }
        XCTAssertEqual(s.offset, 300, accuracy: 1e-9)
        XCTAssertEqual(s.mode, .wheel, "Sigue en modo rueda hasta que el sistema acabe el gesto")
        s.endSystemWheel()
        s.tick(1.0 / 60)
        XCTAssertEqual(s.mode, .idle)
        XCTAssertEqual(s.offset, 300, accuracy: 1e-9, "Sin inercia propia con el trackpad")
    }

    func testMouseWheelCoastsWithOwnInertiaAfterIdleTimeout() {
        var s = StripScroller()
        s.maxOffset = 5000
        s.wheel(delta: 120, systemDriven: false)
        s.tick(1.0 / 60)
        XCTAssertEqual(s.mode, .wheel)
        for _ in 0..<8 { s.tick(1.0 / 60) } // > 0,1 s sin eventos
        XCTAssertEqual(s.mode, .free)
        let before = s.offset
        while s.tick(1.0 / 60) {}
        XCTAssertGreaterThan(s.offset, before + 20, "La rueda de ratón tiene inercia propia")
    }

    func testDragReleaseLaunchesInertiaWithMeasuredVelocity() {
        var s = StripScroller()
        s.maxOffset = 5000
        s.offset = 1000
        s.beginDrag()
        for _ in 0..<6 { s.drag(by: 20); s.tick(1.0 / 60) }
        XCTAssertGreaterThan(s.velocity, 500)
        s.endDrag()
        XCTAssertEqual(s.mode, .free)
        let before = s.offset
        while s.tick(1.0 / 60) {}
        XCTAssertGreaterThan(s.offset, before)
    }

    func testShiftKeepsViewportWhenCardsAreInsertedOnTheLeft() {
        var s = StripScroller()
        s.maxOffset = 5000
        s.offset = 700
        _ = s.animate(to: 300, duration: 0.3)
        s.shift(by: 164)
        XCTAssertEqual(s.offset, 864)
        XCTAssertEqual(s.targetOffset, 464)
    }

    func testTiltOpposesVelocityAndIsClamped() {
        XCTAssertEqual(StripScroll.tiltTarget(velocity: 400, reduceMotion: false), -1, accuracy: 1e-9)
        XCTAssertEqual(StripScroll.tiltTarget(velocity: 3200, reduceMotion: false), -3.5, accuracy: 1e-9)
        XCTAssertEqual(StripScroll.tiltTarget(velocity: -9000, reduceMotion: false), 3.5, accuracy: 1e-9)
        XCTAssertEqual(StripScroll.tiltTarget(velocity: 3200, reduceMotion: true), 0)
    }

    func testTiltSpringSettlesToTargetAndBackToZeroUnderOneSecond() {
        var tilt = TiltState()
        for _ in 0..<60 { tilt.step(target: -3.5, dt: 1.0 / 60, reduceMotion: false) }
        XCTAssertEqual(tilt.angle, -3.5, accuracy: 0.2)
        var t = 0.0
        while tilt.step(target: 0, dt: 1.0 / 60, reduceMotion: false), t < 2 { t += 1.0 / 60 }
        XCTAssertEqual(tilt.angle, 0)
        XCTAssertLessThan(t, 1.0, "Vuelve al reposo en menos de 1 s")
        var reduced = TiltState(angle: 2, velocity: 3)
        XCTAssertFalse(reduced.step(target: 3, dt: 1.0 / 60, reduceMotion: true))
        XCTAssertEqual(reduced.angle, 0)
    }

    func testTiltLagIsAtMostOneFrameAndSamplesHistory() {
        XCTAssertEqual(StripScroll.lag(fraction: 1, movingRight: true, reduceMotion: false), 1)
        XCTAssertEqual(StripScroll.lag(fraction: 0, movingRight: true, reduceMotion: false), 0)
        XCTAssertEqual(StripScroll.lag(fraction: 0, movingRight: false, reduceMotion: false), 1)
        XCTAssertEqual(StripScroll.lag(fraction: 1, movingRight: true, reduceMotion: true), 0)
        XCTAssertEqual(StripScroll.sample([10, 20, 30], lag: 0.5), 15, accuracy: 1e-9)
        XCTAssertEqual(StripScroll.sample([10, 20, 30], lag: 9), 30, accuracy: 1e-9)
    }

    func testVisibleAndMountedRanges() {
        let m = StripScroll.Metrics(count: 32, viewWidth: 800)
        // offset 0: visibles 0…4 (24 + 4·164 + 150 = 830 > 800 → la 4 asoma).
        XCTAssertEqual(StripScroll.visibleRange(m, offset: 0), 0..<5)
        XCTAssertEqual(StripScroll.mountedRange(m, offset: 0), 0..<6)
        // Mitad del recorrido: ±1 de margen.
        let v = StripScroll.visibleRange(m, offset: 2000)
        let mounted = StripScroll.mountedRange(m, offset: 2000)
        XCTAssertEqual(mounted.lowerBound, v.lowerBound - 1)
        XCTAssertEqual(mounted.upperBound, v.upperBound + 1)
        XCTAssertLessThanOrEqual(mounted.count, 8, "Nunca más de unas pocas vistas aunque haya 32 capturas")
        // Final y rebote más allá del borde.
        XCTAssertEqual(StripScroll.visibleRange(m, offset: m.maxOffset).upperBound, 32)
        XCTAssertFalse(StripScroll.mountedRange(m, offset: -150).isEmpty)
        XCTAssertTrue(StripScroll.visibleRange(StripScroll.Metrics(count: 0, viewWidth: 800), offset: 0).isEmpty)
    }

    func testHiddenCountsUseOnePixelThreshold() {
        let m = StripScroll.Metrics(count: 32, viewWidth: 800)
        let atStart = StripScroll.hiddenCounts(m, offset: 0)
        XCTAssertEqual(atStart.left, 0)
        XCTAssertEqual(atStart.right, 32 - 4, "La quinta asoma por la derecha y ya cuenta como oculta")
        // Tarjeta 0 desplazada 1 px a la izquierda del borde (x = −1): aún no cuenta; a 1,5 px sí.
        let edge = m.start + 1
        XCTAssertEqual(StripScroll.hiddenCounts(m, offset: edge).left, 0)
        XCTAssertEqual(StripScroll.hiddenCounts(m, offset: edge + 0.5).left, 1)
        let end = StripScroll.hiddenCounts(m, offset: m.maxOffset)
        XCTAssertEqual(end.right, 0)
        XCTAssertGreaterThan(end.left, 0)
        XCTAssertEqual(StripScroll.hiddenCounts(StripScroll.Metrics(count: 3, viewWidth: 900), offset: 0).left, 0)
    }

    func testHiddenCountsAgreeWithBruteForce() {
        let m = StripScroll.Metrics(count: 20, viewWidth: 640)
        for off in stride(from: CGFloat(-50), through: m.maxOffset + 50, by: 37.3) {
            var l = 0, r = 0
            for i in 0..<m.count {
                let x = m.slotX(i) - off
                if x < -1 { l += 1 } else if x + 150 > 640 + 1 { r += 1 }
            }
            let got = StripScroll.hiddenCounts(m, offset: off)
            XCTAssertEqual(got.left, l, "izquierda en offset \(off)")
            XCTAssertEqual(got.right, r, "derecha en offset \(off)")
        }
    }

    func testPageTargetIsEightyPercentOfWidthAndClamped() {
        XCTAssertEqual(StripScroll.pageTarget(base: 100, direction: 1, viewWidth: 1000, maxOffset: 5000), 900)
        XCTAssertEqual(StripScroll.pageTarget(base: 100, direction: -1, viewWidth: 1000, maxOffset: 5000), 0)
        XCTAssertEqual(StripScroll.pageTarget(base: 4900, direction: 1, viewWidth: 1000, maxOffset: 5000), 5000)
    }

    func testEnsureVisibleKeepsSixtyFourPointMargin() {
        let m = StripScroll.Metrics(count: 32, viewWidth: 800)
        // Tarjeta 10 a la derecha de la vista (offset 0): debe quedar a 64 pt del borde derecho.
        let t = StripScroll.ensureVisibleTarget(index: 10, current: 0, m)
        XCTAssertEqual(m.slotX(10) + 150 - t, 800 - 64, accuracy: 1e-9)
        // Ya a la vista: no se mueve.
        XCTAssertEqual(StripScroll.ensureVisibleTarget(index: 1, current: 0, m), 0)
        // Por la izquierda.
        let l = StripScroll.ensureVisibleTarget(index: 3, current: 2000, m)
        XCTAssertEqual(m.slotX(3) - l, 64, accuracy: 1e-9)
        // Nunca fuera de rango y sin efecto si no se desplaza.
        XCTAssertEqual(StripScroll.ensureVisibleTarget(index: 0, current: 300, m), 0)
        XCTAssertEqual(StripScroll.ensureVisibleTarget(index: 1, current: 0, StripScroll.Metrics(count: 3, viewWidth: 900)), 0)
    }

    func testAxisLockKeepsAxisUntilOtherExceedsThreeTimes() {
        var lock = AxisLock()
        XCTAssertEqual(lock.resolve(dx: 0, dy: 0), 0)
        XCTAssertNil(lock.axis)
        XCTAssertEqual(lock.resolve(dx: 10, dy: 4), 10)
        XCTAssertEqual(lock.axis, .horizontal)
        XCTAssertEqual(lock.resolve(dx: 5, dy: 14), 5, "14 < 3×5+: sigue en horizontal")
        XCTAssertEqual(lock.axis, .horizontal)
        XCTAssertEqual(lock.resolve(dx: 2, dy: 20), 20, "20 > 3×2 y > 4: cambia a vertical")
        XCTAssertEqual(lock.axis, .vertical)
        lock.reset()
        XCTAssertNil(lock.axis)
    }

    func testEdgeOpacityMatchesFadeMask() {
        XCTAssertEqual(StripScroll.fadeZone(highContrast: false), 40)
        XCTAssertEqual(StripScroll.fadeZone(highContrast: true), 16)
        XCTAssertEqual(StripScroll.edgeOpacity(centerX: 400, viewWidth: 800, zone: 40), 1)
        XCTAssertEqual(StripScroll.edgeOpacity(centerX: -30, viewWidth: 800, zone: 40), 0, accuracy: 1e-9)
        XCTAssertEqual(StripScroll.edgeOpacity(centerX: 40, viewWidth: 800, zone: 40), 1, accuracy: 1e-9)
    }

    // MARK: - Capacidad de la tira

    func testCapacityOverflowPolicy() {
        XCTAssertEqual(StripCapacity.overflow(count: 9, limit: 8), 1)
        XCTAssertEqual(StripCapacity.overflow(count: 8, limit: 8), 0)
        XCTAssertEqual(StripCapacity.overflow(count: 32, limit: 8), 24)
        XCTAssertEqual(StripCapacity.overflow(count: 500, limit: 0), 0, "0 = sin límite")
        XCTAssertEqual(StripCapacity.options, [8, 16, 32, 0])
        XCTAssertEqual(StripCapacity.title(for: 0), "Sin límite")
        XCTAssertEqual(StripCapacity.removalAnnouncement(3), "Se quitaron 3 capturas más antiguas")
        XCTAssertEqual(StripCapacity.removalAnnouncement(1), "Se quitaron 1 captura más antigua")
    }

    func testCapacityPersistsInUserDefaultsWithDefault32() throws {
        let suite = "tendedero-capacity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(StripCapacity.defaultsKey, "stripCapacity")
        XCTAssertEqual(StripCapacity.load(from: defaults), 32, "Por defecto 32")
        StripCapacity.save(8, to: defaults)
        XCTAssertEqual(StripCapacity.load(from: defaults), 8)
        StripCapacity.save(0, to: defaults)
        XCTAssertEqual(defaults.object(forKey: "stripCapacity") as? Int, 0)
        XCTAssertEqual(StripCapacity.load(from: defaults), 0, "0 se guarda y significa sin límite")
        defaults.set(7, forKey: "stripCapacity")
        XCTAssertEqual(StripCapacity.load(from: defaults), 32, "Un valor ajeno a las opciones vuelve al predeterminado")
    }

    func testAccessibilityTextsForCountersAndRest() {
        XCTAssertEqual(StripScroll.counterLabel(count: 12, side: .right), "Mostrar 12 capturas más a la derecha")
        XCTAssertEqual(StripScroll.counterLabel(count: 1, side: .left), "Mostrar 1 captura más a la izquierda")
        XCTAssertEqual(StripScroll.countsDescription(32), "32 capturas")
        XCTAssertEqual(StripScroll.restAnnouncement(hiddenLeft: 4, hiddenRight: 23, total: 32), "Mostrando de la 5 a la 9 de 32")
    }

    // MARK: - Vista de la tira (virtualización y cuerda)

    @MainActor
    private func makeStripView(count: Int, width: CGFloat = 800) throws -> (TendederoView, [TendederoItem]) {
        let image = try XCTUnwrap(makeTestImage())
        let view = TendederoView(frame: NSRect(x: 0, y: 0, width: width, height: StripMotion.stripHeight))
        let items = (0..<count).map { i in
            TendederoItem(url: URL(fileURLWithPath: "/tmp/strip-test-\(i).png"), cgImage: image, tilt: 0)
        }
        view.reload(items: items)
        return (view, items)
    }

    @MainActor
    func testStripMountsOnlyVisibleCardsPlusOneOfMargin() throws {
        let (view, _) = try makeStripView(count: 32)
        XCTAssertTrue(view.stripMetrics.isScrollable)
        XCTAssertLessThanOrEqual(view.mountedCardCount, 6, "32 capturas, solo las visibles ±1 tienen vista")
        view.page(1)
        view.advanceForTesting(dt: 1.0 / 60, frames: 60)
        XCTAssertEqual(view.scrollOffset, 640, accuracy: 1e-6, "Una página es 0,8 del ancho")
        XCTAssertLessThanOrEqual(view.mountedCardCount, 8)
        XCTAssertGreaterThan(view.mountedCardCount, 0)
    }

    @MainActor
    func testStripMountedCardsFollowTheRopeCurveAtRest() throws {
        let (view, items) = try makeStripView(count: 32)
        view.page(1)
        view.advanceForTesting(dt: 1.0 / 60, frames: 90)
        _ = items
        let m = view.stripMetrics
        for index in StripScroll.visibleRange(m, offset: view.scrollOffset) {
            let card = try XCTUnwrap(view.mountedCardForTesting(at: index))
            let screenX = m.slotX(index) - view.scrollOffset
            XCTAssertEqual(card.frame.minX, screenX, accuracy: 0.01)
            let expectedTop = StripMotion.slotTopBase + StripMotion.ropeY(x: screenX + 75, width: 800)
            XCTAssertEqual(view.bounds.height - card.frame.maxY, expectedTop, accuracy: 0.01, "La y sigue la curva en la x de pantalla")
            XCTAssertEqual(card.scrollTilt, 0, "En reposo no hay inclinación")
        }
    }

    @MainActor
    func testStripFewCardsStayCenteredAndAllMounted() throws {
        let (view, _) = try makeStripView(count: 3, width: 900)
        XCTAssertFalse(view.stripMetrics.isScrollable)
        XCTAssertEqual(view.mountedCardCount, 3)
        let frames = StripMotion.cardFrames(count: 3, width: 900)
        for i in 0..<3 {
            let card = try XCTUnwrap(view.mountedCardForTesting(at: i))
            XCTAssertEqual(card.frame.minX, frames[i].minX, accuracy: 0.01)
        }
    }

    @MainActor
    func testProgrammaticScrollDoesNotTiltCards() throws {
        let (view, _) = try makeStripView(count: 32)
        view.page(1)
        var maxTilt: CGFloat = 0
        for _ in 0..<40 {
            view.advanceForTesting(dt: 1.0 / 60, frames: 1)
            for i in 0..<32 { if let c = view.mountedCardForTesting(at: i) { maxTilt = max(maxTilt, abs(c.scrollTilt)) } }
        }
        XCTAssertEqual(maxTilt, 0, "Los desplazamientos programáticos no inclinan las tarjetas")
    }

    // MARK: - Contadores, cuerda y rueda

    @MainActor
    func testEdgeCountersTrackHiddenCardsOnBothSides() throws {
        let (view, _) = try makeStripView(count: 32)
        let atStart = StripScroll.hiddenCounts(view.stripMetrics, offset: 0)
        XCTAssertEqual(view.leftCounterValue, 0)
        XCTAssertEqual(view.rightCounterValue, atStart.right)
        view.page(1)
        view.advanceForTesting(dt: 1.0 / 60, frames: 60)
        let mid = StripScroll.hiddenCounts(view.stripMetrics, offset: view.scrollOffset)
        XCTAssertGreaterThan(mid.left, 0)
        XCTAssertEqual(view.leftCounterValue, mid.left)
        XCTAssertEqual(view.rightCounterValue, mid.right)
        XCTAssertLessThan(view.leftCounterValue + view.rightCounterValue, 32, "Siempre hay alguna visible")
    }

    func testEdgeCountButtonIsRealAndLargeEnough() {
        XCTAssertGreaterThanOrEqual(EdgeCountButton.height, 36)
        let button = EdgeCountButton(side: .right)
        XCTAssertTrue(button.isHidden, "Sin capturas ocultas no se muestra")
        button.setCount(12, animated: false)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "Mostrar 12 capturas más a la derecha")
        XCTAssertGreaterThanOrEqual(button.frame.height, 36)
        XCTAssertGreaterThanOrEqual(button.frame.width, 52)
        var clicked = 0
        button.onClick = { clicked += 1 }
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(clicked, 1)
        button.setCount(0, animated: false)
        XCTAssertTrue(button.isHidden)
    }

    @MainActor
    func testRopeBandIsTenPointsAroundTheCurveOnlyWhenScrollable() throws {
        let (view, _) = try makeStripView(count: 32)
        view.playReveal(motion: .current(reduceMotion: true), sway: false)
        let x: CGFloat = 400
        let centerY = view.bounds.height - (StripMotion.ropeBase + StripMotion.ropeY(x: x, width: 800))
        XCTAssertTrue(view.ropeBandContains(NSPoint(x: x, y: centerY)))
        XCTAssertTrue(view.ropeBandContains(NSPoint(x: x, y: centerY + 9.5)))
        XCTAssertTrue(view.ropeBandContains(NSPoint(x: x, y: centerY - 9.5)))
        XCTAssertFalse(view.ropeBandContains(NSPoint(x: x, y: centerY + 10.5)))
        XCTAssertFalse(view.ropeBandContains(NSPoint(x: x, y: centerY - 10.5)))
        XCTAssertFalse(view.ropeBandContains(NSPoint(x: -1, y: centerY)))
        // Pass-through: la franja cuenta como zona interactiva (la rueda se captura), un hueco lejano no.
        XCTAssertTrue(view.containsInteractivePoint(NSPoint(x: x, y: centerY)))
        XCTAssertFalse(view.containsInteractivePoint(NSPoint(x: 5, y: 5)))

        let (few, _) = try makeStripView(count: 3, width: 900)
        few.playReveal(motion: .current(reduceMotion: true), sway: false)
        XCTAssertFalse(few.ropeBandContains(NSPoint(x: 450, y: few.bounds.height - StripMotion.ropeBase)),
                       "Si todo cabe la cuerda no se arrastra")
    }

    @MainActor
    func testWheelEventScrollsHorizontallyAndKeepsBusyState() throws {
        let (view, _) = try makeStripView(count: 32)
        view.page(1)
        view.advanceForTesting(dt: 1.0 / 60, frames: 60)
        let start = view.scrollOffset
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        view.scrollWheel(with: event)
        view.advanceForTesting(dt: 1.0 / 60, frames: 1)
        XCTAssertTrue(view.isScrollBusy)
        // El signo lo decide el sistema: un delta X positivo mueve el contenido a la derecha (offset menor).
        XCTAssertEqual(event.scrollingDeltaX > 0, view.scrollOffset < start)
        view.advanceForTesting(dt: 1.0 / 60, frames: 600)
        XCTAssertFalse(view.isScrollBusy, "En reposo el bucle se para")
    }
}
