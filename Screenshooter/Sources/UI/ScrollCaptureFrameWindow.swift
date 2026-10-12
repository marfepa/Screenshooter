import AppKit

/// Marco de la captura larga: velo exterior tenue con un hueco en el área y un borde por fuera de ella.
///
/// Panel a pantalla completa NO activador a nivel `.statusBar`. `ignoresMouseEvents = true` desde el init: el gesto
/// de scroll debe llegar a la app de debajo (macOS entrega todo el gesto a la ventana donde empieza; ver Trampas).
/// Puede ser key para recibir Esc / Intro mientras la app esté activa.
@MainActor
final class ScrollCaptureFrameWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    private let frameView: ScrollCaptureFrameView

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        frameView = ScrollCaptureFrameView(holeRect: .zero)
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    convenience init(rect: CGRect, screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Evitar double-free con ARC (ver Trampas del ámbito)
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        frameView.holeRect = NSRect(
            x: rect.origin.x - screen.frame.origin.x,
            y: rect.origin.y - screen.frame.origin.y,
            width: rect.width, height: rect.height
        )
        frameView.frame = NSRect(origin: .zero, size: screen.frame.size)
        frameView.autoresizingMask = [.width, .height]
        frameView.keyHandler = { [weak self] code in self?.handleKey(code) }
        frameView.setAccessibilityElement(false)
        contentView = frameView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Naranja (aviso) o color de acento (normal) para el borde.
    func setWarning(_ warning: Bool) {
        frameView.isWarning = warning
    }

    func present() {
        orderFrontRegardless()
        makeFirstResponder(frameView)
        if NSApp.isActive { makeKey() }
    }

    func dismiss() {
        orderOut(nil)
        close()
    }

    override func keyDown(with event: NSEvent) {
        handleKey(event.keyCode)
    }

    /// Esc (53) → `onEscape`; Intro / Intro numérico (36, 76) → `onReturn`; el resto se consume sin pitido.
    func handleKey(_ keyCode: UInt16) {
        switch keyCode {
        case 53: onEscape?()
        case 36, 76: onReturn?()
        default: break
        }
    }

    // MARK: - Para tests

    var holeRectForTesting: NSRect { frameView.holeRect }
    var isWarningForTesting: Bool { frameView.isWarning }
}

/// Vista que pinta el velo y el borde.
final class ScrollCaptureFrameView: NSView {
    var holeRect: NSRect { didSet { needsDisplay = true } }
    var isWarning = false { didSet { needsDisplay = true } }
    var keyHandler: ((UInt16) -> Void)?

    init(holeRect: NSRect) {
        self.holeRect = holeRect
        super.init(frame: .zero)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func displayOptionsChanged() { needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        keyHandler?(event.keyCode)
    }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let veil = NSBezierPath(rect: bounds)
        veil.append(NSBezierPath(rect: holeRect))
        veil.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(contrast ? 0.5 : 0.28).setFill()
        veil.fill()

        // Borde POR FUERA del área: el trazo se centra a media anchura fuera del rectángulo.
        let width: CGFloat = contrast ? 3 : 2
        let border = NSBezierPath(rect: holeRect.insetBy(dx: -width / 2, dy: -width / 2))
        border.lineWidth = width
        (isWarning ? NSColor.systemOrange : NSColor.controlAccentColor).setStroke()
        border.stroke()
    }
}
