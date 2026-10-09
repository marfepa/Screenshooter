import AppKit
import OSLog
import UniformTypeIdentifiers

/// Resultado de interpretar lo que devuelve el servicio de Marcación.
public enum MarkupResult {
    /// Marcación editó el mismo archivo (in situ): no hay nada que copiar.
    case sameFile
    /// Marcación devolvió otra ruta con la copia editada.
    case replace(from: URL)
    /// Marcación devolvió la imagen en memoria.
    case image(NSImage)
    /// No se recibió nada utilizable.
    case none
}

/// Servicio encargado de invocar el editor nativo de Marcación de macOS (Markup),
/// el mismo entorno que muestra macOS al hacer clic sobre una miniatura de captura.
/// Utiliza el servicio del sistema "com.apple.MarkupUI.Markup".
@MainActor
public final class MarkupService: NSObject, NSSharingServiceDelegate {
    public static let shared = MarkupService()
    
    private static let log = Logger(subsystem: "com.marfepa.Screenshooter", category: "Markup")
    private static let markupServiceName = NSSharingService.Name("com.apple.MarkupUI.Markup")
    private var activeURL: URL?
    private var onSavedHandler: ((URL) -> Void)?
    private var onFinishedHandler: (() -> Void)?
    
    private override init() {
        super.init()
    }
    
    /// Abre un archivo de imagen en el editor nativo de Marcación de macOS.
    /// - Parameters:
    ///   - url: URL del archivo de imagen en disco.
    ///   - onSaved: Callback opcional que se invoca tras procesar el resultado de Marcación.
    ///   - onFinished: Callback que se invoca cuando Marcación termina (éxito o fallo).
    public func edit(url: URL, onSaved: ((URL) -> Void)? = nil, onFinished: (() -> Void)? = nil) {
        self.activeURL = url
        self.onSavedHandler = onSaved
        self.onFinishedHandler = onFinished
        
        guard let service = NSSharingService(named: Self.markupServiceName),
              service.canPerform(withItems: [url]) else {
            Self.log.info("Servicio de Marcación no disponible; se abre en Vista Previa")
            // Si el servicio no está disponible en la versión del sistema, abrir en Vista Previa
            NSWorkspace.shared.open(url)
            finish()
            return
        }
        
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }
    
    // MARK: - Lógica pura
    
    /// Decide qué hacer con los items devueltos por Marcación respecto al archivo original.
    public nonisolated static func resolveEdited(items: [Any], original: URL) -> MarkupResult {
        let originalPath = original.standardizedFileURL.resolvingSymlinksInPath().path
        for item in items {
            if let image = item as? NSImage { return .image(image) }
            if let url = (item as? URL) ?? (item as? NSURL) as URL?, url.isFileURL {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                return path == originalPath ? .sameFile : .replace(from: url)
            }
        }
        return .none
    }
    
    /// Sustituye `original` por el contenido de `source` de forma atómica conservando la ruta y el nombre.
    @discardableResult
    public nonisolated static func replaceAtomically(original: URL, with source: URL) -> Bool {
        let fm = FileManager.default
        let temp = original.deletingLastPathComponent()
            .appendingPathComponent(".markup-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: source, to: temp)
            _ = try fm.replaceItemAt(original, withItemAt: temp)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            log.error("No se pudo reemplazar el original: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    private func finish() {
        let finished = onFinishedHandler
        activeURL = nil
        onSavedHandler = nil
        onFinishedHandler = nil
        finished?()
    }
    
    private nonisolated static func describe(_ items: [Any]) -> String {
        items.map { item -> String in
            if let url = (item as? URL) ?? (item as? NSURL) as URL? { return "\(type(of: item)):\(url.path)" }
            return "\(type(of: item))"
        }.joined(separator: ", ")
    }
    
    // MARK: - NSSharingServiceDelegate
    
    public nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Self.log.info("didShareItems: [\(Self.describe(items), privacy: .public)]")
        // Los items no son Sendable; se interpretan aquí y solo se pasa el resultado.
        nonisolated(unsafe) let received = items
        Task { @MainActor in
            guard let url = self.activeURL else { return }
            switch Self.resolveEdited(items: received, original: url) {
            case .sameFile:
                Self.log.info("Marcación editó el mismo archivo in situ")
            case .replace(let source):
                let ok = Self.replaceAtomically(original: url, with: source)
                Self.log.info("Copia editada en \(source.path, privacy: .public); reemplazo ok=\(ok, privacy: .public)")
            case .image(let image):
                if let tiffData = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiffData),
                   let pngData = rep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url, options: .atomic)
                    Self.log.info("Imagen en memoria escrita sobre el original")
                }
            case .none:
                Self.log.info("Resultado sin items utilizables")
            }
            self.onSavedHandler?(url)
            self.finish()
        }
    }
    
    public nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        Self.log.info("didFailToShareItems: [\(Self.describe(items), privacy: .public)] error=\(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            self.finish()
        }
    }
}
