import AppKit

@MainActor
public protocol TendederoViewDelegate: AnyObject {
    func tendederoViewDidRequestCopy(item: TendederoItem) -> Bool
    func tendederoViewDidRequestMarkup(item: TendederoItem)
    func tendederoViewDidRequestPreview(item: TendederoItem)
    func tendederoViewDidRequestShowInFinder(item: TendederoItem)
    func tendederoViewDidRequestDismiss(item: TendederoItem, cardView: TendederoCardView)
    func tendederoViewDidRequestRemoveMissing(item: TendederoItem)
    func tendederoViewDidEndDrag(item: TendederoItem, operation: NSDragOperation)
}

// MARK: - Cuerda

/// Cuerda: curva cuadrática con caída, tres trazos (sombra difusa, núcleo neutro y brillo) y
/// extremos difuminados con una máscara de gradiente.
final class RopeView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        ctx.setLineWidth(contrast ? 2 : 1.5)
        ctx.strokePath()
        ctx.restoreGState()

        // Brillo fino.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -0.35)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.4)
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

// MARK: - Vista de la tira

/// Vista contenedora del Tendedero. Dibuja la cuerda y distribuye las tarjetas colgadas de ella.
public final class TendederoView: NSView, TendederoCardViewDelegate {
    public weak var delegate: TendederoViewDelegate?
    /// Esc con el foco en la tira: la tira se recoge y devuelve el foco.
    public var onEscape: (() -> Void)?
    private var rovingID: UUID?

    /// Contenido que se desplaza al desplegar/recoger la tira.
    private let slideHost = NSView()
    private let ropeView = RopeView()
    private let cardStack = NSView()
    private let emptyCapsule = GlassCapsuleLabel(font: .systemFont(ofSize: 12, weight: .medium), height: 28, horizontalPadding: 13)
    private var cardViews: [UUID: TendederoCardView] = [:]
    private var currentItems: [TendederoItem] = []
    private var laidOutWidth: CGFloat = 0
    private var fallingIDs: Set<UUID> = []
    private var newCards: Set<UUID> = []

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

        cardStack.frame = bounds
        cardStack.autoresizingMask = [.width, .height]
        cardStack.wantsLayer = true
        slideHost.addSubview(cardStack)

        cardStack.setAccessibilityRole(.list)
        cardStack.setAccessibilityLabel("Capturas recientes")

        emptyCapsule.set(text: "Haz una captura con ⌥⌘S y aparecerá aquí")
        slideHost.addSubview(emptyCapsule)
    }

    public override func layout() {
        super.layout()
        emptyCapsule.setFrameOrigin(NSPoint(
            x: (bounds.width - emptyCapsule.frame.width) / 2,
            y: bounds.height - 66 - emptyCapsule.frame.height
        ))
        if abs(bounds.width - laidOutWidth) > 0.5 { applyFrames() }
    }

    // MARK: Carga y disposición

    /// Marca una captura para que, al salir de la lista, caiga girando en vez de desvanecerse.
    public func markForFall(itemID: UUID) { fallingIDs.insert(itemID) }

    /// Actualiza la lista de capturas representadas en la cuerda.
    /// Con la tira visible, las tarjetas nuevas caen y se balancean, las demás se recolocan con muelle
    /// y las que salen se desvanecen (o caen si se marcaron con `markForFall`).
    public func reload(items: [TendederoItem]) {
        let canAnimate = window?.isVisible == true
        let previousRovingIndex = rovingID.flatMap { id in currentItems.firstIndex { $0.id == id } }
        currentItems = items
        emptyCapsule.isHidden = !items.isEmpty

        let currentIDs = Set(items.map { $0.id })
        for (id, card) in cardViews where !currentIDs.contains(id) {
            cardViews.removeValue(forKey: id)
            if canAnimate {
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

        var arrivals: [(TendederoCardView, Bool)] = []
        for item in items {
            if let existing = cardViews[item.id] {
                let wasHidden = existing.isHidden
                existing.updateItem(item)
                existing.isHidden = item.isFlying
                if wasHidden && !item.isFlying { arrivals.append((existing, false)) } // aterrizó tras el vuelo
            } else {
                let card = TendederoCardView(item: item)
                card.delegate = self
                card.isHidden = item.isFlying // Si está volando, espera oculta hasta aterrizar
                cardViews[item.id] = card
                cardStack.addSubview(card)
                if !item.isFlying { arrivals.append((card, true)) }
                newCards.insert(item.id)
            }
        }
        applyFrames(animated: canAnimate)
        newCards.removeAll()
        updateKeyboardStops(previousIndex: previousRovingIndex)
        if canAnimate { for (card, drop) in arrivals { card.playArrival(drop: drop) } }
    }

    private func applyFrames(animated: Bool = false) {
        laidOutWidth = bounds.width
        let frames = StripMotion.cardFrames(count: currentItems.count, width: bounds.width)
        for (item, frame) in zip(currentItems, frames) {
            // Los marcos vienen "de arriba abajo"; AppKit mide desde abajo.
            let y = bounds.height - frame.minY - frame.height
            let target = NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
            cardViews[item.id]?.move(to: target, animated: animated && !newCards.contains(item.id))
        }
    }

    /// Comprueba de nuevo que los archivos existan (al desplegar la tira).
    public func refreshMissingStates() {
        for card in cardViews.values { card.refreshMissingState() }
    }

    // MARK: Teclado

    /// Tarjetas visibles en orden de izquierda a derecha.
    private var orderedCards: [TendederoCardView] {
        currentItems.compactMap { cardViews[$0.id] }.filter { !$0.isHidden }
    }

    /// Mantiene una sola parada de Tab, las posiciones para VoiceOver y recoloca el foco si se quitó la tarjeta enfocada.
    private func updateKeyboardStops(previousIndex: Int?) {
        let cards = orderedCards
        if let id = rovingID, !currentItems.contains(where: { $0.id == id }) {
            // La tarjeta enfocada desapareció: el foco pasa a la vecina.
            let next = min(previousIndex ?? 0, cards.count - 1)
            rovingID = cards.indices.contains(next) ? cards[next].item.id : nil
            if window?.isKeyWindow == true, let card = rovingID.flatMap({ cardViews[$0] }) {
                window?.makeFirstResponder(card)
            }
        }
        if rovingID == nil || cardViews[rovingID!] == nil { rovingID = cards.first?.item.id }
        for (i, card) in cards.enumerated() {
            card.isRovingStop = card.item.id == rovingID
            card.setPosition(index: i, count: cards.count)
        }
        cardStack.setAccessibilityChildren(cards)
    }

    /// Da el foco de teclado a la primera tarjeta (la tira debe ser key). Devuelve `false` si no hay tarjetas.
    @discardableResult
    public func focusFirstCard() -> Bool {
        guard let first = orderedCards.first, let window else { return false }
        rovingID = first.item.id
        updateKeyboardStops(previousIndex: 0)
        return window.makeFirstResponder(first)
    }

    public var hasCards: Bool { !orderedCards.isEmpty }

    /// Suelta el foco de teclado (la tira deja de ser key).
    public func clearKeyboardFocus() {
        if window?.firstResponder is TendederoCardView { window?.makeFirstResponder(nil) }
    }

    public func cardDidRequestFocusMove(_ card: TendederoCardView, to target: TendederoCardView.FocusTarget) {
        let cards = orderedCards
        guard let index = cards.firstIndex(where: { $0 === card }), !cards.isEmpty else { return }
        let destination: Int
        switch target {
        case .previous: destination = max(0, index - 1)
        case .next: destination = min(cards.count - 1, index + 1)
        case .first: destination = 0
        case .last: destination = cards.count - 1
        }
        rovingID = cards[destination].item.id
        updateKeyboardStops(previousIndex: destination)
        window?.makeFirstResponder(cards[destination])
    }

    public func cardDidRequestEscape(_ card: TendederoCardView) { onEscape?() }

    // MARK: Despliegue

    /// Desliza la tira desde arriba con muelle; con Reducir movimiento, solo un fundido.
    public func playReveal(motion: MotionStyle, sway: Bool) {
        guard let layer = slideHost.layer else { return }
        let inFlight = layer.animation(forKey: "slide") != nil
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
            layer.animateValue("opacity", to: 1.0, from: inFlight ? nil : 0.0, duration: motion.fadeDuration, key: "slide")
        } else {
            let from: Any = inFlight ? (layer.presentation()?.value(forKeyPath: "transform.translation.y") ?? StripMotion.stripHeight)
                                     : StripMotion.stripHeight
            layer.animateValue("transform.translation.y", to: 0.0, from: from, spring: motion.revealSpring,
                               duration: motion.revealDuration, key: "slide")
        }
        if sway && !motion.reduceMotion {
            for card in cardViews.values {
                card.playSway(amplitude: Double.random(in: -motion.swayDegrees...motion.swayDegrees),
                              delay: Double.random(in: 0...motion.swayMaxDelay))
            }
        }
    }

    /// Recoge la tira (ease-in 0,22 s hacia arriba; con Reducir movimiento, fundido de 0,2 s).
    public func playRetract(motion: MotionStyle, completion: @escaping () -> Void) {
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
            guard let pointer, !card.isHidden else { card.setHovered(false); continue }
            let local = card.convert(pointer, from: nil)
            card.setHovered(card.hitRect.contains(local))
        }
    }

    /// Marcos de las tarjetas visibles en coordenadas del panel (origen abajo-izquierda, como la ventana).
    public var cardHitRects: [CGRect] {
        cardViews.values.filter { !$0.isHidden }.map { $0.convert($0.hitRect, to: self) }
    }

    /// Marco de la miniatura de una tarjeta en coordenadas de pantalla (destino del vuelo de la captura).
    public func screenFrame(for itemID: UUID) -> CGRect? {
        guard let card = cardViews[itemID], let window = window else { return nil }
        let windowRect = card.convert(card.thumbnailRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    // MARK: - TendederoCardViewDelegate

    public func cardDidRequestCopy(_ card: TendederoCardView, item: TendederoItem) -> Bool {
        delegate?.tendederoViewDidRequestCopy(item: item) ?? false
    }

    public func cardDidRequestMarkup(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestMarkup(item: item)
    }

    public func cardDidRequestPreview(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestPreview(item: item)
    }

    public func cardDidRequestShowInFinder(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestShowInFinder(item: item)
    }

    public func cardDidRequestRemoveMissing(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestRemoveMissing(item: item)
    }

    public func cardDidRequestDismiss(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestDismiss(item: item, cardView: card)
    }

    public func cardDidEndDrag(_ card: TendederoCardView, item: TendederoItem, operation: NSDragOperation) {
        delegate?.tendederoViewDidEndDrag(item: item, operation: operation)
    }
}
