import AppKit
import UniformTypeIdentifiers

@MainActor
public protocol TendederoCardViewDelegate: AnyObject {
    /// Devuelve `false` si no se pudo copiar al portapapeles.
    func cardDidRequestCopy(_ card: TendederoCardView, item: TendederoItem) -> Bool
    func cardDidRequestMarkup(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestPreview(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestShowInFinder(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestDismiss(_ card: TendederoCardView, item: TendederoItem)
    /// El archivo ya no existe: quitar de la tira sin tocar la Papelera.
    func cardDidRequestRemoveMissing(_ card: TendederoCardView, item: TendederoItem)
    func cardDidEndDrag(_ card: TendederoCardView, item: TendederoItem, operation: NSDragOperation)
    func cardDidRequestFocusMove(_ card: TendederoCardView, to target: TendederoCardView.FocusTarget)
    func cardDidRequestEscape(_ card: TendederoCardView)
}

// MARK: - Vidrio

/// Superficie de vidrio: `NSVisualEffectView` `.popover` con borde interior de 0,5 pt y brillo superior de 1 pt.
/// Respeta Reducir transparencia (fondo sólido `windowBackgroundColor`) y Aumentar contraste (borde de 1 pt `labelColor`).
///
/// `blendingMode = .behindWindow`: en un panel transparente `.withinWindow` solo mezcla el contenido de la propia
/// ventana (vacío) y no desenfoca nada; `.behindWindow` muestra el escritorio y las ventanas de detrás.
/// `state = .active` evita que el vidrio se vea apagado cuando el panel no es key.
final class GlassSurface: NSView {
    enum Shape: Equatable {
        case rounded(CGFloat)
        case capsule
        case circle
    }

    let shape: Shape
    private let effect = NSVisualEffectView()
    private let edgeHost = NSView()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let highlightMask = CAGradientLayer()
    private static var maskCache: [CGFloat: NSImage] = [:]

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)

        edgeHost.wantsLayer = true
        addSubview(edgeHost)
        for shapeLayer in [borderLayer, highlightLayer] {
            shapeLayer.fillColor = nil
            edgeHost.layer?.addSublayer(shapeLayer)
        }
        highlightMask.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        highlightLayer.mask = highlightMask

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var cornerRadius: CGFloat {
        switch shape {
        case .rounded(let r): return r
        case .capsule: return bounds.height / 2
        case .circle: return min(bounds.width, bounds.height) / 2
        }
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        edgeHost.frame = bounds
        effect.maskImage = Self.maskImage(radius: cornerRadius)
        refreshStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }

    @objc private func displayOptionsChanged() { refreshStyle() }

    private static func maskImage(radius r: CGFloat) -> NSImage {
        if let cached = maskCache[r] { return cached }
        let side = r * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        maskCache[r] = image
        return image
    }

    /// Reaplica colores y trazos según apariencia y preferencias de accesibilidad.
    func refreshStyle() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let solid = DisplayAccessibility.reduceTransparency
        let contrast = DisplayAccessibility.increaseContrast
        let r = cornerRadius
        let borderWidth: CGFloat = contrast ? 1 : 0.5
        effect.isHidden = solid

        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = r
            layer?.backgroundColor = solid ? NSColor.windowBackgroundColor.cgColor : nil

            borderLayer.frame = bounds
            borderLayer.lineWidth = borderWidth
            borderLayer.path = CGPath(
                roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                cornerWidth: max(0, r - borderWidth / 2), cornerHeight: max(0, r - borderWidth / 2), transform: nil
            )
            borderLayer.strokeColor = contrast
                ? NSColor.labelColor.cgColor
                : NSColor.white.withAlphaComponent(isDark ? 0.22 : 0.75).cgColor

            let showHighlight = !contrast && !solid && bounds.height > 0
            highlightLayer.isHidden = !showHighlight
            highlightLayer.frame = bounds
            highlightLayer.lineWidth = 1
            highlightLayer.path = CGPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: max(0, r - 0.5), cornerHeight: max(0, r - 0.5), transform: nil
            )
            highlightLayer.strokeColor = NSColor.white.withAlphaComponent(isDark ? 0.10 : 0.55).cgColor
            highlightMask.frame = bounds
            highlightMask.startPoint = CGPoint(x: 0.5, y: 1)
            highlightMask.endPoint = CGPoint(x: 0.5, y: max(0, 1 - 12 / max(bounds.height, 1)))
        }
    }
}

/// Botón circular de vidrio de 24 pt visuales con área de clic de 32 pt.
final class CircleGlassButton: NSView {
    static let hitSize: CGFloat = 32
    static let visualSize: CGFloat = 24

    var onClick: (() -> Void)?
    private let glass = GlassSurface(shape: .circle)
    private let icon = NSImageView()
    private var isDown = false

    init(symbol: String, label: String) {
        let side = Self.hitSize
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        let inset = (side - Self.visualSize) / 2
        glass.frame = NSRect(x: inset, y: inset, width: Self.visualSize, height: Self.visualSize)
        addSubview(glass)

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleNone
        icon.frame = glass.frame
        addSubview(icon)

        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDown = true
        glass.alphaValue = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        glass.alphaValue = 1
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        defer { isDown = false }
        if isDown && inside { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Cápsula de vidrio con texto (y símbolo opcional) en `labelColor`.
final class GlassCapsuleLabel: NSView {
    private let glass = GlassSurface(shape: .capsule)
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let font: NSFont
    private let height: CGFloat
    private let horizontalPadding: CGFloat

    init(font: NSFont, height: CGFloat, horizontalPadding: CGFloat) {
        self.font = font
        self.height = height
        self.horizontalPadding = horizontalPadding
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glass)
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        label.backgroundColor = .clear
        addSubview(label)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleNone
        icon.isHidden = true
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(text: String, symbol: String? = nil) {
        label.stringValue = text
        label.sizeToFit()
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .semibold)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        let iconW: CGFloat = symbol == nil ? 0 : 16
        let width = ceil(label.frame.width) + iconW + horizontalPadding * 2
        setFrameSize(NSSize(width: width, height: height))
        needsLayout = true
        layout()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let iconW: CGFloat = icon.isHidden ? 0 : 16
        let textY = (bounds.height - label.frame.height) / 2
        icon.frame = NSRect(x: horizontalPadding - 2, y: 0, width: 14, height: bounds.height)
        label.setFrameOrigin(NSPoint(x: horizontalPadding + iconW, y: textY))
    }
}

// MARK: - Tarjeta

/// Tarjeta de vidrio de una captura colgada de la cuerda.
/// Soporta arrastre (Drag & Drop), clic (copiar), doble clic (Vista Previa), mantener (Marcación),
/// botones ✕ y lápiz al pasar el puntero y cápsula con hora y tamaño.
public final class TendederoCardView: NSView, NSDraggingSource, NSMenuDelegate {
    public weak var delegate: TendederoCardViewDelegate?
    public private(set) var item: TendederoItem

    public static let defaultWidth: CGFloat = StripMotion.slotSize.width
    public static let defaultHeight: CGFloat = StripMotion.slotSize.height

    // Jerarquía: swingView (balanceo) > cardBody (inclinación/escala) > glass + miniatura + avisos.
    private let swingView = NSView()
    private let cardBody = NSView()
    private let glass = GlassSurface(shape: .rounded(10))
    private let imageView = NSImageView()
    private let missingLabel = NSTextField(labelWithString: "Archivo no encontrado")
    private let badge = GlassCapsuleLabel(font: .systemFont(ofSize: 12, weight: .semibold), height: 24, horizontalPadding: 11)
    private let meta = GlassCapsuleLabel(font: .systemFont(ofSize: 11, weight: .medium), height: 18, horizontalPadding: 8)
    private let peg = GlassSurface(shape: .rounded(3))
    private let pressRing = NSView()
    private let closeButton = CircleGlassButton(symbol: "xmark", label: "Mover a la Papelera")
    private let actionButton = CircleGlassButton(symbol: "pencil.tip", label: "Abrir en Marcación")
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()

    private var mouseDownLocation: CGPoint = .zero
    private var isDraggingSession = false
    private var didTriggerLongPress = false
    private var suppressNextMouseUp = false
    private var longPressTimer: Timer?
    private var badgeWorkItem: DispatchWorkItem?

    public enum FocusTarget { case previous, next, first, last }

    public private(set) var isHovered = false
    /// La tarjeta tiene el foco de teclado (la tira es key por petición del usuario).
    public private(set) var isKeyboardFocused = false
    /// Única parada de Tab de la tira (tabulación "roving"); las flechas mueven el foco entre tarjetas.
    var isRovingStop = false
    public private(set) var isMissing = false
    private var isPressed = false
    /// La tarjeta está cayendo/desapareciendo: ya no recibe eventos.
    private(set) var isLeaving = false

    private static var pressActive = false
    private static var menuOpen = false

    /// `true` mientras hay una pulsación, un arrastre o un menú contextual abierto sobre alguna tarjeta
    /// (el panel no debe retraerse ni cambiar el paso de clics).
    public static var isBusy: Bool { pressActive || menuOpen }

    public init(item: TendederoItem) {
        self.item = item
        super.init(frame: NSRect(origin: .zero, size: StripMotion.slotSize))
        wantsLayer = true
        focusRingType = .exterior
        setupLayout()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refreshMissingState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Geometría

    /// Rectángulo de la tarjeta dentro de la ranura (origen abajo-izquierda).
    var cardRect: NSRect {
        NSRect(x: 0, y: bounds.height - StripMotion.cardTopInset - StripMotion.cardSize.height,
               width: StripMotion.cardSize.width, height: StripMotion.cardSize.height)
    }

    /// Zona sensible de la tarjeta (sin la cápsula de hora, que no recibe clics).
    var hitRect: NSRect { cardRect }

    /// Miniatura (ajustada a la proporción de la captura) en coordenadas de la ranura.
    var thumbnailRect: NSRect {
        convert(imageView.frame, from: cardBody)
    }

    private var cardPivot: CGPoint { CGPoint(x: 0, y: StripMotion.cardSize.height / 2) }
    private var swingPivot: CGPoint { CGPoint(x: 0, y: StripMotion.slotSize.height / 2 - 2) }

    // MARK: Montaje

    private func setupLayout() {
        swingView.frame = bounds
        swingView.wantsLayer = true
        addSubview(swingView)

        cardBody.frame = cardRect
        cardBody.wantsLayer = true
        swingView.addSubview(cardBody)

        // Sombra exterior (no se ve a través del vidrio: se recorta el interior de la tarjeta).
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.mask = shadowMask
        shadowMask.fillRule = .evenOdd
        cardBody.layer?.insertSublayer(shadowLayer, at: 0)

        glass.frame = cardBody.bounds
        cardBody.addSubview(glass)

        imageView.wantsLayer = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        cardBody.addSubview(imageView)
        layoutThumbnail()

        missingLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        missingLabel.textColor = .labelColor
        missingLabel.alignment = .center
        missingLabel.maximumNumberOfLines = 2
        missingLabel.frame = cardBody.bounds.insetBy(dx: 8, dy: 36)
        missingLabel.isHidden = true
        cardBody.addSubview(missingLabel)

        badge.isHidden = true
        badge.alphaValue = 0
        cardBody.addSubview(badge)

        pressRing.frame = cardRect.insetBy(dx: -3, dy: -3)
        pressRing.wantsLayer = true
        pressRing.layer?.cornerRadius = 13
        pressRing.layer?.borderWidth = 2
        pressRing.alphaValue = 0
        swingView.addSubview(pressRing)

        peg.frame = NSRect(x: (bounds.width - 8) / 2, y: bounds.height - 14, width: 8, height: 14)
        swingView.addSubview(peg)

        // ✕ arriba-izquierda y lápiz arriba-derecha, dentro de la tarjeta (5 pt de margen visual).
        let side = CircleGlassButton.hitSize
        let centerY = cardRect.maxY - 5 - CircleGlassButton.visualSize / 2
        closeButton.setFrameOrigin(NSPoint(x: 5 + CircleGlassButton.visualSize / 2 - side / 2, y: centerY - side / 2))
        actionButton.setFrameOrigin(NSPoint(x: bounds.width - 5 - CircleGlassButton.visualSize / 2 - side / 2, y: centerY - side / 2))
        closeButton.onClick = { [weak self] in self?.perform(.trash) }
        actionButton.onClick = { [weak self] in self?.perform(.markup) }
        for b in [closeButton, actionButton] {
            b.isHidden = true
            b.alphaValue = 0
            swingView.addSubview(b)
        }

        meta.set(text: StripMotion.metaText(for: item))
        meta.setFrameOrigin(NSPoint(x: (bounds.width - meta.frame.width) / 2, y: bounds.height - 118 - meta.frame.height))
        meta.isHidden = true
        meta.alphaValue = 0
        addSubview(meta)

        imageView.image = item.image
        updateShadowGeometry()
        applyState(animated: false)
        refreshColors()
    }

    private func layoutThumbnail() {
        let area = cardBody.bounds.insetBy(dx: StripMotion.thumbnailPadding, dy: StripMotion.thumbnailPadding)
        imageView.frame = StripMotion.aspectFit(imageSize: item.image.size, in: area)
    }

    private func updateShadowGeometry() {
        let b = cardBody.bounds
        let rounded = CGPath(roundedRect: b, cornerWidth: 10, cornerHeight: 10, transform: nil)
        shadowLayer.frame = b
        shadowLayer.shadowPath = rounded
        let outer = CGMutablePath()
        outer.addRect(b.insetBy(dx: -80, dy: -80))
        outer.addPath(rounded)
        shadowMask.frame = shadowLayer.bounds
        shadowMask.path = outer
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pressRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
            peg.layer?.shadowColor = NSColor.black.cgColor
        }
    }

    // MARK: Datos

    public func updateItem(_ newItem: TendederoItem) {
        item = newItem
        imageView.image = newItem.image
        layoutThumbnail()
        meta.set(text: StripMotion.metaText(for: newItem))
        meta.setFrameOrigin(NSPoint(x: (bounds.width - meta.frame.width) / 2, y: bounds.height - 118 - meta.frame.height))
        applyState()
        refreshMissingState()
    }

    /// Comprueba que el archivo siga existiendo y atenúa la tarjeta si no.
    @discardableResult
    public func refreshMissingState() -> Bool {
        let missing = !FileManager.default.fileExists(atPath: item.url.path)
        isMissing = missing
        imageView.alphaValue = missing ? 0.35 : 1
        imageView.contentFilters = missing
            ? [CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.0])].compactMap { $0 }
            : []
        missingLabel.isHidden = !missing
        applyState()
        updateAccessibility()
        return missing
    }

    // MARK: Accesibilidad

    private var position: (index: Int, count: Int) = (0, 1)

    /// Posición en la lista ("2 de 8") para VoiceOver.
    func setPosition(index: Int, count: Int) {
        position = (index, count)
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel(StripMotion.accessibilityLabel(for: item, missing: isMissing))
        setAccessibilityHelp(isMissing ? "Clic para quitar de la tira" : "Clic para copiar. Mantener para Marcación")
        setAccessibilityIndex(position.index)
        setAccessibilityValueDescription(StripMotion.positionText(index: position.index, count: position.count))
        func action(_ name: String, _ a: Action) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.perform(a)
                return true
            }
        }
        setAccessibilityCustomActions(isMissing
            ? [action("Quitar de la tira", .trash)]
            : [action("Abrir con Marcación", .markup), action("Abrir en Vista Previa", .preview),
               action("Mostrar en Finder", .finder), action("Mover a la Papelera", .trash)])
    }

    public override func accessibilityPerformPress() -> Bool {
        perform(.copy)
        return true
    }

    public override func accessibilityPerformShowMenu() -> Bool {
        showContextMenuFromKeyboard()
        return true
    }

    // MARK: Teclado y foco

    public override var acceptsFirstResponder: Bool { window?.canBecomeKey == true && !isLeaving }
    public override var canBecomeKeyView: Bool { isRovingStop }

    public override func becomeFirstResponder() -> Bool {
        isKeyboardFocused = true
        applyState()
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        isKeyboardFocused = false
        applyState()
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    public override var focusRingMaskBounds: NSRect { cardRect }

    public override func drawFocusRingMask() {
        NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10).fill()
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.specialKey {
        case .leftArrow?: delegate?.cardDidRequestFocusMove(self, to: .previous)
        case .rightArrow?: delegate?.cardDidRequestFocusMove(self, to: .next)
        case .home?: delegate?.cardDidRequestFocusMove(self, to: .first)
        case .end?: delegate?.cardDidRequestFocusMove(self, to: .last)
        case .carriageReturn?, .enter?: perform(.copy)
        case .deleteForward?: perform(.trash)
        case .menu?: showContextMenuFromKeyboard()
        case .f10? where flags.contains(.shift): showContextMenuFromKeyboard()
        case .tab?: window?.selectNextKeyView(nil)
        case .backTab?: window?.selectPreviousKeyView(nil)
        default:
            if event.keyCode == 53 { // Esc
                delegate?.cardDidRequestEscape(self)
            } else if flags.isEmpty || flags == .shift {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case " ": perform(.copy)
                case "m": perform(.markup)
                default: break // Se consume en silencio (sin NSBeep).
                }
            }
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "o": perform(.preview)
        case "c": perform(.copy)
        case "\u{7f}": perform(.trash) // ⌘⌫
        default: return false
        }
        return true
    }

    /// ⇧F10 / tecla de menú: abre el menú contextual junto a la tarjeta.
    func showContextMenuFromKeyboard() {
        makeContextMenu().popUp(positioning: nil, at: NSPoint(x: cardRect.midX, y: cardRect.minY + 40), in: self)
    }

    // MARK: Estado visual

    public func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyState()
    }

    private var showsControls: Bool { (isHovered || isKeyboardFocused) && !isDraggingSession && !isLeaving }

    private func applyState(animated: Bool = true) {
        let motion = MotionStyle.current()
        let animate = animated && window?.isVisible == true
        let scale: CGFloat = isPressed ? motion.pressScale : (showsControls ? motion.hoverScale : 1)
        let target = StripMotion.cardTransform(tilt: item.tilt, scale: scale, pivotOffset: cardPivot)

        // Una sola transformación (inclinación + escala): sin saltos al entrar/salir el puntero.
        if let layer = cardBody.layer, !CATransform3DEqualToTransform(layer.transform, target) {
            if animate {
                if isPressed {
                    layer.animateValue("transform", to: NSValue(caTransform3D: target), duration: motion.pressDuration, key: "state")
                } else {
                    layer.animateValue("transform", to: NSValue(caTransform3D: target), spring: motion.hoverSpring,
                                       duration: 0.3, key: "state")
                }
            } else {
                layer.removeAnimation(forKey: "state")
                layer.transform = target
            }
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animate ? motion.fadeDuration : 0)
        CATransaction.setDisableActions(!animate)
        shadowLayer.shadowRadius = showsControls ? 14 : 8
        shadowLayer.shadowOpacity = showsControls ? 0.26 : 0.18
        shadowLayer.shadowOffset = CGSize(width: 0, height: showsControls ? -7 : -4)
        CATransaction.commit()

        setControl(closeButton, visible: showsControls, animate: animate, scaled: true)
        setControl(actionButton, visible: showsControls && !isMissing, animate: animate, scaled: true)
        setControl(meta, visible: showsControls, animate: animate, scaled: false)
        setAlpha(pressRing, to: isPressed ? 0.9 : 0, animate: animate)
        setAlpha(cardBody, to: isDraggingSession ? 0.35 : 1, animate: animate)
    }

    private func setAlpha(_ view: NSView, to alpha: CGFloat, animate: Bool, completion: (() -> Void)? = nil) {
        guard animate else {
            view.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            view.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    private func setControl(_ view: NSView, visible: Bool, animate: Bool, scaled: Bool) {
        let motion = MotionStyle.current()
        if visible { view.isHidden = false }
        setAlpha(view, to: visible ? 1 : 0, animate: animate) {
            if !visible && view.alphaValue == 0 { view.isHidden = true }
        }
        if scaled, !motion.reduceMotion, let layer = view.layer {
            let target = visible ? CATransform3DIdentity : CATransform3DMakeScale(0.6, 0.6, 1)
            if animate {
                layer.animateValue("transform", to: NSValue(caTransform3D: target), duration: 0.18, key: "scale")
            } else {
                layer.transform = target
            }
        }
    }

    // MARK: Movimiento

    /// Cuando una captura en vuelo aterriza o una nueva llega: cae con muelle y se balancea hasta parar.
    public func playArrival(drop: Bool) {
        let motion = MotionStyle.current()
        guard let layer else { return }
        if motion.reduceMotion {
            layer.animateValue("opacity", to: 1.0, from: 0.0, duration: motion.fadeDuration, key: "arrival")
            return
        }
        if drop, let spring = motion.arrivalSpring {
            let a = CASpringAnimation(keyPath: "transform.translation.y")
            a.mass = 1
            a.stiffness = CGFloat(spring.stiffness)
            a.damping = CGFloat(spring.damping)
            a.fromValue = 60
            a.toValue = 0
            a.isAdditive = true
            a.duration = max(a.settlingDuration, motion.revealDuration)
            layer.add(a, forKey: "drop")
            layer.animateValue("opacity", to: 1.0, from: 0.0, duration: 0.15, key: "arrival")
        }
        let amplitude = motion.arrivalSwingDegrees
        playSwing(angles: [amplitude, -amplitude / 2, amplitude / 5, -amplitude * 0.06, 0],
                  keyTimes: [0, 0.3, 0.6, 0.82, 1], duration: 0.9, delay: 0)
    }

    /// Vaivén leve del primer despliegue de la sesión.
    public func playSway(amplitude: Double, delay: TimeInterval) {
        guard !MotionStyle.current().reduceMotion else { return }
        playSwing(angles: [0, amplitude, -amplitude / 2, amplitude / 5, 0],
                  keyTimes: [0, 0.25, 0.55, 0.8, 1], duration: 1.1, delay: delay)
    }

    private func playSwing(angles: [Double], keyTimes: [NSNumber], duration: TimeInterval, delay: TimeInterval) {
        let anim = CAKeyframeAnimation(keyPath: "transform")
        anim.values = angles.map {
            NSValue(caTransform3D: StripMotion.cardTransform(tilt: $0, scale: 1, pivotOffset: swingPivot))
        }
        anim.keyTimes = keyTimes
        anim.calculationMode = .cubic
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if delay > 0 {
            anim.beginTime = CACurrentMediaTime() + delay
            anim.fillMode = .backwards
        }
        swingView.layer?.add(anim, forKey: "swing")
    }

    /// Recoloca la ranura con un muelle suave (o un deslizamiento corto con Reducir movimiento).
    func move(to newFrame: NSRect, animated: Bool) {
        let old = frame.origin
        frame = newFrame
        guard animated, let layer, old != newFrame.origin else { return }
        let motion = MotionStyle.current()
        let delta = CGPoint(x: old.x - newFrame.origin.x, y: old.y - newFrame.origin.y)
        let anim: CABasicAnimation
        if let spring = motion.repositionSpring {
            let s = CASpringAnimation(keyPath: "position")
            s.mass = 1
            s.stiffness = CGFloat(spring.stiffness)
            s.damping = CGFloat(spring.damping)
            s.duration = max(s.settlingDuration, motion.repositionDuration)
            anim = s
        } else {
            anim = CABasicAnimation(keyPath: "position")
            anim.duration = motion.repositionDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        anim.fromValue = NSValue(point: delta)
        anim.toValue = NSValue(point: .zero)
        anim.isAdditive = true
        layer.add(anim, forKey: "reposition")
    }

    /// Salida sin caída (desalojo, arrastre a otra carpeta): fundido corto.
    func playDisappear(completion: @escaping () -> Void) {
        isLeaving = true
        applyState(animated: false)
        guard let layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        layer.animateValue("opacity", to: 0.0, from: 1.0, duration: MotionStyle.current().fadeDuration, key: "fall")
        CATransaction.commit()
    }

    /// Descartar: cae girando (< 22°) y se desvanece. Con Reducir movimiento, solo se desvanece.
    func playFall(completion: @escaping () -> Void) {
        let motion = MotionStyle.current()
        isLeaving = true
        applyState(animated: false)
        guard let layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        if motion.reduceMotion {
            layer.animateValue("opacity", to: 0.0, from: 1.0, duration: motion.fadeDuration, key: "fall")
        } else {
            let angle = Double.random(in: 12...motion.fallMaxRotation) * (Bool.random() ? 1 : -1)
            let rotate = StripMotion.cardTransform(tilt: angle, scale: 1, pivotOffset: CGPoint(x: 0, y: bounds.height / 2))
            let end = CATransform3DConcat(rotate, CATransform3DMakeTranslation(0, -520, 0))
            let timing = CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45)
            layer.animateValue("transform", to: NSValue(caTransform3D: end), from: NSValue(caTransform3D: CATransform3DIdentity),
                               duration: motion.fallDuration, timing: timing, key: "fall")
            layer.animateValue("opacity", to: 0.0, from: 1.0, duration: motion.fallDuration, timing: timing, key: "fallFade")
        }
        CATransaction.commit()
    }

    // MARK: Acciones

    public enum Action { case copy, preview, markup, finder, trash }

    /// Punto único de entrada de las acciones (ratón, menú, teclado y VoiceOver).
    /// Se vuelve a comprobar que el archivo exista: si no, copiar y descartar quitan la tarjeta de la tira
    /// (sin Papelera) y el resto no hace nada.
    public func perform(_ action: Action) {
        if refreshMissingState() {
            if action == .copy || action == .trash { delegate?.cardDidRequestRemoveMissing(self, item: item) }
            return
        }
        switch action {
        case .copy:
            triggerCopy()
        case .preview:
            delegate?.cardDidRequestPreview(self, item: item)
            showBadge(text: "Abriendo en Vista Previa…", symbol: nil)
        case .markup:
            delegate?.cardDidRequestMarkup(self, item: item)
            showBadge(text: "Abriendo en Marcación…", symbol: nil)
        case .finder:
            delegate?.cardDidRequestShowInFinder(self, item: item)
            showBadge(text: "Mostrando en Finder…", symbol: nil)
        case .trash:
            delegate?.cardDidRequestDismiss(self, item: item)
        }
    }

    // MARK: Efecto Copiado

    public func triggerCopy() {
        let ok = delegate?.cardDidRequestCopy(self, item: item) ?? false
        if ok {
            showCopyFeedback()
        } else {
            showBadge(text: "No se pudo copiar", symbol: "exclamationmark.triangle")
        }
    }

    public func showCopyFeedback() { showBadge(text: "Copiado", symbol: "checkmark") }

    /// Cápsula de vidrio centrada sobre la tarjeta durante 1 s.
    func showBadge(text: String, symbol: String?) {
        let motion = MotionStyle.current()
        let animate = window?.isVisible == true
        badge.set(text: text, symbol: symbol)
        badge.setFrameOrigin(NSPoint(x: (cardBody.bounds.width - badge.frame.width) / 2,
                                     y: (cardBody.bounds.height - badge.frame.height) / 2))
        badge.isHidden = false
        setAlpha(badge, to: 1, animate: animate)
        if animate, !motion.reduceMotion, let layer = badge.layer {
            layer.animateValue("transform", to: NSValue(caTransform3D: CATransform3DIdentity),
                               from: NSValue(caTransform3D: CATransform3DMakeScale(0.85, 0.85, 1)),
                               spring: motion.hoverSpring, duration: 0.25, key: "pop")
        }
        badgeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setAlpha(self.badge, to: 0, animate: animate) { [weak self] in
                guard let self, self.badge.alphaValue == 0 else { return }
                self.badge.isHidden = true
            }
        }
        badgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: Hit testing

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !isLeaving, alphaValue > 0.01 else { return nil }
        let p = convert(point, from: superview)
        guard hitRect.contains(p) else { return nil }
        for button in [closeButton, actionButton] where !button.isHidden && button.alphaValue > 0.05 && button.frame.contains(p) {
            return button
        }
        return self
    }

    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Eventos de ratón y gestos

    public override func mouseDown(with event: NSEvent) {
        // Control + clic = clic derecho.
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        Self.pressActive = true
        mouseDownLocation = event.locationInWindow
        isDraggingSession = false
        didTriggerLongPress = false
        suppressNextMouseUp = false
        longPressTimer?.invalidate()
        longPressTimer = nil

        // Archivo desaparecido: sin pulsación larga ni arrastre; el clic la quita (en mouseUp).
        if refreshMissingState() { return }

        isPressed = true
        applyState()

        // Mantener 0,5 s: abrir en Marcación (el mouseUp posterior no copia).
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDraggingSession else { return }
                self.didTriggerLongPress = true
                self.isPressed = false
                self.applyState()
                self.perform(.markup)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    public override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        Self.pressActive = false
        isPressed = false
        applyState()

        // Soltar un arrastre (incluso sobre la propia tarjeta) o una pulsación larga no copia.
        guard !isDraggingSession, !didTriggerLongPress, !suppressNextMouseUp else { return }

        if event.clickCount == 2 {
            // Doble clic (intervalo del sistema, NSEvent.doubleClickInterval): Vista Previa.
            // La copia del primer clic ya se hizo.
            perform(.preview)
        } else if event.clickCount == 1 {
            perform(.copy)
        }
    }

    // MARK: Menú contextual

    public override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu() }

    public override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    /// Menú nativo: Copiar | Abrir en Vista Previa, Abrir con Marcación | Mostrar en Finder | Mover a la Papelera.
    /// Sin rojo ni atajos de teclado (el panel no los recibe). Archivo no encontrado: todo desactivado
    /// salvo "Quitar de la tira".
    func makeContextMenu() -> NSMenu {
        let missing = refreshMissingState()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        add("Copiar", #selector(menuCopy), enabled: !missing)
        menu.addItem(.separator())
        add("Abrir en Vista Previa", #selector(menuPreview), enabled: !missing)
        add("Abrir con Marcación", #selector(menuMarkup), enabled: !missing)
        menu.addItem(.separator())
        add("Mostrar en Finder", #selector(menuFinder), enabled: !missing)
        menu.addItem(.separator())
        add(missing ? "Quitar de la tira" : "Mover a la Papelera", #selector(menuTrash))
        return menu
    }

    @objc private func menuCopy() { perform(.copy) }
    @objc private func menuPreview() { perform(.preview) }
    @objc private func menuMarkup() { perform(.markup) }
    @objc private func menuFinder() { perform(.finder) }
    @objc private func menuTrash() { perform(.trash) }

    public func menuWillOpen(_ menu: NSMenu) { Self.menuOpen = true }
    public func menuDidClose(_ menu: NSMenu) { Self.menuOpen = false }

    // MARK: Arrastre (Drag & Drop)

    public override func mouseDragged(with event: NSEvent) {
        let currentLocation = event.locationInWindow
        let dx = abs(currentLocation.x - mouseDownLocation.x)
        let dy = abs(currentLocation.y - mouseDownLocation.y)

        if dx > 6 || dy > 6 {
            longPressTimer?.invalidate()
            longPressTimer = nil
            isPressed = false

            if !isDraggingSession {
                isDraggingSession = true
                suppressNextMouseUp = true
                applyState()
                startDraggingSession(with: event)
            }
        }
    }

    private func startDraggingSession(with event: NSEvent) {
        // El writer debe ser la URL del archivo (NSURL) para que Finder acepte el archivo.
        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let frameInWindow = convert(thumbnailRect, to: nil)
        draggingItem.setDraggingFrame(frameInWindow, contents: item.image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: NSDraggingSource

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSession = false
        Self.pressActive = false
        applyState()
        delegate?.cardDidEndDrag(self, item: item, operation: operation)
    }
}
