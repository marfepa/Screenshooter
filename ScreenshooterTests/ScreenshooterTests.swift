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
}
