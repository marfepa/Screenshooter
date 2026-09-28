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
        XCTAssertEqual(window.level, .screenSaver, "La ventana debe situarse en el nivel .screenSaver")
    }
}
