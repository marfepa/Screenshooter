import AppKit

@MainActor
public protocol TendederoViewDelegate: AnyObject {
    func tendederoViewDidRequestCopy(item: TendederoItem)
    func tendederoViewDidRequestMarkup(item: TendederoItem)
    func tendederoViewDidRequestPreview(item: TendederoItem)
    func tendederoViewDidRequestDismiss(item: TendederoItem, cardView: TendederoCardView)
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

    /// Contenido que se desplaza al desplegar/recoger la tira.
    private let slideHost = NSView()
    private let ropeView = RopeView()
    private let cardStack = NSView()
    private let emptyCapsule = GlassCapsuleLabel(font: .systemFont(ofSize: 12, weight: .medium), height: 28, horizontalPadding: 13)
    private var cardViews: [UUID: TendederoCardView] = [:]
    private var currentItems: [TendederoItem] = []
    private var laidOutWidth: CGFloat = 0

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

    /// Actualiza la lista de capturas representadas en la cuerda.
    public func reload(items: [TendederoItem]) {
        currentItems = items
        emptyCapsule.isHidden = !items.isEmpty

        let currentIDs = Set(items.map { $0.id })
        for (id, card) in cardViews where !currentIDs.contains(id) {
            card.removeFromSuperview()
            cardViews.removeValue(forKey: id)
        }

        for item in items {
            if let existing = cardViews[item.id] {
                existing.updateItem(item)
            } else {
                let card = TendederoCardView(item: item)
                card.delegate = self
                cardViews[item.id] = card
                cardStack.addSubview(card)
            }
            cardViews[item.id]?.isHidden = item.isFlying // Si está volando, espera oculta hasta aterrizar
        }
        applyFrames()
    }

    private func applyFrames() {
        laidOutWidth = bounds.width
        let frames = StripMotion.cardFrames(count: currentItems.count, width: bounds.width)
        for (item, frame) in zip(currentItems, frames) {
            // Las marcos vienen "de arriba abajo"; AppKit mide desde abajo.
            let y = bounds.height - frame.minY - frame.height
            cardViews[item.id]?.frame = NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
        }
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

    public func cardDidRequestCopy(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestCopy(item: item)
    }

    public func cardDidRequestMarkup(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestMarkup(item: item)
    }

    public func cardDidRequestPreview(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestPreview(item: item)
    }

    public func cardDidRequestDismiss(_ card: TendederoCardView, item: TendederoItem) {
        delegate?.tendederoViewDidRequestDismiss(item: item, cardView: card)
    }

    public func cardDidEndDrag(_ card: TendederoCardView, item: TendederoItem, operation: NSDragOperation) {
        delegate?.tendederoViewDidEndDrag(item: item, operation: operation)
    }
}
