import AppKit
import UniformTypeIdentifiers

@MainActor
public protocol TendederoCardViewDelegate: AnyObject {
    func cardDidRequestCopy(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestMarkup(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestPreview(_ card: TendederoCardView, item: TendederoItem)
    func cardDidRequestDismiss(_ card: TendederoCardView, item: TendederoItem)
}

/// Vista individual que representa una tarjeta de captura colgada en el Tendedero con su pinza.
/// Soporta arrastre (Drag & Drop), clic simple (copiar), doble clic (Preview),
/// pulsación larga (Marcación) y botones de acción en hover.
public final class TendederoCardView: NSView, NSDraggingSource {
    public weak var delegate: TendederoCardViewDelegate?
    public private(set) var item: TendederoItem
    
    public static let defaultWidth: CGFloat = 160
    public static let defaultHeight: CGFloat = 110
    
    private let cardContainer = NSView()
    private let imageView = NSImageView()
    private let clipView = NSView() // Pinza
    private let overlayControls = NSView()
    private let copyFeedbackBadge = NSTextField(labelWithString: "✓ Copiado")
    
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownLocation: CGPoint = .zero
    private var isDraggingSession = false
    private var didTriggerLongPress = false
    private var longPressTimer: Timer?
    private var isHovered = false
    
    public init(item: TendederoItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultHeight + 20))
        wantsLayer = true
        setupLayout()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func updateItem(_ newItem: TendederoItem) {
        self.item = newItem
        self.imageView.image = newItem.image
        needsDisplay = true
    }
    
    private func setupLayout() {
        // 1. Pinza superior (Clothespin)
        clipView.frame = NSRect(x: (bounds.width - 14) / 2, y: bounds.height - 24, width: 14, height: 24)
        clipView.wantsLayer = true
        if let cl = clipView.layer {
            cl.backgroundColor = NSColor(red: 0.88, green: 0.72, blue: 0.53, alpha: 1.0).cgColor // Tono madera
            cl.cornerRadius = 3
            cl.borderWidth = 0.5
            cl.borderColor = NSColor(white: 0.0, alpha: 0.25).cgColor
            cl.shadowColor = NSColor.black.cgColor
            cl.shadowOpacity = 0.3
            cl.shadowOffset = CGSize(width: 0, height: -1)
            cl.shadowRadius = 2
            
            // Muelle metálico en medio
            let spring = CALayer()
            spring.frame = CGRect(x: 1, y: 9, width: 12, height: 5)
            spring.backgroundColor = NSColor(white: 0.6, alpha: 0.9).cgColor
            spring.cornerRadius = 1
            cl.addSublayer(spring)
        }
        
        // 2. Contenedor de la tarjeta (con inclinación realista)
        let cardH = bounds.height - 22
        cardContainer.frame = NSRect(x: 6, y: 2, width: bounds.width - 12, height: cardH)
        cardContainer.wantsLayer = true
        
        if let clayer = cardContainer.layer {
            clayer.cornerRadius = 8
            clayer.masksToBounds = false
            clayer.shadowColor = NSColor.black.cgColor
            clayer.shadowOpacity = 0.28
            clayer.shadowRadius = 8
            clayer.shadowOffset = CGSize(width: 0, height: -4)
            clayer.borderWidth = 1.0
            clayer.borderColor = NSColor(white: 1.0, alpha: 0.3).cgColor
            clayer.backgroundColor = NSColor(white: 0.15, alpha: 0.85).cgColor
            
            // Aplicar inclinación suave
            let angle = CGFloat(item.tilt * .pi / 180.0)
            clayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        }
        
        // 3. Miniatura de la imagen
        imageView.frame = cardContainer.bounds.insetBy(dx: 4, dy: 4)
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = item.image
        if let imgLayer = imageView.layer {
            imgLayer.cornerRadius = 6
            imgLayer.masksToBounds = true
        }
        cardContainer.addSubview(imageView)
        
        // 4. Controles al pasar el cursor (Hover overlay)
        overlayControls.frame = cardContainer.bounds
        overlayControls.wantsLayer = true
        if let olayer = overlayControls.layer {
            olayer.backgroundColor = NSColor(white: 0.0, alpha: 0.65).cgColor
            olayer.cornerRadius = 8
        }
        overlayControls.alphaValue = 0.0
        setupHoverActionButtons()
        cardContainer.addSubview(overlayControls)
        
        // 5. Badge flotante temporal al copiar
        copyFeedbackBadge.frame = NSRect(x: 12, y: (cardContainer.bounds.height - 24) / 2, width: cardContainer.bounds.width - 24, height: 24)
        copyFeedbackBadge.alignment = .center
        copyFeedbackBadge.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        copyFeedbackBadge.textColor = .white
        copyFeedbackBadge.wantsLayer = true
        if let blayer = copyFeedbackBadge.layer {
            blayer.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor
            blayer.cornerRadius = 12
        }
        copyFeedbackBadge.alphaValue = 0.0
        cardContainer.addSubview(copyFeedbackBadge)
        
        addSubview(cardContainer)
        addSubview(clipView) // La pinza se dibuja por encima
    }
    
    private func setupHoverActionButtons() {
        let btnSize: CGFloat = 24
        let padding: CGFloat = 6
        
        // Botón Descartar (✕) arriba a la derecha
        let closeBtn = createActionButton(symbol: "xmark", tooltip: "Descartar captura") { [weak self] in
            guard let self = self else { return }
            self.delegate?.cardDidRequestDismiss(self, item: self.item)
        }
        closeBtn.frame = NSRect(x: overlayControls.bounds.width - btnSize - 6, y: overlayControls.bounds.height - btnSize - 6, width: btnSize, height: btnSize)
        overlayControls.addSubview(closeBtn)
        
        // Barra inferior de acciones (Copiar, Marcación, Preview)
        let actions: [(String, String, () -> Void)] = [
            ("doc.on.doc", "Copiar al portapapeles", { [weak self] in
                guard let self = self else { return }
                self.triggerCopy()
            }),
            ("pencil.tip.crop.circle", "Anotar con Marcación", { [weak self] in
                guard let self = self else { return }
                self.delegate?.cardDidRequestMarkup(self, item: self.item)
            }),
            ("eye", "Abrir en Vista Previa", { [weak self] in
                guard let self = self else { return }
                self.delegate?.cardDidRequestPreview(self, item: self.item)
            })
        ]
        
        let totalW = CGFloat(actions.count) * btnSize + CGFloat(actions.count - 1) * padding
        var startX = (overlayControls.bounds.width - totalW) / 2
        let startY: CGFloat = 10
        
        for (symbol, tip, action) in actions {
            let btn = createActionButton(symbol: symbol, tooltip: tip, action: action)
            btn.frame = NSRect(x: startX, y: startY, width: btnSize, height: btnSize)
            overlayControls.addSubview(btn)
            startX += btnSize + padding
        }
    }
    
    private func createActionButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let btn = CardActionButton(frame: .zero, action: action)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.wantsLayer = true
        btn.toolTip = tooltip
        
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            img.isTemplate = true
            btn.image = img
            btn.contentTintColor = .white
        }
        
        if let bl = btn.layer {
            bl.backgroundColor = NSColor(white: 0.25, alpha: 0.8).cgColor
            bl.cornerRadius = 12
        }
        return btn
    }
    
    // MARK: - Efecto Copiado
    
    public func triggerCopy() {
        delegate?.cardDidRequestCopy(self, item: item)
        showCopyFeedback()
    }
    
    public func showCopyFeedback() {
        copyFeedbackBadge.alphaValue = 1.0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.cardContainer.animator().alphaValue = 0.8
        }, completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    self.copyFeedbackBadge.animator().alphaValue = 0.0
                    self.cardContainer.animator().alphaValue = 1.0
                }
            }
        })
    }
    
    // MARK: - Tracking Hover
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }
    
    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.overlayControls.animator().alphaValue = 1.0
            self.cardContainer.layer?.transform = CATransform3DMakeScale(1.05, 1.05, 1.0)
        }
    }
    
    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.overlayControls.animator().alphaValue = 0.0
            let angle = CGFloat(self.item.tilt * .pi / 180.0)
            self.cardContainer.layer?.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        }
    }
    
    // MARK: - Eventos de Ratón y Gestos
    
    public override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isDraggingSession = false
        didTriggerLongPress = false
        
        // Long Press: si se mantiene presionado 0.5s, abrir en Marcación
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self = self, !self.isDraggingSession else { return }
            self.didTriggerLongPress = true
            self.delegate?.cardDidRequestMarkup(self, item: self.item)
        }
    }
    
    public override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        
        guard !isDraggingSession, !didTriggerLongPress else { return }
        
        if event.clickCount == 2 {
            // Doble clic: abrir en Vista Previa
            delegate?.cardDidRequestPreview(self, item: item)
        } else if event.clickCount == 1 {
            // Clic simple: copiar al portapapeles
            triggerCopy()
        }
    }
    
    // MARK: - Arrastre (Drag & Drop)
    
    public override func mouseDragged(with event: NSEvent) {
        let currentLocation = event.locationInWindow
        let dx = abs(currentLocation.x - mouseDownLocation.x)
        let dy = abs(currentLocation.y - mouseDownLocation.y)
        
        if dx > 6 || dy > 6 {
            longPressTimer?.invalidate()
            longPressTimer = nil
            
            if !isDraggingSession {
                isDraggingSession = true
                startDraggingSession(with: event)
            }
        }
    }
    
    private func startDraggingSession(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.path, forType: .fileURL)
        
        if let tiff = item.image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboardItem.setData(png, forType: .png)
        }
        
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dragBounds = cardContainer.bounds
        let dragImage = item.image
        draggingItem.setDraggingFrame(NSRect(origin: convert(cardContainer.frame.origin, to: nil), size: dragBounds.size), contents: dragImage)
        
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    
    // MARK: - NSDraggingSource
    
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .generic] : [.copy]
    }
    
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSession = false
    }
}

private final class CardActionButton: NSButton {
    private let actionBlock: () -> Void
    init(frame: NSRect, action: @escaping () -> Void) {
        self.actionBlock = action
        super.init(frame: frame)
        self.target = self
        self.action = #selector(handleClick)
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    @objc private func handleClick() {
        actionBlock()
    }
}
