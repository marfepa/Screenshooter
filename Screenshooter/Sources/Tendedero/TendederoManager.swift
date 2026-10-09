import AppKit
import UniformTypeIdentifiers

/// Administrador central del Tendedero en Screenshooter.
/// Gestiona la persistencia de capturas, el panel deslizante superior,
/// las animaciones espaciales (vuelo y caída libre) y las acciones rápidas del usuario.
@MainActor
public final class TendederoManager: TendederoViewDelegate {
    /// Resultado de evaluar el fin de un arrastre.
    public enum DragEndDecision: Equatable {
        case trash   // Soltado en la Papelera del Dock
        case remove  // Movido a otra ubicación: sacar de la tira sin borrar nada
        case keep    // Copiado o cancelado: se mantiene
    }
    
    /// Lógica pura: decide qué hacer según la operación de arrastre y si el archivo sigue en origen.
    public nonisolated static func dragEndDecision(operation: NSDragOperation, fileExists: Bool) -> DragEndDecision {
        if operation.contains(.delete) { return .trash }
        if operation.contains(.move) && !fileExists { return .remove }
        return .keep
    }

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
    
    /// Carpeta vigilada por el Modo Inbox (capturas nativas). Distinta de `screenshotsDirectory`
    /// para que las capturas propias no se cuelguen dos veces.
    public static let inboxDirectory: URL = {
        let dir = screenshotsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        setupPanel()
    }
    
    /// Crea el panel único (o lo reutiliza recolocándolo si ya existe, p. ej. al cambiar la configuración de pantallas).
    public func setupPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        if let existing = panel {
            existing.place(on: screen)
            return
        }
        let newPanel = TendederoPanel(screen: screen)
        newPanel.tendederoView.delegate = self
        newPanel.tendederoView.reload(items: items)
        newPanel.hasItems = !items.isEmpty
        self.panel = newPanel
    }
    
    /// Recarga las tarjetas y avisa al panel de si hay capturas (controla su timer).
    private func reloadPanel() {
        panel?.tendederoView.reload(items: items)
        panel?.hasItems = !items.isEmpty
    }
    
    public func toggle() {
        panel?.toggle()
    }
    
    public func show(autoHide: Bool = false) {
        if autoHide {
            panel?.peek(seconds: 3.5)
        } else {
            panel?.reveal(pinned: true)
        }
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
        // Evitar duplicados: si ya hay un item con la misma URL, no se vuelve a colgar.
        let target = url.standardizedFileURL
        if items.contains(where: { $0.url.standardizedFileURL == target }) { return }
        
        // Un único panel: se recoloca en la pantalla de la captura.
        if panel == nil { setupPanel() }
        panel?.place(on: screen)
        
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
        
        reloadPanel()
        panel?.peek(seconds: 4)
        
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
                    self.reloadPanel()
                }
            }
        } else {
            // Si no hay coordenadas de origen, mostrar de inmediato
            if let idx = items.firstIndex(where: { $0.id == newItem.id }) {
                items[idx].isFlying = false
                reloadPanel()
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
        reloadPanel()
        
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
    
    /// Gestiona el final de un arrastre iniciado desde una tarjeta.
    /// La Papelera del Dock solo informa `.delete`; Finder completa el `.move` de forma asíncrona,
    /// por lo que se comprueba la existencia del archivo tras una breve espera.
    public func handleDragEnded(itemID: UUID, operation: NSDragOperation) {
        if operation.contains(.delete) {
            trash(itemID: itemID)
        } else if operation.contains(.move) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self,
                      let item = self.items.first(where: { $0.id == itemID }) else { return }
                let exists = FileManager.default.fileExists(atPath: item.url.path)
                if Self.dragEndDecision(operation: .move, fileExists: exists) == .remove {
                    self.items.removeAll { $0.id == itemID }
                    self.reloadPanel()
                    if self.items.isEmpty {
                        self.panel?.slideUp()
                    }
                }
            }
        }
    }
    
    /// Elimina todas las capturas del tendedero (las envía a la Papelera)
    public func clear() {
        for item in items {
            moveToTrashQuietly(item.url)
        }
        items.removeAll()
        reloadPanel()
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
                self.reloadPanel()
                
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
    
    public func tendederoViewDidEndDrag(item: TendederoItem, operation: NSDragOperation) {
        handleDragEnded(itemID: item.id, operation: operation)
    }
    
    public func tendederoViewDidRequestDismiss(item: TendederoItem, cardView: TendederoCardView) {
        guard let window = cardView.window,
              let screen = window.screen else {
            items.removeAll { $0.id == item.id }
            reloadPanel()
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
            self.reloadPanel()
            self.moveToTrashQuietly(item.url)
            
            if self.items.isEmpty {
                self.panel?.slideUp()
            }
        }
    }
}
