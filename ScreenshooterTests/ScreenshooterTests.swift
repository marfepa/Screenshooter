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
        
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        guard let testImage = context.makeImage() else {
            XCTFail("No se pudo generar CGImage")
            return
        }
        
        let copied = ClipboardService.shared.copy(cgImage: testImage, logicalSize: CGSize(width: 10, height: 10), playSound: false)
        XCTAssertTrue(copied, "La imagen debe ser transferida al portapapeles con éxito")
        
        // Verificar que NSPasteboard contiene tipos de imagen
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.tiff) || types.contains(.png), "El portapapeles debe contener tipos de imagen estándar")
    }
}
