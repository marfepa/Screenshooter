import AppKit

/// Panel flotante superior para el Tendedero.
/// Se revela al reposar el cursor en la barra de menús (0,25 s), con el atajo o al colgar una captura,
/// y se retrae cuando el ratón se aleja. La decisión vive en `RevealState`; aquí solo se muestrea el ratón
/// con un timer (un monitor local no recibe eventos de otras apps en una app LSUIElement).
@MainActor
public final class TendederoPanel: NSPanel {
    public let tendederoView: TendederoView
    public var isRevealed: Bool { state.isRevealed }
    
    private let panelHeight: CGFloat = StripMotion.stripHeight
    private var state = RevealState()
    private var tickTimer: Timer?
    private var clickMonitors: [Any] = []
    
    /// Hay capturas en la tira: mantiene vivo el muestreo del ratón aunque esté retraída.
    public var hasItems = false {
        didSet { updateTimer() }
    }
    
    public init(screen: NSScreen) {
        let visible = screen.visibleFrame
        let rect = NSRect(x: visible.minX, y: visible.maxY - panelHeight, width: visible.width, height: panelHeight)
        
        self.tendederoView = TendederoView(frame: NSRect(origin: .zero, size: rect.size))
        
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.becomesKeyOnlyIfNeeded = true
        self.isReleasedWhenClosed = false
        self.contentView = tendederoView
        self.ignoresMouseEvents = true
        
        self.alphaValue = 0.0
        
        watchMenuBarClicks()
    }
    
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    
    /// Detiene timer y monitores y oculta el panel (antes de descartarlo).
    public func tearDown() {
        tickTimer?.invalidate()
        tickTimer = nil
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
        orderOut(nil)
    }
    
    // MARK: - API pública
    
    public func toggle() {
        if isRevealed {
            slideUp()
        } else {
            place(on: screenUnderPointer() ?? screen ?? NSScreen.main ?? NSScreen.screens[0])
            reveal(pinned: true)
        }
    }
    
    /// Revela la tira y evita que se retraiga durante `seconds`.
    public func peek(seconds: TimeInterval) {
        state.peek(until: Date().addingTimeInterval(seconds))
        if !isRevealed { reveal(pinned: false) }
    }
    
    public func reveal(pinned: Bool) {
        if pinned { state.pin() }
        guard !isRevealed else { return }
        state.didReveal()
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
        updateTimer()
    }
    
    public func slideUp() {
        guard isRevealed else { return }
        state.didRetract()
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRevealed else { return }
                self.orderOut(nil)
            }
        })
        updateTimer()
    }
    
    /// Coloca la tira bajo la barra de menús de `screen`.
    public func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let target = NSRect(x: visible.minX, y: visible.maxY - panelHeight, width: visible.width, height: panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
    
    // MARK: - Geometría
    
    /// Franja de la barra de menús de una pantalla.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }
    
    private func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
    
    // MARK: - Muestreo del ratón
    
    private func updateTimer() {
        let needed = hasItems || isRevealed
        if needed, tickTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !needed {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }
    
    private func tick() {
        let mouse = NSEvent.mouseLocation
        let screenUnder = screenUnderPointer()
        let inMenuBar = screenUnder.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        
        var inZone = false
        if isRevealed {
            var zone = frame
            if let s = screen { zone.size.height = s.frame.maxY - zone.minY }
            inZone = NSMouseInRect(mouse, zone, false)
            updateMousePassThrough(mouse)
            if !TendederoCardView.isBusy {
                tendederoView.updateHover(pointer: ignoresMouseEvents ? nil : convertPoint(fromScreen: mouse))
            }
        }
        
        // La consulta de pantalla completa solo hace falta si podría revelarse.
        let fullScreen = (inMenuBar && !isRevealed) ? (screenUnder.map { FullScreen.isActive(on: $0) } ?? false) : false
        let busy = TendederoCardView.isBusy
        
        switch state.tick(now: Date(), inMenuBar: inMenuBar, inZone: inZone, fullScreen: fullScreen, busy: busy) {
        case .reveal:
            if let s = screenUnder { place(on: s) }
            reveal(pinned: false)
        case .retract:
            slideUp()
        case .none:
            break
        }
    }
    
    /// La tira ocupa todo el ancho: solo captura el ratón sobre una tarjeta; el resto de clics pasa a las apps de debajo.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !TendederoCardView.isBusy else { return }
        let local = convertPoint(fromScreen: mouse)
        let overCard = tendederoView.cardHitRects.contains { $0.insetBy(dx: -4, dy: -4).contains(local) }
        if ignoresMouseEvents == overCard { ignoresMouseEvents = !overCard }
    }
    
    /// Un clic en la barra de menús de cualquier pantalla guarda la tira y la suprime hasta salir de la franja.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                if self.state.menuBarClicked() == .retract { self.slideUp() }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
}
