import AppKit

/// Píldora flotante de la captura larga: estado, ayuda, contador de píxeles y botones «Cancel» / «Done».
///
/// Misma familia que `NavigationPillWindow`: panel no activador a nivel `.statusBar`, vidrio, centrada arriba.
/// Los anuncios a VoiceOver los hace el coordinador, no esta ventana.
@MainActor
final class ScrollCapturePillWindow: NSPanel {
    enum Display: Equatable {
        case capturing
        case warnTooFast
        case atEnd
        case limitReached
        case endingSoon(seconds: Int)
        case confirmingCancel
        case stitching
    }

    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onKeepGoing: (() -> Void)?

    private(set) var display: Display = .capturing
    private var keyHintsVisible = false

    private let glass = GlassSurface(shape: .capsule)
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let spinner = NSProgressIndicator()
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)

    private static let topMargin: CGFloat = 12
    private static let minHeight: CGFloat = 36
    private static let dotSize: CGFloat = 9

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
        apply(display: .capturing, pixelHeight: 0)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Contenido

    private func buildContent() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(String(localized: "Long capture", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill title; also VoiceOver label of the pill group"))

        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        dot.setAccessibilityElement(false)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize)
        ])

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byClipping

        hintLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        hintLabel.lineBreakMode = .byClipping

        countLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16)
        ])
        separator.setAccessibilityElement(false)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityElement(false)

        for button in [secondaryButton, primaryButton] {
            button.bezelStyle = .push
            button.controlSize = .large
            button.keyEquivalent = ""
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        secondaryButton.action = #selector(handleSecondary)
        primaryButton.action = #selector(handlePrimary)

        let buttons = NSStackView(views: [secondaryButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [dot, titleLabel, spinner, hintLabel, countLabel, separator, buttons])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 6)
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

    // MARK: - API

    /// Muestra la píldora centrada arriba en el `visibleFrame` de la pantalla dada.
    func present(on screen: NSScreen) {
        guard let root = contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - Self.topMargin - size.height
        )
        setFrame(NSRect(origin: origin, size: size), display: true)

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

    /// Cambia el contenido según el estado y el alto cosido; re-ajusta el tamaño manteniendo el centro.
    func update(display: Display, pixelHeight: Int) {
        apply(display: display, pixelHeight: pixelHeight)
        guard isVisible, let root = contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        guard abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5 else { return }
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Leyendas «esc» / «↩» en los botones: solo útiles si la app está activa y recibe teclado.
    func setKeyHintsVisible(_ visible: Bool) {
        guard visible != keyHintsVisible else { return }
        keyHintsVisible = visible
        refreshButtonTitles()
        guard isVisible, let root = contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = root.fittingSize
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func dismiss() {
        orderOut(nil)
        close()
    }

    // MARK: - Estado

    private struct Content {
        var title: String
        var hint: String?
        var hintIsWarning = false
        var dotColor: NSColor = .systemRed
        var showsCount = true
        var showsSpinner = false
        var secondary: String
        var primary: String
        var secondaryHint: String? = nil
        var primaryHint: String? = "↩"
        var secondaryDestructive = false
        var buttonsEnabled = true
    }

    private var content = Content(title: "", secondary: "", primary: "")

    private func makeContent(for display: Display) -> Content {
        let title = String(localized: "Long capture", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill title; also VoiceOver label of the pill group")
        let cancel = String(localized: "Cancel", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: cancel")
        let done = String(localized: "Done", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill button: finish and stitch the capture")
        var c = Content(title: title, secondary: cancel, primary: done, secondaryHint: "esc")
        switch display {
        case .capturing:
            c.hint = String(localized: "Scroll down", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill hint while capturing: scroll the page down")
        case .warnTooFast:
            c.hint = String(localized: "Slow down: go back up a little", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill warning: scrolling was faster than the capture rate")
            c.hintIsWarning = true
            c.dotColor = .systemOrange
        case .atEnd:
            c.hint = String(localized: "You've reached the end", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill hint: the page seems to have ended")
            c.dotColor = .systemGreen
        case .limitReached:
            c.hint = String(localized: "You've reached the maximum height", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill warning: the maximum image height was reached")
            c.hintIsWarning = true
            c.dotColor = .systemOrange
        case .endingSoon(let seconds):
            c.title = String(localized: "Ending in \(String(seconds)) s", bundle: L10n.bundle, locale: L10n.locale, comment: "Floating pill title shortly before continuous capture ends for inactivity; the argument is a number of seconds")
            c.hint = String(localized: "Scroll down", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill hint while capturing: scroll the page down")
            c.dotColor = .systemOrange
        case .confirmingCancel:
            c.title = String(localized: "Discard the long capture?", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill title asking to confirm cancelling")
            c.hint = String(localized: "What you've captured will be lost.", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill hint in the cancel confirmation")
            c.dotColor = .systemOrange
            c.showsCount = false
            c.secondary = String(localized: "Discard", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill destructive button: throw away what was captured")
            c.primary = String(localized: "Keep going", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill button: dismiss the cancel confirmation and keep capturing")
            c.secondaryHint = nil
            c.secondaryDestructive = true
        case .stitching:
            c.title = String(localized: "Stitching…", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill title while the final image is being composed")
            c.hint = nil
            c.showsCount = false
            c.showsSpinner = true
            c.buttonsEnabled = false
            c.secondaryHint = nil
            c.primaryHint = nil
        }
        return c
    }

    private func apply(display: Display, pixelHeight: Int) {
        self.display = display
        let c = makeContent(for: display)
        content = c

        titleLabel.stringValue = c.title
        hintLabel.stringValue = c.hint ?? ""
        hintLabel.isHidden = c.hint == nil
        if c.hintIsWarning {
            // Con Aumentar contraste el naranja no basta: texto primario.
            hintLabel.textColor = DisplayAccessibility.increaseContrast ? .labelColor : .systemOrange
            hintLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        } else {
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        }

        countLabel.isHidden = !c.showsCount
        countLabel.stringValue = String(localized: "\(String(pixelHeight)) px", bundle: L10n.bundle, locale: L10n.locale, comment: "Long capture pill counter: stitched height in pixels; the argument is a number")

        dot.layer?.backgroundColor = c.dotColor.cgColor
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        spinner.isHidden = !c.showsSpinner
        if c.showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        secondaryButton.isEnabled = c.buttonsEnabled
        primaryButton.isEnabled = c.buttonsEnabled
        secondaryButton.hasDestructiveAction = c.secondaryDestructive
        secondaryButton.bezelColor = c.secondaryDestructive ? .systemRed : nil
        primaryButton.bezelColor = .controlAccentColor
        refreshButtonTitles()
    }

    private func refreshButtonTitles() {
        configure(secondaryButton, title: content.secondary, hint: content.secondaryHint,
                  onColor: content.secondaryDestructive ? .white : .labelColor)
        configure(primaryButton, title: content.primary, hint: content.primaryHint, onColor: .white)
    }

    private func configure(_ button: NSButton, title: String, hint: String?, onColor: NSColor) {
        button.title = title
        button.setAccessibilityLabel(title)
        guard keyHintsVisible, let hint else {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: button === primaryButton ? .semibold : .regular),
                             .foregroundColor: onColor]
            )
            return
        }
        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: button === primaryButton ? .semibold : .regular),
                         .foregroundColor: onColor]
        )
        text.append(NSAttributedString(
            string: "  " + hint,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: onColor.withAlphaComponent(0.8)]
        ))
        button.attributedTitle = text
    }

    // MARK: - Acciones

    @objc private func handleSecondary() {
        if display == .confirmingCancel { onDiscard?() } else { onCancel?() }
    }

    @objc private func handlePrimary() {
        if display == .confirmingCancel { onKeepGoing?() } else { onFinish?() }
    }

    // MARK: - Para tests

    var titleText: String { titleLabel.stringValue }
    var hintText: String? { hintLabel.isHidden ? nil : hintLabel.stringValue }
    var counterText: String? { countLabel.isHidden ? nil : countLabel.stringValue }
    var secondaryButtonTitle: String { secondaryButton.title }
    var primaryButtonTitle: String { primaryButton.title }
    var buttonsAreEnabled: Bool { secondaryButton.isEnabled && primaryButton.isEnabled }
    var secondaryIsDestructive: Bool { secondaryButton.hasDestructiveAction }
    var isShowingSpinner: Bool { !spinner.isHidden }

    func performSecondaryForTesting() { handleSecondary() }
    func performPrimaryForTesting() { handlePrimary() }
}
