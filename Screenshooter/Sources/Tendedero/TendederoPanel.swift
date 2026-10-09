import AppKit

/// Panel flotante superior tipo cortina/persiana para el Tendedero.
/// Se sitúa bajo la barra de menús en la pantalla activa, se desliza hacia abajo
/// suavemente cuando el cursor se posa en la barra superior o cuando se pulsa el atajo,
/// y se retrae automáticamente cuando el ratón se aleja.
@MainActor
public final class TendederoPanel: NSPanel {
    public let tendederoView: TendederoView
    public private(set) var isRevealed = false
    
    private let panelHeight: CGFloat = 160
    private var hideTimer: Timer?
    private var globalMouseMonitor: Any?
    
    public init(screen: NSScreen) {
        let screenFrame = screen.frame
        let rect = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - panelHeight,
            width: screenFrame.width,
            height: panelHeight
        )
        
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
        
        // Iniciar oculto hacia arriba (fuera de la pantalla)
        self.alphaValue = 0.0
        
        setupMouseMonitoring()
    }
    
    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    /// Monitor de ratón para deslizar automáticamente el tendedero al acercar el cursor a la barra de menús
    private func setupMouseMonitoring() {
        globalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self = self else { return event }
            self.handleMouseMoved(event: event)
            return event
        }
    }
    
    private func handleMouseMoved(event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation
        guard let currentScreen = self.screen ?? NSScreen.main else { return }
        let screenTop = currentScreen.frame.maxY
        
        // Si el ratón está en los primeros 25px superiores (barra de menús)
        if mouseLocation.y >= screenTop - 25 && currentScreen.frame.contains(mouseLocation) {
            cancelHideTimer()
            if !isRevealed {
                slideDown()
            }
        } else if isRevealed {
            // Si el tendedero está desplegado pero el ratón ya bajó bastante por debajo del panel
            let panelBottom = screenTop - panelHeight
            if mouseLocation.y < panelBottom - 40 {
                scheduleHideTimer(delay: 0.8)
            } else {
                cancelHideTimer()
            }
        }
    }
    
    public func toggle() {
        if isRevealed {
            slideUp()
        } else {
            slideDown()
        }
    }
    
    public func slideDown(autoHideDelay: TimeInterval? = nil) {
        cancelHideTimer()
        isRevealed = true
        
        guard let screen = self.screen ?? NSScreen.main else { return }
        let screenFrame = screen.frame
        let targetFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - panelHeight,
            width: screenFrame.width,
            height: panelHeight
        )
        self.setFrame(targetFrame, display: true)
        self.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
        
        if let delay = autoHideDelay {
            scheduleHideTimer(delay: delay)
        }
    }
    
    public func slideUp() {
        cancelHideTimer()
        isRevealed = false
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
    
    private func scheduleHideTimer(delay: TimeInterval) {
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.slideUp()
            }
        }
    }
    
    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
}
