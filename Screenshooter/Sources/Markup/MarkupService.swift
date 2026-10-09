import AppKit
import UniformTypeIdentifiers

/// Servicio encargado de invocar el editor nativo de Marcación de macOS (Markup),
/// el mismo entorno que muestra macOS al hacer clic sobre una miniatura de captura.
/// Utiliza el servicio del sistema "com.apple.MarkupUI.Markup".
@MainActor
public final class MarkupService: NSObject, NSSharingServiceDelegate {
    public static let shared = MarkupService()
    
    private static let markupServiceName = NSSharingService.Name("com.apple.MarkupUI.Markup")
    private var activeURL: URL?
    private var onSavedHandler: ((URL) -> Void)?
    
    private override init() {
        super.init()
    }
    
    /// Abre un archivo de imagen en el editor nativo de Marcación de macOS.
    /// - Parameters:
    ///   - url: URL del archivo de imagen en disco.
    ///   - onSaved: Callback opcional que se invoca tras guardar las modificaciones.
    public func edit(url: URL, onSaved: ((URL) -> Void)? = nil) {
        self.activeURL = url
        self.onSavedHandler = onSaved
        
        guard let service = NSSharingService(named: Self.markupServiceName),
              service.canPerform(withItems: [url]) else {
            // Si el servicio no está disponible en la versión del sistema, abrir en Vista Previa
            NSWorkspace.shared.open(url)
            return
        }
        
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }
    
    // MARK: - NSSharingServiceDelegate
    
    public nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in
            guard let url = self.activeURL else { return }
            
            // Si el servicio devuelve la imagen editada en memoria, escribirla sobre el archivo original
            for item in items {
                if let image = item as? NSImage,
                   let tiffData = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiffData),
                   let pngData = rep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url, options: .atomic)
                    break
                }
            }
            
            self.onSavedHandler?(url)
            self.activeURL = nil
            self.onSavedHandler = nil
        }
    }
    
    public nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        Task { @MainActor in
            self.activeURL = nil
            self.onSavedHandler = nil
        }
    }
}
