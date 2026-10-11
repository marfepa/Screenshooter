import AppKit

/// Capa de bienvenida a pantalla completa, sin marco, sobre el escritorio del usuario.
/// Una por pantalla: la principal lleva demostraciones, textos y botones; las demás, solo el velo.
///
/// Nivel `.statusBar`: cubre ventanas, Dock y barra de menús, pero queda por debajo de alertas del sistema,
/// Forzar salida y del overlay de captura (nivel 102), así que ⌥⌘S se puede probar durante la bienvenida.
final class OnboardingOverlayWindow: NSWindow {
    let demoView: OnboardingDemoView
    let controls: OnboardingControlsView?

    /// Esc (vía `cancelOperation`) y flechas ←/→.
    var onCancel: (() -> Void)?
    var onArrow: ((_ forward: Bool) -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        demoView = OnboardingDemoView(frame: NSRect(origin: .zero, size: contentRect.size))
        controls = nil
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    init(screen: NSScreen, isMain: Bool) {
        demoView = OnboardingDemoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        controls = isMain ? OnboardingControlsView() : nil
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Evitar double-free con ARC (ver Trampas del ámbito)
        isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.autoresizingMask = [.width, .height]
        demoView.frame = root.bounds
        demoView.autoresizingMask = [.width, .height]
        demoView.veilOnly = !isMain
        demoView.menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        root.addSubview(demoView)

        if let controls {
            controls.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(controls)
            // Por encima del Dock si lo hay (visibleFrame lo excluye)
            let bottomInset = (screen.visibleFrame.minY - screen.frame.minY) + 40
            NSLayoutConstraint.activate([
                controls.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                controls.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
                controls.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
                controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -bottomInset)
            ])
            root.setAccessibilityElement(true)
            root.setAccessibilityRole(.group)
            root.setAccessibilityLabel(OnboardingText.title(.welcome))
        }
        contentView = root
        autorecalculatesKeyViewLoop = true
    }

    override var canBecomeKey: Bool { controls != nil }
    override var canBecomeMain: Bool { controls != nil }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                   // Esc (por si no llega como cancelOperation)
        case 123: onArrow?(false)              // ←
        case 124: onArrow?(true)               // →
        case 48: super.keyDown(with: event)    // Tab / ⇧Tab: recorrer los botones
        default: break                         // Consumir sin pitido
        }
    }
}

/// Textos y botones de la bienvenida, directamente sobre el velo (sin tarjeta).
final class OnboardingControlsView: NSView {
    var onSkip: (() -> Void)?
    var onBack: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onPrimary: (() -> Void)?
    var onTogglePause: (() -> Void)?

    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusHint = NSTextField(wrappingLabelWithString: "")
    private lazy var statusRow = NSStackView(views: [statusDot, statusLabel])
    private lazy var statusStack = NSStackView(views: [statusRow, statusHint])
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let skipButton = OnboardingButton(title: OnboardingText.skip)
    private let backButton = OnboardingButton(title: OnboardingText.back)
    private let dots = OnboardingDotsView()
    private let secondaryButton = OnboardingButton(title: OnboardingText.later)
    let primaryButton = OnboardingButton(title: OnboardingText.next, primary: true)
    private let pauseButton = OnboardingButton(title: "❚❚")

    init() {
        super.init(frame: .zero)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 10

        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.shadow = shadow
        titleLabel.setAccessibilityRole(.staticText)

        bodyLabel.font = .systemFont(ofSize: 15)
        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        bodyLabel.alignment = .center
        bodyLabel.shadow = shadow

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 6
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([statusDot.widthAnchor.constraint(equalToConstant: 12), statusDot.heightAnchor.constraint(equalToConstant: 12)])
        statusDot.setAccessibilityElement(false)
        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.textColor = .white
        statusHint.font = .systemFont(ofSize: 13)
        statusHint.textColor = NSColor.white.withAlphaComponent(0.8)
        statusHint.alignment = .center
        statusRow.orientation = .horizontal
        statusRow.spacing = 10
        statusStack.orientation = .vertical
        statusStack.spacing = 4

        for (button, action) in [(skipButton, #selector(skip)), (backButton, #selector(back)), (secondaryButton, #selector(secondary)),
                                 (primaryButton, #selector(primary)), (pauseButton, #selector(togglePause))] {
            button.target = self
            button.action = action
        }
        primaryButton.keyEquivalent = "\r"
        pauseButton.setAccessibilityLabel(OnboardingText.pause)

        let buttons = NSStackView(views: [skipButton, backButton, dots, secondaryButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 14
        buttons.setCustomSpacing(18, after: backButton)
        buttons.setCustomSpacing(18, after: dots)

        let stack = NSStackView(views: [statusStack, titleLabel, bodyLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(18, after: statusStack)
        stack.setCustomSpacing(20, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            bodyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            statusHint.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
        titleLabel.preferredMaxLayoutWidth = 600
        bodyLabel.preferredMaxLayoutWidth = 560
        statusHint.preferredMaxLayoutWidth = 480
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// El botón de pausa va en la esquina inferior derecha de la pantalla, no en esta pila.
    func installPauseButton(in root: NSView) {
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pauseButton)
        NSLayoutConstraint.activate([
            pauseButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            pauseButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    struct Model {
        var step: OnboardingStep
        var primaryTitle: String
        var secondaryTitle: String?
        var permissionGranted: Bool
        var permissionRequested: Bool
        var hasAnimation: Bool
        var isPaused: Bool
    }

    func apply(_ model: Model) {
        let step = model.step
        titleLabel.stringValue = OnboardingText.title(step)
        titleLabel.setAccessibilityLabel(OnboardingText.spokenShortcuts(OnboardingText.title(step)))
        bodyLabel.stringValue = OnboardingText.body(step)
        bodyLabel.setAccessibilityLabel(OnboardingText.spokenShortcuts(OnboardingText.body(step)))

        statusStack.isHidden = step != .permission
        statusLabel.stringValue = model.permissionGranted ? OnboardingText.permissionAllowed : OnboardingText.permissionMissing
        statusDot.layer?.backgroundColor = (model.permissionGranted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        statusHint.stringValue = OnboardingText.permissionRestartHint
        statusHint.isHidden = model.permissionGranted || !model.permissionRequested

        backButton.isHidden = step.isFirst
        dots.current = step
        secondaryButton.isHidden = model.secondaryTitle == nil
        secondaryButton.setTitle(model.secondaryTitle ?? "")
        primaryButton.setTitle(model.primaryTitle)
        pauseButton.isHidden = !model.hasAnimation
        setPaused(model.isPaused)
    }

    func setPaused(_ paused: Bool) {
        pauseButton.setTitle(paused ? "▶" : "❚❚")
        pauseButton.setAccessibilityLabel(paused ? OnboardingText.play : OnboardingText.pause)
    }

    @objc private func skip() { onSkip?() }
    @objc private func back() { onBack?() }
    @objc private func secondary() { onSecondary?() }
    @objc private func primary() { onPrimary?() }
    @objc private func togglePause() { onTogglePause?() }
}

/// Botón en cápsula para usar sobre el velo oscuro (blanco relleno si es el principal).
final class OnboardingButton: NSButton {
    private let isPrimary: Bool

    init(title: String, primary: Bool = false) {
        isPrimary = primary
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = primary ? 0 : 1
        focusRingType = .exterior
        setTitle(title)
        refreshStyle()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshStyle),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ text: String) {
        title = text
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isPrimary ? NSColor(white: 0.11, alpha: 1) : NSColor.white
        ])
        invalidateIntrinsicContentSize()
    }

    @objc private func refreshStyle() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = isPrimary ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(contrast ? 1 : 0.35).cgColor
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: max(ceil(text.width) + 32, title.count <= 2 ? 30 : 76), height: 30)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 15, yRadius: 15).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}

/// Puntos de paso: el actual es una píldora más ancha (no depende solo del color).
final class OnboardingDotsView: NSView {
    var current: OnboardingStep = .welcome {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(OnboardingText.stepCounter(current))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(OnboardingStep.allCases.count)
        return NSSize(width: (count - 1) * 7 + 18 + (count - 1) * 7, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let y = (bounds.height - 7) / 2
        for step in OnboardingStep.allCases {
            let width: CGFloat = step == current ? 18 : 7
            let rect = NSRect(x: x, y: y, width: width, height: 7)
            (step == current ? NSColor.white : NSColor.white.withAlphaComponent(0.4)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            x += width + 7
        }
    }
}
