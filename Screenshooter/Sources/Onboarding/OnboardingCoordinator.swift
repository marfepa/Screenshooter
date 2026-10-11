import AppKit

/// Presenta la bienvenida inmersiva: una capa por pantalla, navegación entre pasos,
/// permiso de grabación (con reinicio y reanudación) y persistencia de «ya vista».
@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()

    /// Rectángulo del icono de la barra de menús en coordenadas de pantalla (lo aporta `StatusBarController`).
    var statusItemFrame: (() -> NSRect?)?
    var store = OnboardingStore()

    private var windows: [OnboardingOverlayWindow] = []
    private var step: OnboardingStep = .welcome
    private var permissionRequested = false
    private var awaitingSettings = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var suspended = false
    private var captureObserver: NSObjectProtocol?

    var isPresented: Bool { !windows.isEmpty }

    private init() {
        // ⌥⌘S durante la bienvenida: apartarla mientras dure la captura (si no, saldría en la imagen)
        // y devolverla al terminar
        captureObserver = NotificationCenter.default.addObserver(forName: CaptureCoordinator.activeDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setSuspended(CaptureCoordinator.shared.isActive)
            }
        }
    }

    /// Oculta (o recupera) las capas sin cerrar la bienvenida: captura en curso o alerta modal.
    func setSuspended(_ suspend: Bool) {
        guard isPresented, suspend != suspended else { return }
        suspended = suspend
        if suspend {
            for window in windows {
                window.orderOut(nil)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            for window in windows {
                window.orderFrontRegardless()
            }
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Al arrancar: solo la primera vez (o para reanudar tras el reinicio por el permiso).
    func presentAtLaunchIfNeeded() {
        // Un ciclo después: recién lanzada la app, la ventana del icono de la barra de menús aún puede no estar colocada
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.presentAtLaunchNow() }
        }
    }

    private func presentAtLaunchNow() {
        guard OnboardingFlow.shouldShowAtLaunch(seenVersion: store.seenVersion,
                                                resumeStep: store.resumeStep,
                                                isCaptureActive: CaptureCoordinator.shared.isActive) else { return }
        present(reopenedFromMenu: false)
    }

    /// «Cómo funciona…» en el menú, o el arranque.
    func present(reopenedFromMenu: Bool) {
        if CaptureCoordinator.shared.isActive {
            CaptureCoordinator.shared.cancelCapture()
        }
        let resume = store.resumeStep
        store.clearResumeStep()
        // Tras el reinicio el permiso ya se pidió: si sigue faltando, ofrecer reiniciar de nuevo
        permissionRequested = resume != nil
        step = OnboardingFlow.initialStep(resumeStep: resume, reopenedFromMenu: reopenedFromMenu,
                                          permissionGranted: PermissionsHelper.shared.isScreenCaptureGranted)
        if isPresented {
            show(step)
            return
        }
        buildWindows()
        observe()
        show(step)
    }

    func dismiss() {
        store.markSeen()
        tearDown()
        NSApp.deactivate()
    }

    // MARK: - Ventanas

    private var mainScreen: NSScreen? {
        if let frame = validStatusItemFrame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// El marco del icono solo vale si está colocado en alguna pantalla (al arrancar puede ser 0,0).
    private var validStatusItemFrame: NSRect? {
        guard let frame = statusItemFrame?(), frame.width > 0,
              NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
        return frame
    }

    private func buildWindows() {
        let main = mainScreen
        for screen in NSScreen.screens {
            let window = OnboardingOverlayWindow(screen: screen, isMain: screen == main)
            if let controls = window.controls, let root = window.contentView {
                controls.installPauseButton(in: root)
                controls.onSkip = { [weak self] in self?.dismiss() }
                controls.onBack = { [weak self] in self?.goBack() }
                controls.onSecondary = { [weak self] in self?.goForward() }
                controls.onPrimary = { [weak self] in self?.primaryAction() }
                controls.onTogglePause = { [weak self] in self?.togglePause() }
                window.onCancel = { [weak self] in self?.dismiss() }
                window.onArrow = { [weak self] forward in forward ? self?.goForward() : self?.goBack() }
                if let item = validStatusItemFrame {
                    // Pantalla (abajo-izquierda) → vista con origen arriba-izquierda
                    let local = CGRect(x: item.minX - screen.frame.minX,
                                       y: screen.frame.maxY - item.maxY,
                                       width: item.width, height: item.height)
                    window.demoView.statusItemRect = local
                }
            }
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        if let main = mainWindow {
            main.makeKeyAndOrderFront(nil)
            main.makeFirstResponder(main.controls?.primaryButton)
        }
    }

    private var mainWindow: OnboardingOverlayWindow? { windows.first { $0.controls != nil } }

    private func tearDown() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
        suspended = false
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        awaitingSettings = false
    }

    private func observe() {
        let center = NotificationCenter.default
        // Volver de Ajustes del Sistema: recuperar el nivel y el foco
        observers.append((center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnFromSettings() }
        }))
        // Monitor conectado o desconectado: rehacer las capas
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                let current = self.step
                let wasSuspended = self.suspended
                self.tearDown()
                self.buildWindows()
                self.observe()
                self.show(current)
                if wasSuspended { self.setSuspended(true) }
            }
        }))
        // Reducir movimiento / Aumentar contraste cambiados con la bienvenida abierta
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                self.show(self.step)
            }
        }))
    }

    // MARK: - Pasos

    private func show(_ step: OnboardingStep) {
        self.step = step
        for window in windows {
            window.demoView.show(step)
        }
        guard let controls = mainWindow?.controls else { return }
        let granted = PermissionsHelper.shared.isScreenCaptureGranted
        controls.apply(.init(
            step: step,
            primaryTitle: primaryTitle(granted: granted),
            secondaryTitle: (step == .permission && !granted) ? OnboardingText.later : nil,
            permissionGranted: granted,
            permissionRequested: permissionRequested,
            hasAnimation: mainWindow?.demoView.hasRunningAnimations ?? false,
            isPaused: false
        ))
        mainWindow?.contentView?.setAccessibilityLabel(OnboardingText.title(.welcome))
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: OnboardingText.spokenShortcuts(OnboardingText.title(step)),
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    private func primaryTitle(granted: Bool) -> String {
        if step == .permission && !granted {
            return permissionRequested ? OnboardingText.restartNow : OnboardingText.openSettings
        }
        return step.isLast ? OnboardingText.getStarted : OnboardingText.next
    }

    private func goForward() {
        guard let next = step.next else { return }
        show(next)
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        show(previous)
    }

    private func primaryAction() {
        let granted = PermissionsHelper.shared.isScreenCaptureGranted
        if step == .permission && !granted {
            if permissionRequested {
                // TCC solo aplica el permiso al reiniciar: la bienvenida sigue en el paso 3
                store.saveResumeStep(OnboardingFlow.stepAfterPermissionRestart)
                PermissionsHelper.shared.relaunchApp()
            } else {
                openSettings()
            }
            return
        }
        if step.isLast {
            dismiss()
        } else {
            goForward()
        }
    }

    private func togglePause() {
        guard let demo = mainWindow?.demoView else { return }
        // Todas las pantallas a la vez (el velo del paso 4 anima también en las secundarias)
        let pause = !demo.isPaused
        for window in windows where window.demoView.isPaused != pause {
            window.demoView.togglePause()
        }
        mainWindow?.controls?.setPaused(demo.isPaused)
    }

    // MARK: - Permiso

    /// Ajustes del Sistema debe quedar delante: las capas bajan a nivel normal (no se cierran,
    /// así un clic en ellas devuelve al usuario a la bienvenida).
    private func openSettings() {
        permissionRequested = true
        awaitingSettings = true
        PermissionsHelper.shared.requestAccessOnce()
        for window in windows {
            window.level = .normal
        }
        PermissionsHelper.shared.openScreenCaptureSettings()
        show(step)
    }

    private func returnFromSettings() {
        guard awaitingSettings, isPresented else { return }
        awaitingSettings = false
        for window in windows {
            window.level = .statusBar
            window.orderFrontRegardless()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        show(step)
    }
}
