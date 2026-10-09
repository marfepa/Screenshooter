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
    
    /// Acción que envía un archivo a la Papelera. Inyectable para no ensuciar la Papelera real en tests.
    public var trasher: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    
    /// Si es `false` no se reproduce el sonido de la Papelera (útil en tests).
    public var playsTrashSound: Bool = true
    
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
            moveToTrashQuietly(oldest.url)
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
    
    /// Envía un archivo a la Papelera sin sonido; registra el error si falla.
    /// Nunca borra de forma definitiva.
    @discardableResult
    private func moveToTrashQuietly(_ url: URL) -> Bool {
        do {
            try trasher(url)
            return true
        } catch {
            NSLog("[TendederoManager] No se pudo mover a la Papelera %@: %@", url.lastPathComponent, error.localizedDescription)
            return false
        }
    }
    
    /// Manda una captura concreta a la Papelera y la saca de la tira.
    /// Si falla, suena el beep del sistema y el item permanece.
    public func trash(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        
        do {
            try trasher(item.url)
        } catch {
            NSLog("[TendederoManager] Error al mover a la Papelera: %@", error.localizedDescription)
            NSSound.beep()
            return
        }
        
        items.removeAll { $0.id == itemID }
        panel?.tendederoView.reload(items: items)
        
        if playsTrashSound {
            let soundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif"
            if FileManager.default.fileExists(atPath: soundPath) {
                NSSound(contentsOfFile: soundPath, byReference: true)?.play()
            }
        }
        
        if items.isEmpty {
            panel?.slideUp()
        }
    }
    
    /// Elimina todas las capturas del tendedero (las envía a la Papelera)
    public func clear() {
        for item in items {
            moveToTrashQuietly(item.url)
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
            moveToTrashQuietly(item.url)
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
            self.moveToTrashQuietly(item.url)
            
            if self.items.isEmpty {
                self.panel?.slideUp()
            }
        }
    }
}
