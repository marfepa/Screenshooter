import AppKit
import CoreGraphics
import ScreenCaptureKit

public enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case captureFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permiso de grabación de pantalla no concedido."
        case .displayNotFound:
            return "No se encontró el monitor asociado a la selección."
        case .captureFailed(let message):
            return "Error al capturar la pantalla: \(message)"
        }
    }
}

/// Motor de captura de pantalla nativo basado en ScreenCaptureKit de Apple.
public final class ScreenCaptureEngine {
    public static let shared = ScreenCaptureEngine()
    
    private init() {}
    
    /// Comprueba si la aplicación tiene permiso de grabación de pantalla.
    public func hasScreenCapturePermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    /// Solicita permiso de grabación de pantalla si aún no está concedido.
    @discardableResult
    public func requestScreenCapturePermission() -> Bool {
        return CGRequestScreenCaptureAccess()
    }
    
    /// Captura un área específica de una pantalla determinada con recorte a nivel de píxel.
    ///
    /// - Parameters:
    ///   - rect: Rectángulo en coordenadas de pantalla de AppKit (origen abajo a la izquierda).
    ///   - screen: Pantalla NSScreen sobre la que se realizó la selección.
    /// - Returns: Una tupla con la imagen CGImage recortada y su factor de escala Retina.
    public func captureArea(rect: CGRect, on screen: NSScreen) async throws -> (image: CGImage, scale: CGFloat) {
        guard hasScreenCapturePermission() else {
            throw ScreenCaptureError.permissionDenied
        }
        
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let scale = screen.backingScaleFactor
        
        // Obtener el contenido compartible de ScreenCaptureKit
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = shareableContent.displays.first(where: { $0.displayID == displayID }) ?? shareableContent.displays.first else {
            throw ScreenCaptureError.displayNotFound
        }
        
        // Capturar el display completo a resolución nativa
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(scDisplay.width) * scale)
        config.height = Int(CGFloat(scDisplay.height) * scale)
        config.showsCursor = false
        
        let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        
        // Convertir coordenadas de AppKit (origen abajo-izquierda) a coordenadas de píxeles en la imagen (origen arriba-izquierda)
        let screenFrame = screen.frame
        let localX = rect.origin.x - screenFrame.origin.x
        let localY = screenFrame.height - (rect.origin.y - screenFrame.origin.y + rect.height)
        
        let pixelX = round(localX * scale)
        let pixelY = round(localY * scale)
        let pixelW = round(rect.width * scale)
        let pixelH = round(rect.height * scale)
        
        // Asegurar que el recuadro de recorte esté estrictamente dentro de los límites de la imagen
        let clampedX = max(0, min(pixelX, CGFloat(fullImage.width) - 1))
        let clampedY = max(0, min(pixelY, CGFloat(fullImage.height) - 1))
        let clampedW = min(pixelW, CGFloat(fullImage.width) - clampedX)
        let clampedH = min(pixelH, CGFloat(fullImage.height) - clampedY)
        
        let cropRect = CGRect(x: clampedX, y: clampedY, width: max(1, clampedW), height: max(1, clampedH))
        
        guard let croppedImage = fullImage.cropping(to: cropRect) else {
            throw ScreenCaptureError.captureFailed("No se pudo recortar el área seleccionada de la imagen.")
        }
        
        return (image: croppedImage, scale: scale)
    }
}
