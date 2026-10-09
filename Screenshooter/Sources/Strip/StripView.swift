import AppKit

@MainActor
public protocol StripViewDelegate: AnyObject {
    func stripViewDidRequestCopy(item: StripItem) -> Bool
    func stripViewDidRequestMarkup(item: StripItem)
    func stripViewDidRequestPreview(item: StripItem)
    func stripViewDidRequestShowInFinder(item: StripItem)
    func stripViewDidRequestDismiss(item: StripItem, cardView: StripCardView)
    func stripViewDidRequestRemoveMissing(item: StripItem)
    func stripViewDidEndDrag(item: StripItem, operation: NSDragOperation)
}

// MARK: - Cuerda

/// Cuerda: curva cuadrática con caída, tres trazos (sombra difusa, núcleo neutro y brillo) y
/// extremos difuminados con una máscara de gradiente.
final class RopeView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Cuerda más gruesa mientras el puntero está sobre la franja de arrastre o se arrastra (como la maqueta).
    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(optionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func optionsChanged() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }
        let w = bounds.width
        let sag = StripMotion.ropeSag(width: w)
        let y0 = StripMotion.ropeBase
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = DisplayAccessibility.increaseContrast

        let core: CGColor
        if contrast {
            core = (isDark ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.35, alpha: 1)).cgColor
        } else {
            core = NSColor(white: 0.478, alpha: 1).cgColor // #7a7a7a
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: -20, y: y0))
        path.addQuadCurve(to: CGPoint(x: w + 20, y: y0), control: CGPoint(x: w / 2, y: y0 + 2 * sag))

        ctx.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
        ctx.setLineCap(.round)

        // Núcleo con sombra difusa.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2), blur: 2, color: NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.addPath(path)
        ctx.setStrokeColor(core)
        ctx.setLineWidth(isEmphasized ? 2.6 : (contrast ? 2 : 1.5))
        ctx.strokePath()
        ctx.restoreGState()

        // Brillo fino.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -0.35)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(isEmphasized ? 0.8 : 0.4)
        ctx.strokePath()
        ctx.restoreGState()

        // Extremos difuminados.
        let colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.cgColor,
                      NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.08, 0.92, 1]) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [])
        }
        ctx.endTransparencyLayer()
    }
}

// MARK: - Elemento de accesibilidad de una tarjeta no montada

/// Proxy ligero de una captura sin vista (fuera del rango visible ±1): VoiceOver la ve en la lista y, al enfocarla,
/// la tira la desplaza a la vista y la sustituye por la tarjeta real.
final class StripProxyElement: NSAccessibilityElement {
    var onReveal: (() -> Void)?

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        if accessibilityFocused { onReveal?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onReveal?()
        return true
    }
}

// MARK: - Contador de tarjetas fuera de vista

/// Botón de cápsula «‹ +N» / «+N ›» con las capturas ocultas a un lado. Alto 36 pt, relleno de vidrio casi opaco (0,9)
/// y borde de 1 pt. Clic = una página.
final class EdgeCountButton: NSView {
    static let height: CGFloat = 36
    static let minWidth: CGFloat = 52

    let side: StripScroll.Side
    var onClick: (() -> Void)?
    var onEscape: (() -> Void)?
    private(set) var count = 0

    private let glass = GlassSurface(shape: .capsule)
    private let fill = NSView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isDown = false

    init(side: StripScroll.Side) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height))
        wantsLayer = true
        focusRingType = .exterior
        addSubview(glass)

        fill.wantsLayer = true
        fill.layer?.cornerCurve = .continuous
        addSubview(fill)

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.lineBreakMode = .byClipping
        addSubview(label)

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        chevron.image = NSImage(systemSymbolName: side == .left ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        chevron.contentTintColor = .labelColor
        chevron.imageScaling = .scaleNone
        addSubview(chevron)

        isHidden = true
        alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(optionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func optionsChanged() { refreshStyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }

    /// Relleno de vidrio ~0,9 (sólido con Reducir transparencia) y borde de 1 pt.
    private func refreshStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let solid = DisplayAccessibility.reduceTransparency
            let contrast = DisplayAccessibility.increaseContrast
            fill.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(solid ? 1 : 0.9).cgColor
            fill.layer?.borderWidth = 1
            fill.layer?.borderColor = (contrast ? NSColor.labelColor : NSColor.separatorColor).cgColor
        }
        glass.refreshStyle()
    }

    /// Actualiza el número. Con 0 el botón se desvanece y se oculta (también para VoiceOver).
    func setCount(_ n: Int, animated: Bool) {
        guard n != count else { return }
        count = n
        if n > 0 {
            label.stringValue = "+\(n)"
            label.sizeToFit()
            let width = max(Self.minWidth, ceil(label.frame.width) + 13 * 2 + 5 + 8)
            setFrameSize(NSSize(width: width, height: Self.height))
            let description = StripScroll.counterLabel(count: n, side: side)
            setAccessibilityLabel(description)
            toolTip = description
            needsLayout = true
            layoutSubtreeIfNeeded()
            refreshStyle()
            isHidden = false
            fade(to: 1, animated: animated)
        } else {
            setAccessibilityLabel(nil)
            fade(to: 0, animated: animated) { [weak self] in
                guard let self, self.count == 0 else { return }
                self.isHidden = true
            }
        }
    }

    private func fade(to alpha: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MotionStyle.current().reduceMotion ? 0.2 : 0.18
            animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    /// Resalta el contador cuando entra una captura nueva por ese lado (fundido con Reducir movimiento).
    func bump() {
        guard let layer, !isHidden else { return }
        if MotionStyle.current().reduceMotion {
            layer.removeAnimation(forKey: "bump")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 1
            fade.duration = 0.4
            layer.add(fade, forKey: "bump")
            return
        }
        let pivot = StripCardView.pivotOffset(of: self, at: CGPoint(x: bounds.midX, y: bounds.midY))
        let big = StripMotion.cardTransform(tilt: 0, scale: 1.22, pivotOffset: pivot)
        let anim = CAKeyframeAnimation(keyPath: "transform")
        anim.values = [CATransform3DIdentity, big, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        anim.keyTimes = [0, 0.25, 1]
        anim.duration = 0.6
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "bump")
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        fill.frame = bounds
        fill.layer?.cornerRadius = bounds.height / 2
        let iconW: CGFloat = 8, gap: CGFloat = 5
        let contentW = ceil(label.frame.width) + gap + iconW
        var x = (bounds.width - contentW) / 2
        let chevronFrame = { (x: CGFloat) in NSRect(x: x, y: 0, width: iconW, height: self.bounds.height) }
        let labelY = (bounds.height - label.frame.height) / 2
        if side == .left {
            chevron.frame = chevronFrame(x)
            x += iconW + gap
            label.setFrameOrigin(NSPoint(x: x, y: labelY))
        } else {
            label.setFrameOrigin(NSPoint(x: x, y: labelY))
            x += ceil(label.frame.width) + gap
            chevron.frame = chevronFrame(x)
        }
    }

    // Ratón y teclado

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDown = true
        fill.alphaValue = 0.75
    }

    override func mouseUp(with event: NSEvent) {
        fill.alphaValue = 1
        defer { isDown = false }
        if isDown && bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override var acceptsFirstResponder: Bool { window?.canBecomeKey == true && !isHidden && count > 0 }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        switch event.specialKey {
        case .carriageReturn?, .enter?: onClick?()
        default:
            if event.charactersIgnoringModifiers == " " { onClick?() }
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Franja de arrastre de la cuerda

/// Capa transparente que solo captura el ratón en una franja de ±10 pt alrededor de la curva de la cuerda.
/// Arrastrar desplaza la tira (cursor mano abierta / cerrada).
final class RopeDragView: NSView {
    /// ¿El punto (en coordenadas de esta vista) cae en la franja? La decide la tira (curva y si es desplazable).
    var bandContains: (NSPoint) -> Bool = { _ in false }
    var onDragBegan: (() -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var isDragging = false
    private var lastX: CGFloat = 0
    private var hovering = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        bandContains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    private func updateHover(_ event: NSEvent) {
        let over = bandContains(convert(event.locationInWindow, from: nil))
        if over != hovering { hovering = over; onHoverChanged?(over || isDragging) }
        if !isDragging { (over ? NSCursor.openHand : NSCursor.arrow).set() }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func cursorUpdate(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !isDragging { onHoverChanged?(false); NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        isDragging = true
        lastX = event.locationInWindow.x
        NSCursor.closedHand.set()
        onHoverChanged?(true)
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let x = event.locationInWindow.x
        onDragged?(lastX - x) // arrastrar a la izquierda = el contenido avanza (offset crece)
        lastX = x
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragEnded?()
        let over = bandContains(convert(event.locationInWindow, from: nil))
        onHoverChanged?(over)
        (over ? NSCursor.openHand : NSCursor.arrow).set()
    }
}

// MARK: - Vista de la tira

/// Contenedor transparente a los clics: solo responde si lo hace una subvista.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Vista contenedora del Strip. Dibuja la cuerda y distribuye las tarjetas colgadas de ella.
///
/// Con más capturas de las que caben, la tira se desplaza: la cuerda no se mueve y las tarjetas se deslizan
/// por su curva. Solo se montan las vistas de las tarjetas visibles ±1 (reciclaje); el resto del contenido es
/// geometría (`StripScroll.Metrics`).
public final class StripView: NSView, StripCardViewDelegate {
    public weak var delegate: StripViewDelegate?
    /// Esc con el foco en la tira: la tira se recoge y devuelve el foco.
    public var onEscape: (() -> Void)?
    /// Anuncios para VoiceOver (los publica el gestor).
    public var onAnnounce: ((String) -> Void)?
    private var rovingID: UUID?
    /// Tarjeta que está a punto de recibir el foco de teclado: se monta aunque quede fuera del rango visible.
    private var focusPendingID: UUID?

    /// Contenido que se desplaza al desplegar/recoger la tira.
    private let slideHost = NSView()
    private let ropeView = RopeView()
    private let cardStack = PassthroughView()
    private let emptyCapsule = GlassCapsuleLabel(font: .systemFont(ofSize: 12, weight: .medium), height: 28, horizontalPadding: 13)
    private let fadeMask = CAGradientLayer()
    private let ropeDragView = RopeDragView()
    private let leftCount = EdgeCountButton(side: .left)
    private let rightCount = EdgeCountButton(side: .right)
    private var axisLock = AxisLock()
    private var pendingLeftBump = false
    private var proxies: [UUID: StripProxyElement] = [:]
    private var accessibilityDirty = false
    /// El tirón inicial de la cuerda no se anuncia.
    private var suppressRestAnnouncement = false
    private var pendingAccessibilityFocusID: UUID?

    /// Tarjetas montadas (visibles ±1 y la que tiene el foco de teclado).
    private var cardViews: [UUID: StripCardView] = [:]
    private var pool: [StripCardView] = []
    private static let poolLimit = 8
    private var currentItems: [StripItem] = []
    private var indexByID: [UUID: Int] = [:]
    private var laidOutWidth: CGFloat = 0
    private var fallingIDs: Set<UUID> = []

    // Desplazamiento
    private var metrics = StripScroll.Metrics(count: 0, viewWidth: 0)
    private var scroller = StripScroller()
    private var tilts: [UUID: TiltState] = [:]
    private var offHistory = [CGFloat](repeating: 0, count: 6)
    private var velHistory = [CGFloat](repeating: 0, count: 6)
    private var tiltVelHistory = [CGFloat](repeating: 0, count: 6)
    private var displayLink: CADisplayLink?
    private var lastLinkTimestamp: CFTimeInterval = 0
    private var isRevealed = false
    private var pendingNote: String?
    private var restWork: DispatchWorkItem?
    /// El tirón de la cuerda solo ocurre la primera vez por sesión que la tira es desplazable.
    private static var hasTuggedThisSession = false
    /// El puntero está sobre la zona de la tira (lo informa el panel).
    var pointerInside = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        layer?.backgroundColor = NSColor.clear.cgColor

        slideHost.frame = bounds
        slideHost.autoresizingMask = [.width, .height]
        slideHost.wantsLayer = true
        addSubview(slideHost)

        ropeView.frame = bounds
        ropeView.autoresizingMask = [.width, .height]
        slideHost.addSubview(ropeView)

        // La franja de la cuerda va debajo de las tarjetas: donde se solapan manda la tarjeta.
        ropeDragView.frame = bounds
        ropeDragView.autoresizingMask = [.width, .height]
        ropeDragView.bandContains = { [weak self] p in self?.ropeBandContains(p) ?? false }
        ropeDragView.onDragBegan = { [weak self] in self?.beginRopeDrag() }
        ropeDragView.onDragged = { [weak self] dx in self?.ropeDragged(by: dx) }
        ropeDragView.onDragEnded = { [weak self] in self?.endRopeDrag() }
        ropeDragView.onHoverChanged = { [weak self] on in self?.ropeView.isEmphasized = on }
        slideHost.addSubview(ropeDragView)

        cardStack.frame = bounds
        cardStack.autoresizingMask = [.width, .height]
        cardStack.wantsLayer = true
        slideHost.addSubview(cardStack)

        for button in [leftCount, rightCount] {
            slideHost.addSubview(button)
            button.onEscape = { [weak self] in self?.onEscape?() }
        }
        leftCount.onClick = { [weak self] in self?.page(-1) }
        rightCount.onClick = { [weak self] in self?.page(1) }

        cardStack.setAccessibilityElement(true)
        cardStack.setAccessibilityRole(.list)
        cardStack.setAccessibilityLabel("Capturas recientes")

        emptyCapsule.set(text: "Haz una captura con ⌥⌘S y aparecerá aquí")
        slideHost.addSubview(emptyCapsule)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @objc private func displayOptionsChanged() {
        updateFadeMask()
        _ = step(dt: 0)
    }

    public override func layout() {
        super.layout()
        emptyCapsule.setFrameOrigin(NSPoint(
            x: (bounds.width - emptyCapsule.frame.width) / 2,
            y: bounds.height - 66 - emptyCapsule.frame.height
        ))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = cardStack.bounds
        CATransaction.commit()
        layoutCounters()
        if abs(bounds.width - laidOutWidth) > 0.5 { relayout() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() }
    }

    // MARK: Carga y disposición

    /// Marca una captura para que, al salir de la lista, caiga girando en vez de desvanecerse.
    public func markForFall(itemID: UUID) { fallingIDs.insert(itemID) }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (i, item) in currentItems.enumerated() { indexByID[item.id] = i }
    }

    private func updateMetrics() {
        metrics = StripScroll.Metrics(count: currentItems.count, viewWidth: bounds.width)
        scroller.maxOffset = metrics.maxOffset
        scroller.reduceMotion = MotionStyle.current().reduceMotion
        let before = scroller.offset
        scroller.boundsChanged()
        // Reducir movimiento recoloca el offset al instante: los historiales (retardo/inclinación) no deben arrastrar el salto.
        if scroller.offset != before && !scroller.isBusy { fillHistories(scroller.offset) }
        cardStack.setAccessibilityValueDescription(StripScroll.countsDescription(currentItems.count))
        updateFadeMask()
    }

    /// El ancho cambió (otra pantalla, redimensionado): recalcula el rango y recoloca sin animar.
    private func relayout() {
        laidOutWidth = bounds.width
        updateMetrics()
        fillHistories(scroller.offset)
        syncMounted()
        _ = step(dt: 0)
        if scroller.isBusy { kick() }
    }

    /// Actualiza la lista de capturas representadas en la cuerda.
    /// Con la tira visible, las tarjetas nuevas caen y se balancean, las demás se recolocan con muelle
    /// y las que salen se desvanecen (o caen si se marcaron con `markForFall`).
    public func reload(items: [StripItem]) {
        let canAnimate = window?.isVisible == true
        let previousRovingIndex = rovingID.flatMap { indexByID[$0] }
        let oldIDs = Set(currentItems.map { $0.id })
        let hadItems = !currentItems.isEmpty
        let beforeOrigins = cardViews.mapValues { $0.frame.origin }
        currentItems = items
        rebuildIndex()
        let currentIDs = Set(items.map { $0.id })
        let freshIDs = currentIDs.subtracting(oldIDs)
        var animatedRemoval = false

        for (id, card) in cardViews where !currentIDs.contains(id) {
            cardViews.removeValue(forKey: id)
            tilts.removeValue(forKey: id)
            if canAnimate {
                animatedRemoval = true
                if fallingIDs.contains(id) {
                    card.playFall { [weak card] in card?.removeFromSuperview() }
                } else {
                    card.playDisappear { [weak card] in card?.removeFromSuperview() }
                }
            } else {
                card.removeFromSuperview()
            }
        }
        fallingIDs.removeAll()
        if items.isEmpty && animatedRemoval {
            // La cápsula de estado vacío espera a que termine la caída de la última tarjeta.
            emptyCapsule.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + MotionStyle.current().fallDuration) { [weak self] in
                guard let self else { return }
                self.emptyCapsule.isHidden = !self.currentItems.isEmpty
            }
        } else {
            emptyCapsule.isHidden = !items.isEmpty
        }

        updateMetrics()
        let inserted = items.prefix { freshIDs.contains($0.id) }.count
        adjustViewportForInsertion(inserted: inserted, hadItems: hadItems)

        var arrivals: [(StripCardView, Bool)] = []
        for item in items {
            guard let existing = cardViews[item.id] else { continue }
            let wasHidden = existing.isHidden
            existing.updateItem(item)
            existing.isHidden = item.isFlying
            if wasHidden && !item.isFlying { arrivals.append((existing, false)) } // aterrizó tras el vuelo
        }
        for id in syncMounted() where freshIDs.contains(id) {
            if let card = cardViews[id], !card.isHidden { arrivals.append((card, true)) }
        }
        _ = placeCards(dt: 0)
        if canAnimate {
            for (id, before) in beforeOrigins {
                guard !freshIDs.contains(id), let card = cardViews[id] else { continue }
                card.reposition(delta: CGPoint(x: before.x - card.frame.origin.x, y: before.y - card.frame.origin.y))
            }
        }
        updateKeyboardStops(previousIndex: previousRovingIndex)
        _ = step(dt: 0)
        if scroller.isBusy { kick() }
        if canAnimate { for (card, drop) in arrivals { card.playArrival(drop: drop) } }
        scheduleTugIfNeeded()
    }

    /// Una captura nueva entra por la izquierda. Si el usuario no está interactuando, la tira vuelve al inicio;
    /// si lo está, la vista no se mueve (se compensa el origen) y la captura cuenta en el contador izquierdo.
    private func adjustViewportForInsertion(inserted: Int, hadItems: Bool) {
        guard inserted > 0, hadItems else { return }
        let offset = scroller.offset
        if offset > 2 && isRevealed {
            scroller.shift(by: CGFloat(inserted) * metrics.step)
            shiftHistories(CGFloat(inserted) * metrics.step)
            if isUserInteracting {
                insertedWhileInteracting()
            } else {
                animateScroll(to: 0, duration: 0.35)
                pendingNote = StripScroll.newCaptureAtStartNote
            }
        } else {
            if offset != 0 {
                scroller.jump(to: 0)
                fillHistories(0)
            }
            if metrics.isScrollable { pendingNote = StripScroll.newCaptureAtStartNote; scroller.moved = true }
        }
    }

    private func insertedWhileInteracting() {
        pendingLeftBump = true
        onAnnounce?(StripScroll.newCaptureLeftNote)
    }

    /// Interacción en curso: puntero sobre la tira, arrastre/rueda o foco de teclado en una tarjeta.
    var isUserInteracting: Bool {
        pointerInside || scroller.mode == .drag || scroller.mode == .wheel || window?.firstResponder is StripCardView
    }

    // MARK: Virtualización

    /// Monta las tarjetas visibles ±1 (más la que tiene el foco) y recicla el resto. Devuelve los ids recién montados.
    @discardableResult
    private func syncMounted() -> [UUID] {
        var wanted: [UUID] = []
        for i in StripScroll.mountedRange(metrics, offset: scroller.offset) { wanted.append(currentItems[i].id) }
        if let r = rovingID, indexByID[r] != nil, !wanted.contains(r),
           focusPendingID == r || cardViews[r]?.isKeyboardFocused == true { wanted.append(r) }
        // Una tarjeta pulsada, con menú o arrastrándose conserva su vista aunque salga del rango.
        for (id, card) in cardViews where card.isInteracting && !wanted.contains(id) { wanted.append(id) }
        let wantedSet = Set(wanted)
        var changed = false
        for (id, card) in cardViews where !wantedSet.contains(id) {
            unmount(id: id, card: card)
            changed = true
        }
        var added: [UUID] = []
        for id in wanted where cardViews[id] == nil {
            guard let index = indexByID[id] else { continue }
            mount(item: currentItems[index])
            added.append(id)
            changed = true
        }
        if changed { refreshStops() }
        return added
    }

    private func mount(item: StripItem) {
        let card: StripCardView
        if let recycled = pool.popLast() {
            recycled.reconfigure(with: item)
            card = recycled
        } else {
            card = StripCardView(item: item)
        }
        card.delegate = self
        card.isHidden = item.isFlying
        cardViews[item.id] = card
        cardStack.addSubview(card)
        if let index = indexByID[item.id] { placeCard(card, id: item.id, index: index, dt: 0, initial: true) }
    }

    private func unmount(id: UUID, card: StripCardView) {
        cardViews.removeValue(forKey: id)
        tilts.removeValue(forKey: id)
        card.removeFromSuperview()
        card.resetForReuse()
        if pool.count < Self.poolLimit { pool.append(card) }
    }

    /// Número de vistas de tarjeta montadas (para pruebas).
    var mountedCardCount: Int { cardViews.count }
    var scrollOffset: CGFloat { scroller.offset }
    var stripMetrics: StripScroll.Metrics { metrics }
    func mountedCardForTesting(at index: Int) -> StripCardView? {
        currentItems.indices.contains(index) ? cardViews[currentItems[index].id] : nil
    }

    // MARK: Colocación de las tarjetas

    private func placeCards(dt: CGFloat) -> Bool {
        var active = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, card) in cardViews {
            guard let index = indexByID[id] else { continue }
            if placeCard(card, id: id, index: index, dt: dt, initial: false) { active = true }
        }
        CATransaction.commit()
        return active
    }

    /// Posición en la cuerda (la `y` sigue la curva en la `x` de pantalla) e inclinación de una tarjeta.
    @discardableResult
    private func placeCard(_ card: StripCardView, id: UUID, index: Int, dt: CGFloat, initial: Bool) -> Bool {
        let w = max(bounds.width, 1)
        let reduce = scroller.reduceMotion
        let slot = StripScroll.cardWidth
        let nominal = metrics.slotX(index)
        let fraction = StripScroll.clamp((nominal - scroller.offset) / w, 0, 1)
        let lag = StripScroll.lag(fraction: fraction, movingRight: velHistory[0] >= 0, reduceMotion: reduce)
        let sx = nominal - StripScroll.sample(offHistory, lag: lag)
        let y = StripMotion.slotTopBase + StripMotion.ropeY(x: sx + slot / 2, width: w)
        card.place(origin: NSPoint(x: sx, y: bounds.height - y - StripMotion.slotSize.height))

        let target = StripScroll.tiltTarget(velocity: StripScroll.sample(tiltVelHistory, lag: lag), reduceMotion: reduce)
        var tilt = tilts[id] ?? TiltState(angle: initial ? target : 0)
        let active = tilt.step(target: target, dt: dt, reduceMotion: reduce)
        tilts[id] = tilt
        card.setScrollTilt(tilt.angle)
        return active
    }

    private func fillHistories(_ offset: CGFloat) {
        for i in offHistory.indices { offHistory[i] = offset; velHistory[i] = 0; tiltVelHistory[i] = 0 }
    }

    private func shiftHistories(_ delta: CGFloat) {
        for i in offHistory.indices { offHistory[i] += delta }
    }

    private func push(_ history: inout [CGFloat], _ value: CGFloat) {
        history.insert(value, at: 0)
        history.removeLast()
    }

    // MARK: Bucle de animación

    /// Arranca el bucle (CADisplayLink de la vista); en reposo está parado.
    private func kick() {
        scroller.reduceMotion = MotionStyle.current().reduceMotion
        guard window != nil else { return }
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastLinkTimestamp = 0
        }
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let ts = link.timestamp
        let dt = lastLinkTimestamp == 0 ? CGFloat(1.0 / 60) : CGFloat(min(0.05, max(0, ts - lastLinkTimestamp)))
        lastLinkTimestamp = ts
        if !step(dt: dt) { stopLink() }
    }

    /// Un paso de simulación. Devuelve `true` si algo sigue en movimiento.
    @discardableResult
    func step(dt: CGFloat) -> Bool {
        var active = scroller.tick(dt)
        if dt > 0 {
            push(&offHistory, scroller.offset)
            push(&velHistory, scroller.velocity)
            push(&tiltVelHistory, scroller.isProgrammatic ? 0 : scroller.velocity)
        }
        if velHistory.contains(where: { abs($0) > 0.5 }) || offHistory.contains(where: { $0 != offHistory[0] }) { active = true }
        syncMounted()
        if placeCards(dt: dt) { active = true }
        if scroller.mode != .wheel && scroller.mode != .drag { axisLock.reset() }
        updateCounters()
        if !active && scroller.moved {
            scroller.moved = false
            accessibilityDirty = true // las posiciones de los proxies cambiaron
            if suppressRestAnnouncement { suppressRestAnnouncement = false } else { scheduleRestAnnouncement() }
        }
        if !active && accessibilityDirty { rebuildAccessibilityChildren() }
        return active
    }

    /// Bucle manual para pruebas (sin ventana ni display link).
    func advanceForTesting(dt: CGFloat, frames: Int) {
        for _ in 0..<frames { step(dt: dt) }
    }

    // MARK: Anuncios al reposar

    private func scheduleRestAnnouncement() {
        restWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announceRest() }
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func announceRest() {
        let n = currentItems.count
        if let id = pendingAccessibilityFocusID {
            // VoiceOver enfocó un proxy: ahora que la tarjeta real está montada, el foco de VoiceOver pasa a ella.
            pendingAccessibilityFocusID = nil
            if let card = cardViews[id] { NSAccessibility.post(element: card, notification: .focusedUIElementChanged) }
        }
        guard isRevealed, n > 0 else { return }
        if let note = pendingNote {
            pendingNote = nil
            onAnnounce?(note.replacingOccurrences(of: "{n}", with: "\(n)"))
            return
        }
        guard metrics.isScrollable else { return }
        let hidden = StripScroll.hiddenCounts(metrics, offset: scroller.offset)
        onAnnounce?(StripScroll.restAnnouncement(hiddenLeft: hidden.left, hiddenRight: hidden.right, total: n))
    }

    // MARK: Desplazamiento programático

    /// Anima el offset (teclado, páginas, volver al inicio). Con Reducir movimiento salta con un fundido de 150 ms.
    private func animateScroll(to target: CGFloat, duration: CGFloat) {
        userDidScroll()
        scroller.reduceMotion = MotionStyle.current().reduceMotion
        scroller.cancelAnimation()
        if scroller.animate(to: target, duration: duration) {
            fillHistories(scroller.offset)
            _ = step(dt: 0)
            if window?.isVisible == true, let layer = cardStack.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.35
                fade.toValue = 1
                fade.duration = 0.15
                layer.add(fade, forKey: "jumpFade")
            }
        } else {
            kick()
            if window == nil { _ = step(dt: 0) }
        }
    }

    /// Lleva la tarjeta `index` a la vista dejando un margen de 64 pt.
    func ensureVisible(index: Int) {
        guard metrics.isScrollable else { return }
        // Con una animación en curso se evalúa desde su destino, no desde el offset intermedio.
        let base = scroller.mode == .anim ? scroller.targetOffset : scroller.offset
        let target = StripScroll.ensureVisibleTarget(index: index, current: base, metrics)
        guard abs(target - scroller.targetOffset) >= 1 else { return }
        animateScroll(to: target, duration: 0.32)
    }

    /// Una página (0,8 del ancho) a la izquierda (-1) o a la derecha (+1).
    func page(_ direction: Int) {
        guard metrics.isScrollable else { return }
        animateScroll(
            to: StripScroll.pageTarget(base: scroller.targetOffset, direction: direction, viewWidth: bounds.width, maxOffset: metrics.maxOffset),
            duration: 0.42
        )
    }

    /// Algo se está desplazando (arrastre, rueda, inercia o animación): la tira no debe recogerse.
    var isScrollBusy: Bool { scroller.isBusy || displayLink != nil }

    // MARK: Contadores

    private func layoutCounters() {
        let y = bounds.height - 56 - EdgeCountButton.height
        leftCount.setFrameOrigin(NSPoint(x: 10, y: y))
        rightCount.setFrameOrigin(NSPoint(x: bounds.width - 10 - rightCount.frame.width, y: y))
    }

    /// Capturas fuera de vista a cada lado (una tarjeta parcialmente oculta ya cuenta si sobresale más de 1 px).
    private func updateCounters() {
        let hidden = StripScroll.hiddenCounts(metrics, offset: scroller.offset)
        let animated = window?.isVisible == true
        for (button, n) in [(leftCount, hidden.left), (rightCount, hidden.right)] {
            let before = button.count
            button.setCount(n, animated: animated)
            if n == 0, before > 0, window?.firstResponder === button, let id = rovingID, let card = cardViews[id] {
                window?.makeFirstResponder(card) // el contador desaparece: el foco vuelve a la tira
            }
        }
        if pendingLeftBump, leftCount.count > 0 {
            pendingLeftBump = false
            leftCount.bump()
        }
        layoutCounters()
    }

    /// Hay un arrastre de la cuerda en curso (el panel no cambia el paso de clics).
    var isRopeDragging: Bool { scroller.mode == .drag }
    var rovingIDForTesting: UUID? { rovingID }

    var leftCounterValue: Int { leftCount.count }
    var rightCounterValue: Int { rightCount.count }

    // MARK: Entrada: rueda, trackpad y cuerda

    /// Rueda y trackpad. El trackpad (con fases del sistema) se sigue tal cual, con rubber band en los bordes y sin
    /// inercia propia; la rueda de ratón tiene inercia propia. Los signos los resuelve el sistema (desplazamiento
    /// natural incluido): aquí solo se traducen a coordenadas de offset (contenido a la derecha = offset menor).
    public override func scrollWheel(with event: NSEvent) {
        guard metrics.isScrollable else {
            super.scrollWheel(with: event)
            return
        }
        userDidScroll()
        scroller.reduceMotion = MotionStyle.current().reduceMotion
        let phase = event.phase, momentum = event.momentumPhase
        let precise = event.hasPreciseScrollingDeltas
        let systemDriven = precise && (!phase.isEmpty || !momentum.isEmpty)
        if phase.contains(.mayBegin) { return }
        if phase.contains(.began) { axisLock.reset() }

        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !precise {
            dx *= StripScroll.wheelLineHeight
            dy *= StripScroll.wheelLineHeight
        }
        let d = axisLock.resolve(dx: dx, dy: dy)
        if d != 0 { scroller.wheel(delta: -d, systemDriven: systemDriven) }
        if phase.contains(.ended) || phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
            scroller.endSystemWheel()
            if momentum.contains(.ended) || momentum.contains(.cancelled) { axisLock.reset() }
        }
        kick()
        if window == nil { _ = step(dt: 0) }
    }

    /// ¿El punto (coordenadas de la vista) cae en la franja de ±10 pt alrededor de la curva de la cuerda?
    func ropeBandContains(_ p: NSPoint) -> Bool {
        guard metrics.isScrollable, isRevealed else { return false }
        let w = bounds.width
        guard w > 0, p.x >= 0, p.x <= w else { return false }
        let centerY = bounds.height - (StripMotion.ropeBase + StripMotion.ropeY(x: p.x, width: w))
        return abs(p.y - centerY) <= StripScroll.ropeBandHalfWidth
    }

    /// Zonas que capturan el ratón (y la rueda): tarjetas, contadores visibles y franja de la cuerda si la tira se
    /// desplaza. Fuera de ellas el evento pasa a la app de debajo. `p` en coordenadas del panel.
    public func containsInteractivePoint(_ p: NSPoint, margin: CGFloat = 4) -> Bool {
        if cardHitRects.contains(where: { $0.insetBy(dx: -margin, dy: -margin).contains(p) }) { return true }
        let dy = slideOffset
        for button in [leftCount, rightCount] where !button.isHidden && button.alphaValue > 0.01 {
            if button.frame.offsetBy(dx: 0, dy: dy).insetBy(dx: -margin, dy: -margin).contains(p) { return true }
        }
        return ropeBandContains(NSPoint(x: p.x, y: p.y - dy))
    }

    /// Entrada del usuario o desplazamiento propio: cancela el anuncio de reposo pendiente.
    private func userDidScroll() {
        restWork?.cancel()
        suppressRestAnnouncement = false
    }

    public func cardDidBeginPress(_ card: StripCardView) {
        userDidScroll()
        scroller.stopMomentum()
    }

    private func beginRopeDrag() {
        userDidScroll()
        scroller.reduceMotion = MotionStyle.current().reduceMotion
        scroller.beginDrag()
        kick()
    }

    private func ropeDragged(by dx: CGFloat) {
        scroller.drag(by: dx)
        kick()
    }

    private func endRopeDrag() {
        scroller.endDrag()
        kick()
        if window == nil { _ = step(dt: 0) }
    }

    // MARK: Tirón de la cuerda

    private func scheduleTugIfNeeded() {
        guard !Self.hasTuggedThisSession, metrics.isScrollable, isRevealed, !MotionStyle.current().reduceMotion else { return }
        Self.hasTuggedThisSession = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.scroller.mode == .idle, self.scroller.offset == 0 else { return }
            self.scroller.fling(-380)
            self.suppressRestAnnouncement = true
            self.kick()
        }
    }

    // MARK: Desvanecimiento de bordes

    /// Máscara de degradado sobre la capa de tarjetas: 40 pt (16 con Aumentar contraste), solo si la tira se desplaza.
    private func updateFadeMask() {
        guard let layer = cardStack.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard metrics.isScrollable, bounds.width > 0 else {
            layer.mask = nil
            return
        }
        let zone = StripScroll.fadeZone(highContrast: DisplayAccessibility.increaseContrast)
        let w = bounds.width
        let edge = StripScroll.edgeOpacity(centerX: 0, viewWidth: w, zone: zone)
        fadeMask.frame = cardStack.bounds
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.black.withAlphaComponent(edge).cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, NSColor.black.withAlphaComponent(edge).cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(zone / w)), NSNumber(value: Double(1 - zone / w)), 1]
        if layer.mask !== fadeMask { layer.mask = fadeMask }
    }

    /// Comprueba de nuevo que los archivos existan (al desplegar la tira).
    public func refreshMissingStates() {
        for card in cardViews.values { card.refreshMissingState() }
    }

    // MARK: Teclado

    /// Primera captura que ya se puede enfocar (no está en vuelo).
    private var firstNavigableID: UUID? { currentItems.first(where: { !$0.isFlying })?.id }

    /// Mantiene una sola parada de Tab, las posiciones para VoiceOver y recoloca el foco si se quitó la tarjeta enfocada.
    private func updateKeyboardStops(previousIndex: Int?) {
        if let id = rovingID, indexByID[id] == nil {
            // La tarjeta enfocada desapareció: el foco pasa a la vecina.
            let next = min(previousIndex ?? 0, currentItems.count - 1)
            rovingID = currentItems.indices.contains(next) ? currentItems[next].id : nil
            if let rid = rovingID, window?.isKeyWindow == true {
                focusPendingID = rid
                syncMounted()
                ensureVisible(index: next)
                if let card = cardViews[rid] { window?.makeFirstResponder(card) }
                focusPendingID = nil
            }
        }
        if rovingID == nil || indexByID[rovingID!] == nil { rovingID = firstNavigableID }
        refreshStops()
    }

    private func refreshStops() {
        // La parada de Tab debe ser una tarjeta montada: si la actual se recicló, pasa a la más cercana al viewport.
        if let r = rovingID, cardViews[r] == nil, focusPendingID != r {
            let center = scroller.offset + bounds.width / 2
            let nearest = cardViews.filter { !$0.value.isHidden && !$0.value.item.isFlying }
                .min { a, b in
                    abs(metrics.slotX(indexByID[a.key] ?? 0) + StripScroll.cardWidth / 2 - center)
                        < abs(metrics.slotX(indexByID[b.key] ?? 0) + StripScroll.cardWidth / 2 - center)
                }
            if let nearest { rovingID = nearest.key }
        }
        let count = currentItems.count
        for (id, card) in cardViews {
            card.isRovingStop = id == rovingID
            card.setPosition(index: indexByID[id] ?? 0, count: count)
        }
        if scroller.isBusy { accessibilityDirty = true } else { rebuildAccessibilityChildren() }
    }

    /// Todas las capturas, también las no montadas: la vista real si existe y un proxy ligero si no.
    private func rebuildAccessibilityChildren() {
        accessibilityDirty = false
        let count = currentItems.count
        var children: [Any] = []
        children.reserveCapacity(count)
        var live = Set<UUID>()
        for (index, item) in currentItems.enumerated() {
            if let card = cardViews[item.id] {
                children.append(card)
                continue
            }
            live.insert(item.id)
            let proxy = proxies[item.id] ?? StripProxyElement()
            proxies[item.id] = proxy
            proxy.setAccessibilityRole(.button)
            proxy.setAccessibilityParent(cardStack)
            proxy.setAccessibilityLabel(StripMotion.accessibilityLabel(for: item, missing: false))
            proxy.setAccessibilityHelp("Clic para copiar. Mantener para Marcación")
            proxy.setAccessibilityIndex(index)
            proxy.setAccessibilityValueDescription(StripMotion.positionText(index: index, count: count))
            let x = metrics.slotX(index) - scroller.offset
            let y = StripMotion.slotTopBase + StripMotion.ropeY(x: x + StripScroll.cardWidth / 2, width: max(bounds.width, 1))
            proxy.setAccessibilityFrameInParentSpace(NSRect(
                x: x, y: bounds.height - y - StripMotion.slotSize.height,
                width: StripMotion.slotSize.width, height: StripMotion.slotSize.height
            ))
            let id = item.id
            proxy.onReveal = { [weak self] in
                guard let self, let index = self.indexByID[id] else { return }
                self.pendingAccessibilityFocusID = id
                self.ensureVisible(index: index)
                self.kick()
                if self.window == nil { _ = self.step(dt: 0) }
            }
            children.append(proxy)
        }
        for id in proxies.keys where indexByID[id] == nil || cardViews[id] != nil { proxies.removeValue(forKey: id) }
        cardStack.setAccessibilityChildren(children)
    }

    /// Elementos hijos de la lista, en orden (para pruebas).
    var accessibilityChildCountForTesting: Int { (cardStack.accessibilityChildren() ?? []).count }
    func accessibilityChildForTesting(at index: Int) -> Any? {
        let children = cardStack.accessibilityChildren() ?? []
        return children.indices.contains(index) ? children[index] : nil
    }
    func rebuildAccessibilityForTesting() { rebuildAccessibilityChildren() }

    /// Da el foco de teclado a la primera tarjeta (la tira debe ser key). Devuelve `false` si no hay tarjetas.
    @discardableResult
    public func focusFirstCard() -> Bool {
        guard let firstID = firstNavigableID, let window else { return false }
        rovingID = firstID
        focusPendingID = firstID
        defer { focusPendingID = nil }
        syncMounted()
        refreshStops()
        ensureVisible(index: indexByID[firstID] ?? 0)
        guard let card = cardViews[firstID] else { return false }
        return window.makeFirstResponder(card)
    }

    public var hasCards: Bool { currentItems.contains { !$0.isFlying } }

    /// Suelta el foco de teclado (la tira deja de ser key).
    public func clearKeyboardFocus() {
        if window?.firstResponder is StripCardView { window?.makeFirstResponder(nil) }
    }

    public func cardDidRequestFocusMove(_ card: StripCardView, to target: StripCardView.FocusTarget) {
        guard let index = indexByID[card.item.id], !currentItems.isEmpty else { return }
        let last = currentItems.count - 1
        let destination: Int
        switch target {
        case .previous: destination = max(0, index - 1)
        case .next: destination = min(last, index + 1)
        case .first: destination = 0
        case .last: destination = last
        case .pageUp: page(-1); return
        case .pageDown: page(1); return
        }
        moveFocus(to: destination)
    }

    private func moveFocus(to index: Int) {
        guard currentItems.indices.contains(index) else { return }
        rovingID = currentItems[index].id
        focusPendingID = rovingID
        defer { focusPendingID = nil }
        syncMounted()
        refreshStops()
        ensureVisible(index: index)
        if let card = cardViews[currentItems[index].id] { window?.makeFirstResponder(card) }
    }

    public func cardDidRequestEscape(_ card: StripCardView) { onEscape?() }

    public func cardDidGainAccessibilityFocus(_ card: StripCardView) {
        if let index = indexByID[card.item.id] { ensureVisible(index: index) }
    }

    // MARK: Despliegue

    /// Desliza la tira desde arriba con muelle; con Reducir movimiento, solo un fundido.
    public func playReveal(motion: MotionStyle, sway: Bool) {
        isRevealed = true
        guard let layer = slideHost.layer else { return }
        // Se lee la posición mostrada ANTES de tocar el modelo o quitar animaciones.
        let inFlight = layer.animation(forKey: "slide") != nil
        let shownY = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat
        let shownOpacity = layer.presentation()?.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if motion.reduceMotion {
            layer.transform = CATransform3DIdentity
        } else {
            layer.opacity = 1
        }
        CATransaction.commit()

        if motion.reduceMotion {
            layer.removeAnimation(forKey: "slide")
            let from: Float = inFlight ? (shownOpacity ?? 0) : 0
            layer.animateValue("opacity", to: 1.0, from: from, duration: motion.fadeDuration, key: "slide")
        } else {
            let from = inFlight ? (shownY ?? StripMotion.stripHeight) : StripMotion.stripHeight
            layer.animateValue("transform.translation.y", to: 0.0, from: from, spring: motion.revealSpring,
                               duration: motion.revealDuration, key: "slide")
        }
        if sway && !motion.reduceMotion {
            for card in cardViews.values {
                card.playSway(amplitude: Double.random(in: -motion.swayDegrees...motion.swayDegrees),
                              delay: Double.random(in: 0...motion.swayMaxDelay))
            }
        }
        scheduleTugIfNeeded()
    }

    /// Recoge la tira (ease-in 0,22 s hacia arriba; con Reducir movimiento, fundido de 0,2 s).
    public func playRetract(motion: MotionStyle, completion: @escaping () -> Void) {
        isRevealed = false
        guard let layer = slideHost.layer else { completion(); return }
        let inFlight = layer.animation(forKey: "slide") != nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        if motion.reduceMotion {
            layer.animateValue("opacity", to: 0.0, from: inFlight ? nil : 1.0, duration: motion.fadeDuration, key: "slide")
        } else {
            let from: Any = inFlight ? (layer.presentation()?.value(forKeyPath: "transform.translation.y") ?? 0.0) : 0.0
            layer.animateValue("transform.translation.y", to: StripMotion.stripHeight, from: from,
                               duration: motion.retractDuration, timing: CAMediaTimingFunction(name: .easeIn), key: "slide")
        }
        CATransaction.commit()
    }

    /// Cada tarjeta recibe el hover según la posición del puntero (en coordenadas del panel).
    public func updateHover(pointer: NSPoint?) {
        for card in cardViews.values {
            guard let pointer, !card.isHidden, !isScrollBusy else { card.setHovered(false); continue }
            let local = card.convert(pointer, from: nil)
            card.setHovered(card.hitRect.contains(local))
        }
    }

    /// Marcos de las tarjetas visibles en coordenadas del panel (origen abajo-izquierda, como la ventana).
    public var cardHitRects: [CGRect] {
        // Durante el deslizamiento las tarjetas visibles están desplazadas: se usa la posición mostrada.
        let dy = slideOffset
        return cardViews.values.filter { !$0.isHidden }.map { $0.convert($0.hitRect, to: self).offsetBy(dx: 0, dy: dy) }
    }

    /// Desplazamiento vertical visible de la tira (positivo = hacia arriba, fuera de pantalla).
    private var slideOffset: CGFloat {
        guard let layer = slideHost.layer, layer.animation(forKey: "slide") != nil,
              let y = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat else { return 0 }
        return y
    }

    /// `true` mientras la tira se despliega o se recoge.
    public var isSliding: Bool { slideHost.layer?.animation(forKey: "slide") != nil }

    /// Marco de la miniatura de una captura en coordenadas de pantalla (destino del vuelo de la captura).
    /// Si la tarjeta no está montada se calcula con la geometría del destino del desplazamiento; si queda fuera
    /// de la vista por la izquierda, el destino es el contador «+N».
    public func screenFrame(for itemID: UUID) -> CGRect? {
        guard let window, let index = indexByID[itemID] else { return nil }
        let sx = metrics.slotX(index) - scroller.targetOffset
        guard sx + StripScroll.cardWidth > 0, sx < bounds.width else {
            // La captura entra por la izquierda con la vista sin moverse: vuela al contador «+N».
            guard metrics.isScrollable, sx < 0 else { return nil }
            layoutCounters()
            return window.convertToScreen(convert(leftCount.frame, to: nil))
        }
        let card = cardViews[itemID] ?? StripCardView(item: currentItems[index])
        let y = StripMotion.slotTopBase + StripMotion.ropeY(x: sx + StripScroll.cardWidth / 2, width: max(bounds.width, 1))
        let origin = NSPoint(x: sx, y: bounds.height - y - StripMotion.slotSize.height)
        let rect = card.thumbnailRect.offsetBy(dx: origin.x, dy: origin.y)
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: - StripCardViewDelegate

    public func cardDidRequestCopy(_ card: StripCardView, item: StripItem) -> Bool {
        delegate?.stripViewDidRequestCopy(item: item) ?? false
    }

    public func cardDidRequestMarkup(_ card: StripCardView, item: StripItem) {
        delegate?.stripViewDidRequestMarkup(item: item)
    }

    public func cardDidRequestPreview(_ card: StripCardView, item: StripItem) {
        delegate?.stripViewDidRequestPreview(item: item)
    }

    public func cardDidRequestShowInFinder(_ card: StripCardView, item: StripItem) {
        delegate?.stripViewDidRequestShowInFinder(item: item)
    }

    public func cardDidRequestRemoveMissing(_ card: StripCardView, item: StripItem) {
        delegate?.stripViewDidRequestRemoveMissing(item: item)
    }

    public func cardDidRequestDismiss(_ card: StripCardView, item: StripItem) {
        delegate?.stripViewDidRequestDismiss(item: item, cardView: card)
    }

    public func cardDidEndDrag(_ card: StripCardView, item: StripItem, operation: NSDragOperation) {
        delegate?.stripViewDidEndDrag(item: item, operation: operation)
    }
}
