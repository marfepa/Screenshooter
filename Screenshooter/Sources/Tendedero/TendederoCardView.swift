import AppKit
import UniformTypeIdentifiers

@MainActor
public protocol TendederoCardViewDelegate: AnyObject {
    func cardDidRequestCopy(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestMarkup(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestPreview(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestDismiss(_ card: TendederoCardView, item: TendederoItem)
    func cardDidEndDrag(_ card: TendederoCardView, item: TendederoItem, operation: NSDragOperation)
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
public final class TendederoCardView: NSView, NSDraggingSource {
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
    private var longPressTimer: Timer?
    private var badgeWorkItem: DispatchWorkItem?

    public private(set) var isHovered = false
    public private(set) var isMissing = false
    private var isPressed = false

    /// `true` mientras hay una pulsación o arrastre en curso sobre alguna tarjeta (el panel no debe retraerse).
    public private(set) static var isBusy = false

    public init(item: TendederoItem) {
        self.item = item
        super.init(frame: NSRect(origin: .zero, size: StripMotion.slotSize))
        wantsLayer = true
        setupLayout()
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
        closeButton.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.cardDidRequestDismiss(self, item: self.item)
        }
        actionButton.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.cardDidRequestMarkup(self, item: self.item)
        }
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
        applyState()
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
        return missing
    }

    // MARK: Estado visual

    public func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyState()
    }

    private var showsControls: Bool { isHovered && !isDraggingSession }

    private func applyState() {
        let motion = MotionStyle.current()
        let scale: CGFloat = isPressed ? motion.pressScale : (showsControls ? motion.hoverScale : 1)
        cardBody.layer?.transform = StripMotion.cardTransform(tilt: item.tilt, scale: scale, pivotOffset: cardPivot)

        shadowLayer.shadowRadius = showsControls ? 14 : 8
        shadowLayer.shadowOpacity = showsControls ? 0.26 : 0.18
        shadowLayer.shadowOffset = CGSize(width: 0, height: showsControls ? -7 : -4)

        setControl(closeButton, visible: showsControls)
        setControl(actionButton, visible: showsControls && !isMissing)
        setControl(meta, visible: showsControls)
        pressRing.alphaValue = isPressed ? 0.9 : 0
        cardBody.alphaValue = isDraggingSession ? 0.35 : 1
    }

    private func setControl(_ view: NSView, visible: Bool) {
        view.isHidden = !visible
        view.alphaValue = visible ? 1 : 0
    }

    // MARK: Efecto Copiado

    public func triggerCopy() {
        delegate?.cardDidRequestCopy(self, item: item)
        showCopyFeedback()
    }

    public func showCopyFeedback() {
        badge.set(text: "Copiado", symbol: "checkmark")
        badge.setFrameOrigin(NSPoint(x: (cardBody.bounds.width - badge.frame.width) / 2,
                                     y: (cardBody.bounds.height - badge.frame.height) / 2))
        badge.isHidden = false
        badge.alphaValue = 1
        badgeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.badge.alphaValue = 0
            self?.badge.isHidden = true
        }
        badgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: Hit testing

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
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
        Self.isBusy = true
        mouseDownLocation = event.locationInWindow
        isDraggingSession = false
        didTriggerLongPress = false
        isPressed = true
        applyState()

        // Mantener 0,5 s: abrir en Marcación.
        longPressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDraggingSession else { return }
                self.didTriggerLongPress = true
                self.isPressed = false
                self.applyState()
                self.delegate?.cardDidRequestMarkup(self, item: self.item)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    public override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        Self.isBusy = false
        isPressed = false
        applyState()

        guard !isDraggingSession, !didTriggerLongPress else { return }

        if event.clickCount == 2 {
            // Doble clic (intervalo del sistema, NSEvent.doubleClickInterval): Vista Previa.
            // La copia del primer clic ya se hizo.
            delegate?.cardDidRequestPreview(self, item: item)
        } else if event.clickCount == 1 {
            triggerCopy()
        }
    }

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
        Self.isBusy = false
        applyState()
        delegate?.cardDidEndDrag(self, item: item, operation: operation)
    }
}
