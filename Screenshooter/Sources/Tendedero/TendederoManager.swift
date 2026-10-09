import AppKit
import UniformTypeIdentifiers

/// Administrador central del Tendedero en Screenshooter.
/// Gestiona la persistencia de capturas, el panel deslizante superior,
/// las animaciones espaciales (vuelo y caída libre) y las acciones rápidas del usuario.
@MainActor
public final class TendederoManager: TendederoViewDelegate {
    public static let shared = TendederoManager()
    
    public private(set) var items: [TendederoItem] = []
    public let maxItems: Int = 8
    
    private var panel: TendederoPanel?
    
    /// Carpeta dedicada para almacenar capturas en caché
    public static let screenshotsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Screenshooter/Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private init() {
        setupPanel()
    }
    
    public func setupPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let newPanel = TendederoPanel(screen: screen)
        newPanel.tendederoView.delegate = self
        self.panel = newPanel
    }
    
    public func toggle() {
        panel?.toggle()
    }
    
    public func show(autoHide: Bool = false) {
        panel?.slideDown(autoHideDelay: autoHide ? 3.5 : nil)
    }
    
    public func hide() {
        panel?.slideUp()
    }
    
    /// Cuelga una nueva captura en el Tendedero.
    /// - Parameters:
    ///   - url: Ubicación del archivo de la captura.
    ///   - cgImage: Imagen CoreGraphics.
    ///   - fromRect: Rectángulo de origen en la pantalla para ejecutar la animación de vuelo (opcional).
    ///   - screen: Pantalla donde se originó la captura.
    public func hang(url: URL, cgImage: CGImage, fromRect: CGRect? = nil, screen: NSScreen = NSScreen.main ?? NSScreen.screens.first!) {
        // Asegurar que el panel esté asociado a la pantalla de captura
        if panel?.screen != screen {
            panel?.orderOut(nil)
            panel = TendederoPanel(screen: screen)
            panel?.tendederoView.delegate = self
        }
        
        var newItem = TendederoItem(url: url, cgImage: cgImage)
        if fromRect != nil {
            newItem.isFlying = true
        }
        
        items.insert(newItem, at: 0)
        
        // Mantener como máximo `maxItems` capturas
        while items.count > maxItems {
            let oldest = items.removeLast()
            try? FileManager.default.removeItem(at: oldest.url)
        }
        
        panel?.tendederoView.reload(items: items)
        panel?.slideDown(autoHideDelay: 4.0)
        
        // Ejecutar animación de vuelo de despegue
        if let originRect = fromRect,
           let targetRect = panel?.tendederoView.screenFrame(for: newItem.id) {
            CaptureFlight.fly(
                image: cgImage,
                from: originRect,
                to: targetRect,
                tilt: newItem.tilt,
                screen: screen
            ) { [weak self] in
                guard let self = self else { return }
                if let idx = self.items.firstIndex(where: { $0.id == newItem.id }) {
                    self.items[idx].isFlying = false
                    self.panel?.tendederoView.reload(items: self.items)
                }
            }
        } else {
            // Si no hay coordenadas de origen, mostrar de inmediato
            if let idx = items.firstIndex(where: { $0.id == newItem.id }) {
                items[idx].isFlying = false
                panel?.tendederoView.reload(items: items)
            }
        }
    }
    
    /// Guarda una CGImage en formato PNG dentro del directorio de capturas del Tendedero.
    public func saveToCache(cgImage: CGImage) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "Captura-\(timestamp).png"
        let destination = Self.screenshotsDirectory.appendingPathComponent(filename)
        
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        
        do {
            try pngData.write(to: destination, options: .atomic)
            return destination
        } catch {
            NSLog("[TendederoManager] Error al guardar imagen en caché: %@", error.localizedDescription)
            return nil
        }
    }
    
    /// Elimina todas las capturas del tendedero
    public func clear() {
        for item in items {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll()
        panel?.tendederoView.reload(items: items)
        panel?.slideUp()
    }
    
    // MARK: - TendederoViewDelegate
    
    public func tendederoViewDidRequestCopy(item: TendederoItem) {
        ClipboardService.shared.copy(
            cgImage: item.cgImage,
            logicalSize: item.logicalSize,
            playSound: true
        )
    }
    
    public func tendederoViewDidRequestMarkup(item: TendederoItem) {
        MarkupService.shared.edit(url: item.url) { [weak self] updatedURL in
            guard let self = self else { return }
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx].reloadFromDisk()
                self.panel?.tendederoView.reload(items: self.items)
                
                // Actualizar portapapeles con la versión anotada
                ClipboardService.shared.copy(
                    cgImage: self.items[idx].cgImage,
                    logicalSize: self.items[idx].logicalSize,
                    playSound: true
                )
            }
        }
    }
    
    public func tendederoViewDidRequestPreview(item: TendederoItem) {
        NSWorkspace.shared.open(item.url)
    }
    
    public func tendederoViewDidRequestDismiss(item: TendederoItem, cardView: TendederoCardView) {
        guard let window = cardView.window,
              let screen = window.screen else {
            items.removeAll { $0.id == item.id }
            panel?.tendederoView.reload(items: items)
            try? FileManager.default.removeItem(at: item.url)
            return
        }
        
        let cardScreenRect = window.convertToScreen(cardView.convert(cardView.bounds, to: nil))
        
        // Ocultar tarjeta inmediatamente en la vista
        cardView.isHidden = true
        
        // Ejecutar animación de caída libre por gravedad
        CaptureFlight.fall(
            image: item.cgImage,
            cardRect: cardScreenRect,
            tilt: item.tilt,
            screen: screen
        ) { [weak self] in
            guard let self = self else { return }
            self.items.removeAll { $0.id == item.id }
            self.panel?.tendederoView.reload(items: self.items)
            try? FileManager.default.removeItem(at: item.url)
            
            if self.items.isEmpty {
                self.panel?.slideUp()
            }
        }
    }
}
