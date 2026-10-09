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

/// Contenedor transparente a los clics: solo responde si lo hace una subvista.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Vista contenedora del Tendedero. Dibuja la cuerda y distribuye las tarjetas colgadas de ella.
///
/// Con más capturas de las que caben, la tira se desplaza: la cuerda no se mueve y las tarjetas se deslizan
/// por su curva. Solo se montan las vistas de las tarjetas visibles ±1 (reciclaje); el resto del contenido es
/// geometría (`StripScroll.Metrics`).
public final class TendederoView: NSView, TendederoCardViewDelegate {
    public weak var delegate: TendederoViewDelegate?
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

    /// Tarjetas montadas (visibles ±1 y la que tiene el foco de teclado).
    private var cardViews: [UUID: TendederoCardView] = [:]
    private var pool: [TendederoCardView] = []
    private static let poolLimit = 8
    private var currentItems: [TendederoItem] = []
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

        cardStack.frame = bounds
        cardStack.autoresizingMask = [.width, .height]
        cardStack.wantsLayer = true
        slideHost.addSubview(cardStack)

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
        scroller.boundsChanged()
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
    public func reload(items: [TendederoItem]) {
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

        var arrivals: [(TendederoCardView, Bool)] = []
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
        onAnnounce?(StripScroll.newCaptureLeftNote)
    }

    /// Interacción en curso: puntero sobre la tira, arrastre/rueda o foco de teclado en una tarjeta.
    var isUserInteracting: Bool {
        pointerInside || scroller.mode == .drag || scroller.mode == .wheel || window?.firstResponder is TendederoCardView
    }

    // MARK: Virtualización

    /// Monta las tarjetas visibles ±1 (más la que tiene el foco) y recicla el resto. Devuelve los ids recién montados.
    @discardableResult
    private func syncMounted() -> [UUID] {
        var wanted: [UUID] = []
        for i in StripScroll.mountedRange(metrics, offset: scroller.offset) { wanted.append(currentItems[i].id) }
        if let r = rovingID, indexByID[r] != nil, !wanted.contains(r),
           focusPendingID == r || cardViews[r]?.isKeyboardFocused == true { wanted.append(r) }
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

    private func mount(item: TendederoItem) {
        let card: TendederoCardView
        if let recycled = pool.popLast() {
            recycled.reconfigure(with: item)
            card = recycled
        } else {
            card = TendederoCardView(item: item)
        }
        card.delegate = self
        card.isHidden = item.isFlying
        cardViews[item.id] = card
        cardStack.addSubview(card)
        if let index = indexByID[item.id] { placeCard(card, id: item.id, index: index, dt: 0, initial: true) }
    }

    private func unmount(id: UUID, card: TendederoCardView) {
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
    func mountedCardForTesting(at index: Int) -> TendederoCardView? {
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
    private func placeCard(_ card: TendederoCardView, id: UUID, index: Int, dt: CGFloat, initial: Bool) -> Bool {
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
        if !active && scroller.moved {
            scroller.moved = false
            scheduleRestAnnouncement()
        }
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
        let target = StripScroll.ensureVisibleTarget(index: index, current: scroller.offset, metrics)
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

    // MARK: Tirón de la cuerda

    private func scheduleTugIfNeeded() {
        guard !Self.hasTuggedThisSession, metrics.isScrollable, isRevealed, !MotionStyle.current().reduceMotion else { return }
        Self.hasTuggedThisSession = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.scroller.mode == .idle, self.scroller.offset == 0 else { return }
            self.scroller.fling(-380)
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
        let count = currentItems.count
        for (id, card) in cardViews {
            card.isRovingStop = id == rovingID
            card.setPosition(index: indexByID[id] ?? 0, count: count)
        }
        cardStack.setAccessibilityChildren(currentItems.compactMap { cardViews[$0.id] })
    }

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
        if window?.firstResponder is TendederoCardView { window?.makeFirstResponder(nil) }
    }

    public func cardDidRequestFocusMove(_ card: TendederoCardView, to target: TendederoCardView.FocusTarget) {
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

    public func cardDidRequestEscape(_ card: TendederoCardView) { onEscape?() }

    public func cardDidGainAccessibilityFocus(_ card: TendederoCardView) {
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
    /// de la vista devuelve `nil` y la captura aparece sin vuelo.
    public func screenFrame(for itemID: UUID) -> CGRect? {
        guard let window, let index = indexByID[itemID] else { return nil }
        let sx = metrics.slotX(index) - scroller.targetOffset
        guard sx + StripScroll.cardWidth > 0, sx < bounds.width else { return nil }
        let card = cardViews[itemID] ?? TendederoCardView(item: currentItems[index])
        let y = StripMotion.slotTopBase + StripMotion.ropeY(x: sx + StripScroll.cardWidth / 2, width: max(bounds.width, 1))
        let origin = NSPoint(x: sx, y: bounds.height - y - StripMotion.slotSize.height)
        let rect = card.thumbnailRect.offsetBy(dx: origin.x, dy: origin.y)
        return window.convertToScreen(convert(rect, to: nil))
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
