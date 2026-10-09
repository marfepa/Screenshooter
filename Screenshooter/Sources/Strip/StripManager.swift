import AppKit
import UniformTypeIdentifiers

/// Administrador central del Strip en Screenshooter.
/// Gestiona la persistencia de capturas, el panel deslizante superior,
/// las animaciones espaciales (vuelo y caída libre) y las acciones rápidas del usuario.
@MainActor
public final class StripManager: StripViewDelegate {
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

    public static let shared = StripManager()
    
    public private(set) var items: [StripItem] = []
    /// Capacidad de la tira: `0` = sin límite. Se guarda en `UserDefaults` (`stripCapacity`).
    public private(set) var capacity: Int
    /// Almacén de la capacidad. Inyectable para que los tests no toquen los ajustes reales;
    /// al cambiarlo se vuelve a leer la capacidad guardada en él.
    public var defaults: UserDefaults = .standard {
        didSet { capacity = StripCapacity.load(from: defaults) }
    }
    
    private var panel: StripPanel?
    
    /// Acción que envía un archivo a la Papelera. Inyectable para no ensuciar la Papelera real en tests.
    public var trasher: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
    
    /// Si es `false` no se reproduce el sonido de la Papelera (útil en tests).
    public var playsTrashSound: Bool = true
    
    /// Carpeta dedicada para almacenar capturas en caché
    public static let screenshotsDirectory: URL = {
        let base = StripStorage.defaultBase
        // Primer arranque tras el renombrado: trae el contenido de `Screenshots` a `Shelf`.
        StripStorage.migrateLegacyCache(base: base)
        let dir = StripStorage.cacheDirectory(base: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    /// Carpeta vigilada por el Modo Inbox (capturas nativas). Distinta de `screenshotsDirectory`
    /// para que las capturas propias no se cuelguen dos veces.
    public static let inboxDirectory: URL = {
        _ = screenshotsDirectory  // garantiza que la migración ya se ejecutó
        let dir = StripStorage.inboxDirectory(base: StripStorage.defaultBase)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        capacity = StripCapacity.load(from: .standard)
        setupPanel()
    }
    
    /// Crea el panel único (o lo reutiliza recolocándolo si ya existe, p. ej. al cambiar la configuración de pantallas).
    public func setupPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        if let existing = panel {
            existing.place(on: screen)
            return
        }
        let newPanel = StripPanel(screen: screen)
        newPanel.stripView.delegate = self
        newPanel.stripView.onAnnounce = { [weak self] text in self?.announce(text) }
        newPanel.stripView.reload(items: items)
        newPanel.hasItems = !items.isEmpty
        self.panel = newPanel
    }
    
    /// Recarga las tarjetas y avisa al panel de si hay capturas (controla su timer).
    private func reloadPanel() {
        panel?.stripView.reload(items: items)
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
    
    /// Cuelga una nueva captura en el Strip.
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
        
        // Con Reducir movimiento no hay vuelo: la captura aparece con un fundido en su sitio.
        let flies = fromRect != nil && !MotionStyle.current().reduceMotion
        var newItem = StripItem(url: url, cgImage: cgImage)
        if flies {
            newItem.isFlying = true
        }
        
        items.insert(newItem, at: 0)
        
        // Respetar la capacidad: la más antigua va a la Papelera (nunca se borra de forma definitiva).
        for _ in 0..<StripCapacity.overflow(count: items.count, limit: capacity) {
            let oldest = items.removeLast()
            stopMarkupWatch(itemID: oldest.id)
            moveToTrashQuietly(oldest.url)
        }
        
        // Primero se despliega la tira: las animaciones de llegada solo corren con la ventana visible.
        panel?.peek(seconds: 4)
        reloadPanel()
        
        // Ejecutar animación de vuelo de despegue
        if flies, let originRect = fromRect,
           let targetRect = panel?.stripView.screenFrame(for: newItem.id) {
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
    
    /// Cambia la capacidad de la tira (`0` = sin límite), la guarda y, si hay capturas de más,
    /// retira las más antiguas a la Papelera (cayendo) y lo anuncia.
    public func setCapacity(_ value: Int) {
        let value = StripCapacity.options.contains(value) ? value : StripCapacity.defaultValue
        capacity = value
        StripCapacity.save(value, to: defaults)
        let excess = StripCapacity.overflow(count: items.count, limit: value)
        guard excess > 0 else { return }
        for _ in 0..<excess {
            let oldest = items.removeLast()
            stopMarkupWatch(itemID: oldest.id)
            panel?.stripView.markForFall(itemID: oldest.id)
            moveToTrashQuietly(oldest.url)
        }
        reloadPanel()
        announce(StripCapacity.removalAnnouncement(excess))
    }

    /// Guarda una CGImage en formato PNG dentro del directorio de capturas del Strip.
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
            NSLog("[StripManager] Error al guardar imagen en caché: %@", error.localizedDescription)
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
            NSLog("[StripManager] No se pudo mover a la Papelera %@: %@", url.lastPathComponent, error.localizedDescription)
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
            NSLog("[StripManager] Error al mover a la Papelera: %@", error.localizedDescription)
            NSSound.beep()
            return
        }
        
        items.removeAll { $0.id == itemID }
        panel?.stripView.markForFall(itemID: itemID)
        reloadPanel()
        announce("Movida a la Papelera")
        
        if playsTrashSound {
            let soundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif"
            if FileManager.default.fileExists(atPath: soundPath) {
                NSSound(contentsOfFile: soundPath, byReference: true)?.play()
            }
        }
        
        if items.isEmpty {
            // Deja terminar la caída de la última tarjeta antes de recoger la tira.
            let delay = MotionStyle.current().fallDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.items.isEmpty else { return }
                self.panel?.slideUp()
            }
        }
    }
    
    /// Quita una captura de la tira SIN tocar la Papelera (el archivo ya no existe).
    public func removeFromStrip(itemID: UUID) {
        guard items.contains(where: { $0.id == itemID }) else { return }
        items.removeAll { $0.id == itemID }
        stopMarkupWatch(itemID: itemID)
        reloadPanel()
        announce("Archivo no encontrado, quitada de la tira")
        if items.isEmpty { panel?.slideUp() }
    }
    
    /// Anuncia un texto a VoiceOver con prioridad alta.
    public func announce(_ text: String) {
        NSAccessibility.post(
            element: panel ?? (NSApp as NSApplication),
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
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
                    self.stopMarkupWatch(itemID: itemID)
                    self.reloadPanel()
                    if self.items.isEmpty {
                        self.panel?.slideUp()
                    }
                }
            }
        }
    }
    
    /// Elimina todas las capturas del strip (las envía a la Papelera)
    public func clear() {
        for item in items {
            moveToTrashQuietly(item.url)
        }
        items.removeAll()
        for id in Array(markupWatchers.keys) { stopMarkupWatch(itemID: id) }
        reloadPanel()
        panel?.slideUp()
    }
    
    // MARK: - StripViewDelegate
    
    public func stripViewDidRequestCopy(item: StripItem) -> Bool {
        let ok = ClipboardService.shared.copy(
            cgImage: item.cgImage,
            logicalSize: item.logicalSize,
            playSound: true
        )
        announce(ok ? "Copiado" : "No se pudo copiar")
        return ok
    }

    public func stripViewDidRequestShowInFinder(item: StripItem) {
        announce("Mostrando en Finder")
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    public func stripViewDidRequestRemoveMissing(item: StripItem) {
        removeFromStrip(itemID: item.id)
    }
    
    public func stripViewDidRequestMarkup(item: StripItem) {
        announce("Abriendo en Marcación")
        let itemID = item.id
        startMarkupWatch(itemID: itemID, url: item.url)
        MarkupService.shared.edit(url: item.url, onSaved: { [weak self] _ in
            // Resultado devuelto por Marcación (ya aplicado al archivo): recargar ya;
            // el vigilante cubre escrituras posteriores al callback.
            self?.markupFileChanged(itemID: itemID)
        }, onFinished: { [weak self] in
            self?.markupWatchers[itemID]?.scheduleStop(after: 10)
        })
    }
    
    // MARK: - Vigilancia del archivo durante Marcación
    
    private var markupWatchers: [UUID: MarkupFileWatcher] = [:]
    
    private func startMarkupWatch(itemID: UUID, url: URL) {
        markupWatchers[itemID]?.stop()
        let watcher = MarkupFileWatcher(url: url) { [weak self] in
            self?.markupFileChanged(itemID: itemID)
        }
        watcher.onExpire = { [weak self, weak watcher] in
            guard let self, let watcher, self.markupWatchers[itemID] === watcher else { return }
            self.markupWatchers.removeValue(forKey: itemID)
        }
        markupWatchers[itemID] = watcher
        watcher.start()
    }
    
    private func stopMarkupWatch(itemID: UUID) {
        markupWatchers.removeValue(forKey: itemID)?.stop()
    }
    
    /// Recarga la miniatura y el portapapeles tras un cambio en el archivo. El sonido solo suena una vez por sesión.
    private func markupFileChanged(itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else {
            stopMarkupWatch(itemID: itemID)
            return
        }
        guard items[idx].reloadFromDisk() else { return }
        reloadPanel()
        let watcher = markupWatchers[itemID]
        let playSound = !(watcher?.didPlaySound ?? false)
        watcher?.didPlaySound = true
        ClipboardService.shared.copy(
            cgImage: items[idx].cgImage,
            logicalSize: items[idx].logicalSize,
            playSound: playSound
        )
    }
    
    public func stripViewDidRequestPreview(item: StripItem) {
        announce("Abriendo en Vista Previa")
        NSWorkspace.shared.open(item.url)
    }
    
    public func stripViewDidEndDrag(item: StripItem, operation: NSDragOperation) {
        handleDragEnded(itemID: item.id, operation: operation)
    }
    
    public func stripViewDidRequestDismiss(item: StripItem, cardView: StripCardView) {
        trash(itemID: item.id)
    }
}

/// Vigila un archivo con `DispatchSource` mientras Marcación lo edita. Si la escritura es atómica
/// (`.rename`/`.delete`) el inode cambia, así que se reabre el descriptor sobre la misma ruta.
/// Los cambios se notifican con debounce y esperando a que el tamaño se estabilice.
@MainActor
final class MarkupFileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopped = false
    var didPlaySound = false
    var onExpire: (() -> Void)?
    
    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }
    
    func start() {
        guard !stopped else { return }
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // El archivo puede estar a mitad de sustitución: reintentar enseguida.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.start()
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            MainActor.assumeIsolated {
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.start()   // inode sustituido: reabrir sobre la misma ruta
                }
                self.scheduleChange()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
    
    /// Debounce ~0,15 s y tamaño estable antes de notificar.
    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            var last: Int = -1
            while true {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, !self.stopped else { return }
                let size = (try? self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size == last { break }
                last = size
            }
            guard let self, !self.stopped else { return }
            self.onChange()
        }
    }
    
    func scheduleStop(after seconds: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop()
            self?.onExpire?()
        }
    }
    
    func stop() {
        stopped = true
        debounceTask?.cancel()
        stopTask?.cancel()
        source?.cancel()
        source = nil
    }
}
