import AppKit
import AudioToolbox

/// Servicio responsable de transferir imágenes capturadas al portapapeles de macOS (NSPasteboard)
/// y emitir feedback sensorial.
public final class ClipboardService {
    public static let shared = ClipboardService()
    
    private init() {}
    
    /// Copia una CGImage al portapapeles respetando la densidad Retina.
    ///
    /// - Parameters:
    ///   - cgImage: Imagen CoreGraphics resultante de la captura.
    ///   - logicalSize: Tamaño en puntos lógicos de la pantalla (para no duplicar el tamaño visual al pegar en pantallas Retina).
    ///   - playSound: Determina si se reproduce el sonido de obturador del sistema.
    ///   - pasteboard: Instancia de NSPasteboard de destino (por defecto, NSPasteboard.general).
    /// - Returns: True si la imagen fue escrita exitosamente en el portapapeles.
    @discardableResult
    public func copy(
        cgImage: CGImage,
        logicalSize: CGSize? = nil,
        playSound: Bool = true,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        
        let size = logicalSize ?? CGSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        
        var success = pasteboard.writeObjects([nsImage])
        
        // Adjuntar representación PNG explícita para compatibilidad total con apps web / WhatsApp / Slack / Electron
        if let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(pngData, forType: .png)
            pasteboard.setData(tiffData, forType: .tiff)
            success = true
        }
        
        if success && playSound {
            // Reproducir sonido nativo de obturador de cámara de macOS
            AudioServicesPlaySystemSound(1108)
        }
        
        return success
    }
}
