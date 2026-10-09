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
            return String(localized: "Screen recording permission has not been granted.", bundle: L10n.bundle, locale: L10n.locale, comment: "Error: missing screen recording permission")
        case .displayNotFound:
            return String(localized: "The display for the selection could not be found.", bundle: L10n.bundle, locale: L10n.locale, comment: "Error: display of the selection not found")
        case .captureFailed(let message):
            return String(localized: "Failed to capture the screen: \(message)", bundle: L10n.bundle, locale: L10n.locale, comment: "Error: capture failed; the argument is the underlying reason")
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
            throw ScreenCaptureError.captureFailed(String(localized: "Could not crop the selected area from the image.", bundle: L10n.bundle, locale: L10n.locale, comment: "Error reason: cropping the captured image failed"))
        }
        
        return (image: croppedImage, scale: scale)
    }
}
