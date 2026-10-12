import AppKit

/// Dueño de una captura larga: sesión de ScreenCaptureKit, cosido, modelo de fases, tres ventanas,
/// monitores de scroll y temporizador. El coordinador solo lo crea, escucha sus tres resultados y aplica
/// los eventos de la máquina de estados. Todo se desmonta en `teardown()`; los callbacks tardíos de una
/// sesión vieja se descartan comparando el `token`.
@MainActor
final class ScrollCaptureController {
    struct Result {
        let image: CGImage
        let rect: CGRect
        let screen: NSScreen
        /// El stream se cortó antes de terminar: es lo capturado hasta ese momento.
        let interrupted: Bool
    }

    /// Ya desmontado todo; el coordinador sale del modo.
    var onCancelled: (() -> Void)?
    /// Ya desmontado todo; el coordinador sigue la ruta normal de una captura terminada.
    var onFinished: ((Result) -> Void)?
    /// Ya desmontado todo; el coordinador sale del modo y muestra la alerta de error.
    var onFailed: ((Error) -> Void)?

    private let rect: CGRect
    private let screen: NSScreen
    private let announce: (String) -> Void

    private var token = 0
    private var isRunning = false
    private var isFinishing = false
    private var model = ScrollCaptureModel(startedAt: ProcessInfo.processInfo.systemUptime)
    private var pixelHeight = 0
    private var shownDisplay: ScrollCapturePillWindow.Display?
    private var shownHeight = -1

    private var session: ScrollCaptureSession?
    private var frameWindow: ScrollCaptureFrameWindow?
    private var pillWindow: ScrollCapturePillWindow?
    private var previewWindow: ScrollCapturePreviewWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var stitchingPillTask: Task<Void, Never>?
    private let stitchState = StitchState()
    private let stitchQueue = DispatchQueue(label: "com.marfepa.Screenshooter.scroll.stitch", qos: .userInitiated)

    init(rect: CGRect, screen: NSScreen, announce: @escaping (String) -> Void) {
        self.rect = rect
        self.screen = screen
        self.announce = announce
    }

    // MARK: - Inicio

    func start() {
        guard !isRunning else { return }
        isRunning = true
        token += 1
        let current = token
        let now = ProcessInfo.processInfo.systemUptime
        model = ScrollCaptureModel(startedAt: now)

        let frame = ScrollCaptureFrameWindow(rect: rect, screen: screen)
        frame.onEscape = { [weak self] in self?.escapePressed() }
        frame.onReturn = { [weak self] in self?.returnPressed() }
        let pill = ScrollCapturePillWindow()
        pill.onCancel = { [weak self] in self?.requestCancel() }
        pill.onFinish = { [weak self] in self?.finish(interrupted: false) }
        pill.onDiscard = { [weak self] in self?.discard() }
        pill.onKeepGoing = { [weak self] in self?.keepGoing() }
        let preview = ScrollCapturePreviewWindow(rect: rect, screen: screen)
        frameWindow = frame
        pillWindow = pill
        previewWindow = preview

        pill.present(on: screen)
        if preview.isPlaceable { preview.present() }
        // Activar la app y hacer key el marco para que Intro y Esc lleguen
        NSApp.activate(ignoringOtherApps: true)
        frame.present()
        frame.makeKeyAndOrderFront(nil)
        pill.setKeyHintsVisible(NSApp.isActive)
        refreshPill(force: true)

        installMonitors()
        installTimer()
        installActiveObservers()

        let state = stitchState
        let stitchQueue = stitchQueue
        let newSession = ScrollCaptureSession(
            rect: rect,
            screen: screen,
            onFrame: { [weak self] image in
                // `sync` sobre la cola de cosido: si vamos lentos, la sesión sigue descartando fotogramas
                let box = UncheckedBox(image)
                let result = stitchQueue.sync {
                    state.process(box.value, now: ProcessInfo.processInfo.systemUptime)
                }
                Task { @MainActor in self?.handle(result, token: current) }
            },
            onStop: { [weak self] error in
                self?.streamStopped(error: error, token: current)
            }
        )
        session = newSession

        announce(String(localized: "Long capture. Scroll down; Return to finish, Escape to cancel.", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when the long capture starts"))

        Task { @MainActor [weak self] in
            do {
                try await newSession.start()
                if self?.token != current { await newSession.stop() }
            } catch {
                guard let self, self.token == current else { return }
                self.fail(error)
            }
        }
    }

    // MARK: - Fotogramas

    private func handle(_ result: StitchState.Result, token current: Int) {
        guard current == token, isRunning, !isFinishing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pixelHeight = result.height
        if let outcome = result.outcome {
            model.apply(outcome, at: now)
        }
        if let preview = result.preview {
            previewWindow?.update(preview: preview.value)
        }
        let phase = model.phase
        frameWindow?.setWarning(phase == .warnTooFast || phase == .limitReached)
        refreshPill(force: false)
        if phase == .limitReached, let session {
            // No hacen falta más fotogramas
            Task { await session.stop() }
        }
    }

    private func streamStopped(error: Error?, token current: Int) {
        guard let error, current == token, isRunning, !isFinishing else { return }
        NSLog("[ScrollCapture] El stream se detuvo: %@", error.localizedDescription)
        // Con al menos un fotograma cosido se guarda lo que haya; solo sin ninguno es un error
        let state = stitchState
        let hasFrames = stitchQueue.sync { state.hasFrames }
        if hasFrames {
            finish(interrupted: true)
        } else {
            fail(error)
        }
    }

    // MARK: - Píldora

    private func display(at now: TimeInterval) -> ScrollCapturePillWindow.Display? {
        switch model.phase {
        case .stitching: return nil
        case .confirmingCancel: return .confirmingCancel
        case .limitReached: return .limitReached
        case .atEnd, .capturing, .warnTooFast:
            if case .warning(let seconds) = model.inactivity(at: now) { return .endingSoon(seconds: seconds) }
            switch model.phase {
            case .atEnd: return .atEnd
            case .warnTooFast: return .warnTooFast
            default: return .capturing
            }
        }
    }

    private func refreshPill(force: Bool) {
        guard let next = display(at: ProcessInfo.processInfo.systemUptime) else { return }
        guard force || next != shownDisplay || pixelHeight != shownHeight else { return }
        if next != shownDisplay { announceChange(to: next) }
        shownDisplay = next
        shownHeight = pixelHeight
        pillWindow?.update(display: next, pixelHeight: pixelHeight)
    }

    /// Los avisos se anuncian una vez al aparecer; el progreso del contador no se anuncia.
    private func announceChange(to display: ScrollCapturePillWindow.Display) {
        switch display {
        case .warnTooFast:
            announce(String(localized: "Slow down: go back up a little", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill warning: scrolling was faster than the capture rate"))
        case .atEnd:
            announce(String(localized: "You've reached the end", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill hint: the page seems to have ended"))
        case .limitReached:
            announce(String(localized: "You've reached the maximum height", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill warning: the maximum image height was reached"))
        case .confirmingCancel:
            announce(String(localized: "Discard the long capture?", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill title asking to confirm cancelling"))
        case .capturing, .endingSoon, .stitching:
            break
        }
    }

    // MARK: - Monitores y temporizador

    private func installMonitors() {
        let handler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let delta = event.scrollingDeltaY
            let pointer = NSEvent.mouseLocation
            Task { @MainActor in self?.noteScroll(deltaY: delta, pointer: pointer) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func noteScroll(deltaY: CGFloat, pointer: CGPoint) {
        guard isRunning, !isFinishing, deltaY != 0, rect.contains(pointer) else { return }
        model.noteScrollAttempt(towardEnd: deltaY < 0, at: ProcessInfo.processInfo.systemUptime)
    }

    private func installTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // En `.common` para que no se congele durante el tracking de menús
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isRunning, !isFinishing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        model.tick(at: now)
        if model.phase != .confirmingCancel, model.inactivity(at: now) == .expired {
            finish(interrupted: false)
            return
        }
        refreshPill(force: false)
    }

    private func installActiveObservers() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pillWindow?.setKeyHintsVisible(NSApp.isActive) }
            }
            observers.append(observer)
        }
    }

    // MARK: - Acciones del usuario

    private func escapePressed() {
        guard isRunning, !isFinishing else { return }
        if model.phase == .confirmingCancel { keepGoing() } else { requestCancel() }
    }

    private func returnPressed() {
        guard isRunning, !isFinishing else { return }
        if model.phase == .confirmingCancel { keepGoing() } else { finish(interrupted: false) }
    }

    private func requestCancel() {
        guard isRunning, !isFinishing else { return }
        switch model.requestCancel() {
        case .cancelNow:
            discard()
        case .askConfirmation:
            refreshPill(force: true)
        }
    }

    private func keepGoing() {
        guard isRunning, !isFinishing else { return }
        model.dismissCancel()
        refreshPill(force: true)
    }

    private func discard() {
        guard isRunning, !isFinishing else { return }
        teardown()
        onCancelled?()
    }

    private func fail(_ error: Error) {
        guard isRunning else { return }
        teardown()
        onFailed?(error)
    }

    /// Termina guardando: «Hecho», Intro, inactividad o stream cortado con algo capturado.
    func finish(interrupted: Bool) {
        guard isRunning, !isFinishing else { return }
        isFinishing = true
        model.beginStitching()
        let current = token
        let state = stitchState
        let stitchQueue = stitchQueue
        let session = session

        // Solo se enseña «Cosiendo…» si tarda
        stitchingPillTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.token == current else { return }
            self.pillWindow?.update(display: .stitching, pixelHeight: self.pixelHeight)
        }

        Task { @MainActor [weak self] in
            await session?.stop()
            let box: UncheckedBox<CGImage?> = await withCheckedContinuation { continuation in
                stitchQueue.async {
                    continuation.resume(returning: UncheckedBox(state.finalImage()))
                }
            }
            guard let self, self.token == current else { return }
            let rect = self.rect, screen = self.screen
            self.teardown()
            if let image = box.value {
                self.onFinished?(Result(image: image, rect: rect, screen: screen, interrupted: interrupted))
                return
            }
            // Ningún fotograma llegó (p. ej. Intro en los primeros ms): captura normal del área, con las
            // ventanas propias ya cerradas por `teardown()`
            do {
                try? await Task.sleep(nanoseconds: 120_000_000) // deja que el compositor retire las ventanas
                let fallback = try await ScreenCaptureEngine.shared.captureArea(rect: rect, on: screen)
                self.onFinished?(Result(image: fallback.image, rect: rect, screen: screen, interrupted: false))
            } catch {
                self.onFailed?(error)
            }
        }
    }

    // MARK: - Desmontaje

    /// Para la sesión, quita monitores y temporizador y cierra las tres ventanas. Idempotente.
    func teardown() {
        token += 1
        isRunning = false
        isFinishing = false
        stitchingPillTask?.cancel()
        stitchingPillTask = nil
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let session {
            Task { await session.stop() }
        }
        session = nil
        frameWindow?.onEscape = nil
        frameWindow?.onReturn = nil
        frameWindow?.dismiss()
        frameWindow = nil
        pillWindow?.dismiss()
        pillWindow = nil
        previewWindow?.dismiss()
        previewWindow = nil
    }
}

/// Envoltorio para cruzar colas con tipos de Core Graphics que no son `Sendable`.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Estado del cosido. Solo se toca desde `stitchQueue` (serie): `ScrollStitcher` no es thread-safe.
final class StitchState: @unchecked Sendable {
    struct Result: @unchecked Sendable {
        var outcome: ScrollStitcher.Outcome?
        var height: Int
        var preview: UncheckedBox<CGImage>?
    }

    private static let previewInterval: TimeInterval = 0.25
    private var stitcher: ScrollStitcher?
    private var lastPreviewAt: TimeInterval = 0
    private var appendedSincePreview = false
    private var isFinal = false

    /// Ya hay al menos un fotograma cosido (leer desde `stitchQueue`).
    var hasFrames: Bool { stitcher != nil }

    func process(_ frame: CGImage, now: TimeInterval) -> Result {
        guard !isFinal else { return Result(outcome: nil, height: stitcher?.height ?? 0, preview: nil) }
        var outcome: ScrollStitcher.Outcome?
        if let stitcher {
            let value = stitcher.add(frame)
            outcome = value
            if case .appended = value { appendedSincePreview = true }
        } else {
            stitcher = ScrollStitcher(firstFrame: frame)
            appendedSincePreview = true
        }
        var preview: UncheckedBox<CGImage>?
        if appendedSincePreview, now - lastPreviewAt >= Self.previewInterval,
           let image = stitcher?.makePreview(maxWidth: 220) {
            preview = UncheckedBox(image)
            lastPreviewAt = now
            appendedSincePreview = false
        }
        return Result(outcome: outcome, height: stitcher?.height ?? 0, preview: preview)
    }

    /// Cierra el cosido (no admite más fotogramas) y devuelve la imagen completa.
    func finalImage() -> CGImage? {
        isFinal = true
        return stitcher?.makeImage()
    }
}
