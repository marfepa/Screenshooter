import AppKit

/// Coordinador principal del ciclo de vida de captura de pantalla.
/// Administra la apertura de ventanas de superposición multi-pantalla,
/// la interacción con el usuario y la canalización del resultado hacia el portapapeles.
@MainActor
public final class CaptureCoordinator {
    public static let shared = CaptureCoordinator()
    
    /// Se publica cada vez que el modo continuo empieza o termina (la barra de menús muestra «Salir del modo captura»).
    public static let activeDidChangeNotification = Notification.Name("CaptureCoordinatorActiveDidChange")
    
    /// Inactividad permitida con los overlays visibles y en el modo Navegar.
    private static let selectingTimeout: TimeInterval = 30
    private static let navigatingTimeout: TimeInterval = 120
    private static let navigatingWarningLead: TimeInterval = 10
    
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var navigationPill: NavigationPillWindow?
    private var activeHUD: HUDNotificationWindow?
    private var safetyTimer: Timer?
    private var warningTimer: Timer?
    private var scrollQuietTimer: Timer?
    private var scrollMonitors: [Any] = []
    private var scrollTracker = ScrollPassthroughTracker()
    /// Sube en cada captura y en cada salida del modo: un `Task` de captura solo toca el estado
    /// si sigue siendo la sesión vigente (ESC y ⌥⌘S pueden haber abierto otra mientras capturaba).
    private var captureGeneration = 0
    private var scrollController: ScrollCaptureController?
    /// Solo la siguiente selección se fuerza como captura larga (entrada desde el menú).
    private var forceScrollCaptureOnce = false
    
    public private(set) var state: ContinuousCaptureState = .idle {
        didSet {
            if state.isActive != oldValue.isActive {
                NotificationCenter.default.post(name: Self.activeDidChangeNotification, object: self)
            }
        }
    }
    
    public var isActive: Bool { state.isActive }
    
    private init() {}
    
    /// ⌥⌘S (o el menú): inicia el modo de captura continua y, con él ya activo,
    /// alterna entre seleccionar áreas y navegar libremente por el sistema.
    /// El modo termina con ESC, «Salir» o el temporizador de inactividad.
    public func toggleCapture() {
        if state == .idle {
            // Verificar permisos antes de oscurecer pantallas
            if !PermissionsHelper.shared.isScreenCaptureGranted {
                // La alerta es modal: con la bienvenida delante quedaría tapada y la app parecería colgada
                OnboardingCoordinator.shared.setSuspended(true)
                PermissionsHelper.shared.promptPermissionDialogIfNeeded()
                OnboardingCoordinator.shared.setSuspended(false)
                return
            }
        }
        
        let previous = state
        state = ContinuousCaptureMachine.next(state, on: .hotKey)
        guard state != previous else { return }
        
        switch state {
        case .selecting:
            dismissNavigationPill()
            presentOverlays()
            if previous == .navigating {
                announce(String(localized: "Selecting. Drag to capture.", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when going back from navigate mode to selecting areas"))
            }
        case .navigating:
            enterNavigating()
        default:
            break
        }
    }
    
    /// Menú «Captura larga…»: igual que iniciar la captura (permiso incluido), pero la siguiente
    /// selección es una captura larga sin necesidad de ⇧.
    public func startScrollCaptureSelection() {
        if state == .idle {
            toggleCapture()
            guard state == .selecting else { return }
        } else if state == .navigating {
            toggleCapture()
            guard state == .selecting else { return }
        } else if state != .selecting {
            return
        }
        forceScrollCaptureOnce = true
        for overlay in overlayWindows { overlay.selectionView.forcesScrollCapture = true }
    }
    
    /// Presenta una ventana de superposición transparente por cada monitor activo.
    private func presentOverlays() {
        dismissOverlays()
        
        // Activar la aplicación explícitamente para que reciba eventos de ratón y teclado siendo LSUIElement
        NSApp.activate(ignoringOtherApps: true)
        
        for screen in NSScreen.screens {
            let overlay = SelectionOverlayWindow(screen: screen)
            
            overlay.selectionView.onSelectionCompleted = { [weak self] selectedRect, targetScreen in
                self?.handleSelectionCompleted(rect: selectedRect, on: targetScreen)
            }
            
            overlay.selectionView.onScrollCaptureSelected = { [weak self] selectedRect, targetScreen in
                self?.beginScrollCapture(rect: selectedRect, on: targetScreen)
            }
            overlay.selectionView.forcesScrollCapture = forceScrollCaptureOnce
            
            overlay.selectionView.onCancelled = { [weak self] in
                self?.cancelCapture()
            }
            
            overlay.selectionView.onScrollPassthrough = { [weak self] _ in
                self?.beginScrollPassthrough()
            }
            
            overlay.orderFrontRegardless()
            overlayWindows.append(overlay)
        }
        
        // Asegurar foco y primer respondedor en la ventana de la pantalla activa para capturar atajos como ESC
        if let keyWindow = overlayWindows.first(where: { $0.screen == NSScreen.main }) ?? overlayWindows.first {
            keyWindow.makeKey()
            keyWindow.makeFirstResponder(keyWindow.selectionView)
        }
        
        // Temporizador de seguridad: si el overlay lleva más de 30 segundos
        // sin interacción completada, cancelar automáticamente para evitar bloqueos.
        restartSafetyTimer(after: Self.selectingTimeout)
    }
    
    // MARK: - Scroll pasante
    
    /// El usuario empieza a hacer scroll sin arrastrar: los overlays dejan pasar los eventos
    /// a la ventana bajo el cursor hasta que el puntero se mueve o pasa `quietInterval` sin scroll.
    private func beginScrollPassthrough() {
        let previous = state
        state = ContinuousCaptureMachine.next(state, on: .scrollBegan)
        guard state == .scrollPassthrough, previous != state else { return }
        
        for overlay in overlayWindows {
            overlay.setPassthrough(true)
        }
        scrollTracker.noteScroll(at: ProcessInfo.processInfo.systemUptime, pointer: NSEvent.mouseLocation)
        restartSafetyTimer(after: Self.selectingTimeout)
        
        // Con los overlays transparentes el scroll va a otras apps (monitor global)
        // o a ventanas propias como la Tira (monitor local). Ninguno pide permiso de Accesibilidad.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            Task { @MainActor in self?.noteScrollActivity() }
        }) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            Task { @MainActor in self?.noteScrollActivity() }
            return event
        }) {
            scrollMonitors.append(local)
        }
        
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkScrollPassthroughEnd() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollQuietTimer = timer
        
        announce(String(localized: "Scrolling", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when the overlay lets scrolling through to the app below"))
    }
    
    private func noteScrollActivity() {
        guard state == .scrollPassthrough else { return }
        scrollTracker.noteScroll(at: ProcessInfo.processInfo.systemUptime, pointer: NSEvent.mouseLocation)
        restartSafetyTimer(after: Self.selectingTimeout)
    }
    
    private func checkScrollPassthroughEnd() {
        // Con un botón pulsado (p. ej. arrastrando la barra de scroll de otra app) no reaparecer a mitad del arrastre
        guard state == .scrollPassthrough,
              scrollTracker.shouldEnd(at: ProcessInfo.processInfo.systemUptime, pointer: NSEvent.mouseLocation),
              NSEvent.pressedMouseButtons == 0 else { return }
        state = ContinuousCaptureMachine.next(state, on: .scrollEnded)
        stopScrollPassthrough()
        
        for overlay in overlayWindows {
            overlay.setPassthrough(false)
        }
        // Un clic durante el scroll pudo activar otra app: recuperar el foco para que ESC llegue
        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow = overlayWindows.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? overlayWindows.first {
            keyWindow.makeKey()
            keyWindow.makeFirstResponder(keyWindow.selectionView)
        }
        announce(String(localized: "Selecting. Drag to capture.", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when going back from navigate mode to selecting areas"))
    }
    
    /// Retira monitores y timer del scroll pasante (no toca los overlays).
    private func stopScrollPassthrough() {
        scrollQuietTimer?.invalidate()
        scrollQuietTimer = nil
        for monitor in scrollMonitors {
            NSEvent.removeMonitor(monitor)
        }
        scrollMonitors.removeAll()
        scrollTracker.reset()
    }
    
    // MARK: - Modo Navegar
    
    /// Oculta los overlays y deja solo la píldora: el usuario usa el sistema con normalidad
    /// hasta volver a pulsar ⌥⌘S.
    private func enterNavigating() {
        // La captura larga forzada vale solo para la siguiente selección
        forceScrollCaptureOnce = false
        dismissOverlays()
        
        let pill = NavigationPillWindow()
        pill.onExit = { [weak self] in
            self?.cancelCapture()
        }
        navigationPill = pill
        pill.present()
        
        // Devolver el foco a la app que estaba debajo (la nuestra solo lo tenía por los overlays)
        NSApp.deactivate()
        
        restartSafetyTimer(after: Self.navigatingTimeout)
        let warning = Timer(timeInterval: Self.navigatingTimeout - Self.navigatingWarningLead, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .navigating else { return }
                let seconds = Int(Self.navigatingWarningLead)
                self.navigationPill?.showTimeoutWarning(seconds: seconds)
                self.announce(String(localized: "Capture mode ends in \(String(seconds)) seconds", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement shortly before continuous capture ends for inactivity; the argument is a number of seconds"))
            }
        }
        RunLoop.main.add(warning, forMode: .common)
        warningTimer = warning
        
        announce(String(localized: "Navigate mode. Press Option Command S to capture.", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when the overlays hide so the user can use other apps"))
    }
    
    private func dismissNavigationPill() {
        navigationPill?.dismiss()
        navigationPill = nil
        warningTimer?.invalidate()
        warningTimer = nil
    }
    
    // MARK: - Fin del modo
    
    /// Termina el modo continuo cerrando superposiciones y píldora sin alterar el portapapeles.
    public func cancelCapture() {
        guard state != .idle else { return }
        captureGeneration += 1
        forceScrollCaptureOnce = false
        tearDownScrollCapture()
        dismissOverlays()
        dismissNavigationPill()
        state = ContinuousCaptureMachine.next(state, on: .cancel)
    }
    
    // MARK: - Captura larga
    
    /// Selección soltada con ⇧ o elegida desde el menú: pasa a `scrollCapturing` y arranca el controlador.
    private func beginScrollCapture(rect: CGRect, on screen: NSScreen) {
        let previous = state
        state = ContinuousCaptureMachine.next(state, on: .scrollCaptureRequested)
        guard state == .scrollCapturing, previous != state else { return }
        forceScrollCaptureOnce = false
        dismissOverlays() // también para el temporizador de seguridad: la inactividad la lleva el modelo
        ScrollCaptureHelpHint.recordUse(defaults: .standard)
        captureGeneration += 1
        let generation = captureGeneration
        
        let controller = ScrollCaptureController(rect: rect, screen: screen) { [weak self] text in
            self?.announce(text)
        }
        controller.onCancelled = { [weak self] in
            guard let self, generation == self.captureGeneration else { return }
            self.scrollController = nil
            self.cancelCapture()
        }
        controller.onFailed = { [weak self] error in
            NSLog("[CaptureCoordinator] Error en la captura larga: %@", error.localizedDescription)
            guard let self, generation == self.captureGeneration else { return }
            self.scrollController = nil
            // Salir del modo antes de la alerta: un overlay la taparía
            self.cancelCapture()
            self.showErrorAlert(message: error.localizedDescription)
        }
        controller.onFinished = { [weak self] result in
            guard let self, generation == self.captureGeneration else { return }
            self.scrollController = nil
            self.finishScrollCapture(result, generation: generation)
        }
        scrollController = controller
        controller.start()
    }
    
    private func finishScrollCapture(_ result: ScrollCaptureController.Result, generation: Int) {
        state = ContinuousCaptureMachine.next(state, on: .scrollCaptureFinished)
        guard state == .processing else { return }
        let scale = max(result.screen.backingScaleFactor, 1)
        let logicalSize = CGSize(width: CGFloat(result.image.width) / scale, height: CGFloat(result.image.height) / scale)
        finishCapture(
            image: result.image,
            logicalSize: logicalSize,
            rect: result.rect,
            screen: result.screen,
            generation: generation,
            notice: result.interrupted
                ? String(localized: "The long capture was interrupted. What was captured so far is in the Shelf.", bundle: L10n.bundle, locale: L10n.locale, comment: "Notice shown when the screen stream stopped during a long capture and the partial result was saved")
                : nil,
            isLongCapture: result.isLongCapture
        )
        if !result.interrupted {
            announce(String(localized: "Long capture copied to the Shelf.", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when the long capture is saved"))
        }
    }
    
    /// Desmonta sesión, monitores, temporizador y ventanas de la captura larga (si hay).
    private func tearDownScrollCapture() {
        guard let controller = scrollController else { return }
        scrollController = nil
        controller.onCancelled = nil
        controller.onFinished = nil
        controller.onFailed = nil
        controller.teardown()
    }
    
    /// Procesa la selección completada por el usuario. El modo continuo solo termina
    /// en `cancelCapture()` o si la captura falla.
    private func handleSelectionCompleted(rect: CGRect, on screen: NSScreen) {
        state = ContinuousCaptureMachine.next(state, on: .selectionCompleted)
        guard state == .processing else { return }
        forceScrollCaptureOnce = false
        
        // Cerrar inmediatamente todas las superposiciones para que no aparezcan en la captura
        dismissOverlays()
        captureGeneration += 1
        let generation = captureGeneration
        // Si la captura se cuelga, el modo no debe quedar vivo sin overlays para siempre
        restartSafetyTimer(after: Self.selectingTimeout)
        
        Task {
            do {
                // Capturar el área seleccionada
                let result = try await ScreenCaptureEngine.shared.captureArea(rect: rect, on: screen)
                
                self.finishCapture(
                    image: result.image,
                    logicalSize: rect.size,
                    rect: rect,
                    screen: screen,
                    generation: generation,
                    notice: nil
                )
            } catch {
                NSLog("[CaptureCoordinator] Error al capturar área: %@", error.localizedDescription)
                // Si ya es otra sesión, no matarla ni abrir una alerta modal que sus overlays taparían
                guard generation == self.captureGeneration else { return }
                // Salir del modo antes de la alerta: un overlay la taparía
                self.cancelCapture()
                self.showErrorAlert(message: error.localizedDescription)
            }
        }
    }
    
    /// Ruta común tras obtener la imagen (captura normal o larga): portapapeles, caché, Tira, HUD y vuelta al selector.
    private func finishCapture(
        image: CGImage,
        logicalSize: CGSize,
        rect: CGRect,
        screen: NSScreen,
        generation: Int,
        notice: String?,
        isLongCapture: Bool = false
    ) {
        // Copiar al portapapeles y reproducir sonido de obturador
        let copied = ClipboardService.shared.copy(
            cgImage: image,
            logicalSize: logicalSize,
            playSound: true
        )
        
        // Guardar en la caché del Strip y colgar la captura con animación de vuelo
        let savedURL = StripManager.shared.saveToCache(cgImage: image)
        if let url = savedURL {
            StripManager.shared.hang(
                url: url,
                cgImage: image,
                fromRect: rect,
                screen: screen,
                isLongCapture: isLongCapture
            )
        }
        
        if copied && savedURL == nil {
            // Solo HUD si no hay tira: con savedURL, la tira + vuelo + sonido ya confirman la captura
            activeHUD?.dismiss()
            let hud = HUDNotificationWindow(
                cgImage: image,
                pixelSize: CGSize(width: image.width, height: image.height),
                fileURL: savedURL
            )
            activeHUD = hud
            hud.present()
        }
        
        if let notice {
            // Aviso modal ANTES de reabrir los overlays: si no, quedaría tapado
            showNotice(message: notice)
        }
        
        // Modo continuo: volver a mostrar los overlays para la siguiente selección
        // (también reinicia el temporizador de inactividad). Si ESC llegó antes, el estado ya es `idle`.
        if state == .processing, generation == captureGeneration {
            state = ContinuousCaptureMachine.next(state, on: .captureFinished)
            presentOverlays()
        }
    }
    
    private func restartSafetyTimer(after interval: TimeInterval) {
        safetyTimer?.invalidate()
        // En `.common` para que no se congele durante el tracking de menús
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                NSLog("[CaptureCoordinator] Temporizador de seguridad: cancelando captura por inactividad.")
                self?.cancelCapture()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }
    
    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
    
    private func dismissOverlays() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        stopScrollPassthrough()
        
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
    }
    
    /// Aviso informativo modal (mismas precauciones que `showErrorAlert`).
    private func showNotice(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: acknowledge"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.runModal()
    }
    
    /// Muestra una alerta de error visible por encima de cualquier ventana.
    /// Es seguro usar runModal() aquí porque los overlays ya están cerrados
    /// y la ventana de la alerta se eleva a nivel flotante para garantizar
    /// visibilidad en apps LSUIElement.
    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Capture Error", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert title: capturing the screen failed")
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: acknowledge"))
        
        // Activar la app para que reciba foco de teclado siendo LSUIElement
        NSApp.activate(ignoringOtherApps: true)
        // Elevar la ventana de la alerta al nivel flotante para que sea visible
        alert.window.level = .floating
        alert.runModal()
    }
}
