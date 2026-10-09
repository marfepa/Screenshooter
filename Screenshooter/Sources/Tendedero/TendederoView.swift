import AppKit

@MainActor
public protocol TendederoViewDelegate: AnyObject {
    func tendederoViewDidRequestCopy(item: TendederoItem)
    func tendederoViewDidRequestMarkup(item: TendederoItem)
    func tendederoViewDidRequestPreview(item: TendederoItem)
    func tendederoViewDidRequestDismiss(item: TendederoItem, cardView: TendederoCardView)
}

/// Vista contenedora del Tendedero. Dibuja la cuerda horizontal en la parte superior
/// y distribuye las tarjetas (pegged cards) colgadas.
public final class TendederoView: NSView, TendederoCardViewDelegate {
    public weak var delegate: TendederoViewDelegate?
    
    private let lineLayer = CALayer()
    private let cardStack = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Tendedero vacío · Captura con ⌥⌘S")
    private var cardViews: [UUID: TendederoCardView] = [:]
    
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let layer = layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        
        // 1. La cuerda del tendedero (fina línea sutil)
        lineLayer.backgroundColor = NSColor(white: 0.85, alpha: 0.6).cgColor
        lineLayer.cornerRadius = 1
        lineLayer.shadowColor = NSColor.black.cgColor
        lineLayer.shadowOpacity = 0.4
        lineLayer.shadowRadius = 1
        lineLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer.addSublayer(lineLayer)
        
        // 2. Contenedor de tarjetas
        cardStack.wantsLayer = true
        addSubview(cardStack)
        
        // 3. Etiqueta de estado vacío
        emptyLabel.alignment = .center
        emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        emptyLabel.wantsLayer = true
        if let el = emptyLabel.layer {
            el.backgroundColor = NSColor(white: 0.1, alpha: 0.75).cgColor
            el.cornerRadius = 12
        }
        addSubview(emptyLabel)
    }
    
    public override func layout() {
        super.layout()
        
        // Posicionar la cuerda a 26 puntos del borde superior
        let lineY = bounds.height - 24
        lineLayer.frame = CGRect(x: 20, y: lineY, width: bounds.width - 40, height: 2)
        
        // Área para las tarjetas
        cardStack.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        
        // Etiqueta vacía centrada
        let labelW: CGFloat = 280
        let labelH: CGFloat = 28
        emptyLabel.frame = NSRect(
            x: (bounds.width - labelW) / 2,
            y: (bounds.height - labelH) / 2 - 10,
            width: labelW,
            height: labelH
        )
    }
    
    /// Actualiza la lista de capturas representadas en la cuerda.
    public func reload(items: [TendederoItem]) {
        emptyLabel.isHidden = !items.isEmpty
        
        // Eliminar tarjetas que ya no existen
        let currentIDs = Set(items.map { $0.id })
        for (id, card) in cardViews where !currentIDs.contains(id) {
            card.removeFromSuperview()
            cardViews.removeValue(forKey: id)
        }
        
        // Añadir o actualizar tarjetas
        let cardW = TendederoCardView.defaultWidth
        let spacing: CGFloat = 16
        let totalCount = items.count
        let totalWidth = CGFloat(totalCount) * cardW + CGFloat(max(0, totalCount - 1)) * spacing
        
        var currentX = max(24, (bounds.width - totalWidth) / 2)
        let cardY: CGFloat = 10
        
        for item in items {
            let cardView: TendederoCardView
            if let existing = cardViews[item.id] {
                cardView = existing
                cardView.updateItem(item)
            } else {
                cardView = TendederoCardView(item: item)
                cardView.delegate = self
                cardViews[item.id] = cardView
                cardStack.addSubview(cardView)
            }
            
            cardView.frame = NSRect(x: currentX, y: cardY, width: cardW, height: bounds.height - 24)
            cardView.isHidden = item.isFlying // Si está volando, espera oculta hasta aterrizar
            currentX += cardW + spacing
        }
    }
    
    /// Devuelve el marco en coordenadas de pantalla de una tarjeta para la animación de vuelo.
    public func screenFrame(for itemID: UUID) -> CGRect? {
        guard let card = cardViews[itemID], let window = window else { return nil }
        let windowRect = card.convert(card.bounds, to: nil)
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
}
