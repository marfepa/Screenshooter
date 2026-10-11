import AppKit

/// Píldora flotante del modo Navegar: indica que la captura continua sigue viva sin overlays
/// («Navegando · ⌥⌘S para capturar · Salir»).
///
/// Panel no activador: un clic en «Salir» no roba el foco a la app de debajo.
/// Se coloca bajo la barra de menús de la pantalla del cursor y acompaña al usuario entre Spaces.
@MainActor
final class NavigationPillWindow: NSPanel {
    var onExit: (() -> Void)?

    private let glass = GlassSurface(shape: .capsule)
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let exitButton = NSButton(title: "", target: nil, action: nil)

    private static let topMargin: CGFloat = 12
    private static let minHeight: CGFloat = 36

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    convenience init() {
        self.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Evitar double-free con ARC (ver Trampas del ámbito)
        isReleasedWhenClosed = false
        buildContent()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func buildContent() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(String(localized: "Navigate mode active", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver label of the floating pill shown while navigating during continuous capture"))

        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = String(localized: "Navigating", bundle: L10n.bundle, locale: L10n.locale, comment: "Floating pill title while the overlays are hidden during continuous capture")

        hintLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = String(localized: "⌥⌘S to capture", bundle: L10n.bundle, locale: L10n.locale, comment: "Floating pill hint: press the shortcut to go back to selecting areas")
        hintLabel.setAccessibilityLabel(String(localized: "Option Command S to capture again", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver reading of the pill shortcut hint"))

        exitButton.title = String(localized: "Exit", bundle: L10n.bundle, locale: L10n.locale, comment: "Floating pill button: end continuous capture")
        exitButton.bezelStyle = .push
        exitButton.controlSize = .large
        exitButton.keyEquivalent = ""
        exitButton.target = self
        exitButton.action = #selector(handleExit)
        exitButton.setAccessibilityLabel(String(localized: "Exit capture mode", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver label of the pill exit button; also the status bar menu item"))

        let stack = NSStackView(views: [titleLabel, hintLabel, exitButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 18, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),
            root.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor)
        ])

        contentView = root
    }

    /// Muestra la píldora bajo la barra de menús de la pantalla en la que está el cursor.
    func present() {
        guard let root = contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - Self.topMargin - size.height
            )
            setFrame(NSRect(origin: origin, size: size), display: true)
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
            orderFrontRegardless()
        } else {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    /// Aviso previo al cierre por inactividad: el título pasa a «Saliendo en 10 s».
    func showTimeoutWarning(seconds: Int) {
        titleLabel.stringValue = String(localized: "Ending in \(String(seconds)) s", bundle: L10n.bundle, locale: L10n.locale, comment: "Floating pill title shortly before continuous capture ends for inactivity; the argument is a number of seconds")
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func dismiss() {
        orderOut(nil)
        close()
    }

    @objc private func handleExit() {
        onExit?()
    }
}
