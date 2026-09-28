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
    
    /// Captura un área específica de una pantalla determinada.
    ///
    /// - Parameters:
    ///   - rect: Rectángulo en coordenadas de pantalla de AppKit (origen abajo a la izquierda).
    ///   - screen: Pantalla NSScreen sobre la que se realizó la selección.
    /// - Returns: Una tupla con la imagen CGImage capturada y su factor de escala Retina.
    public func captureArea(rect: CGRect, on screen: NSScreen) async throws -> (image: CGImage, scale: CGFloat) {
        guard hasScreenCapturePermission() else {
            throw ScreenCaptureError.permissionDenied
        }
        
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let scale = screen.backingScaleFactor
        
        // Convertir coordenadas de AppKit (origen abajo-izquierda) a ScreenCaptureKit (origen arriba-izquierda)
        let screenFrame = screen.frame
        let localX = rect.origin.x - screenFrame.origin.x
        let localY = screenFrame.height - (rect.origin.y - screenFrame.origin.y + rect.height)
        let sourceRect = CGRect(x: max(0, localX), y: max(0, localY), width: rect.width, height: rect.height)
        
        // Obtener el contenido compartible de ScreenCaptureKit
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = shareableContent.displays.first(where: { $0.displayID == displayID }) ?? shareableContent.displays.first else {
            throw ScreenCaptureError.displayNotFound
        }
        
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)
        config.showsCursor = false
        config.scalesToFit = false
        
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image: cgImage, scale: scale)
    }
}
