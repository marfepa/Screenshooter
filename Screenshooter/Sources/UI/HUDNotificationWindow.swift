import AppKit

/// Ventana flotante translúcida tipo HUD (Toast) que confirma la captura
/// y la copia automática al portapapeles durante 1.5 segundos.
public final class HUDNotificationWindow: NSWindow {
    private var dismissTimer: Timer?
    private var fileURL: URL?
    private var cgImage: CGImage?
    
    public init(cgImage: CGImage, pixelSize: CGSize, fileURL: URL? = nil) {
        self.cgImage = cgImage
        self.fileURL = fileURL
        
        let width: CGFloat = 280
        let height: CGFloat = 68
        
        // Posicionar en la esquina superior derecha de la pantalla principal
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenRect = screen.visibleFrame
        let origin = CGPoint(
            x: screenRect.maxX - width - 20,
            y: screenRect.maxY - height - 20
        )
        
        super.init(
            contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.isReleasedWhenClosed = false
        
        setupContent(cgImage: cgImage, pixelSize: pixelSize)
    }
    
    public override var canBecomeKey: Bool {
        return false
    }
    
    private func setupContent(cgImage: CGImage, pixelSize: CGSize) {
        let visualEffectView = HUDContainerView(frame: contentView?.bounds ?? .zero)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 10
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        
        visualEffectView.onHoverChanged = { [weak self] isHovered in
            if isHovered {
                self?.dismissTimer?.invalidate()
                self?.dismissTimer = nil
            } else {
                self?.scheduleDismiss(delay: 1.5)
            }
        }
        
        // Miniatura arrastrable
        let thumbView = HUDDraggableThumbView(frame: CGRect(x: 12, y: 12, width: 54, height: 44), image: NSImage(cgImage: cgImage, size: CGSize(width: 54, height: 44)), fileURL: fileURL)
        visualEffectView.addSubview(thumbView)
        
        // Título "✓ Copiado al portapapeles"
        let titleLabel = NSTextField(labelWithString: "✓ Copiado al portapapeles")
        titleLabel.frame = CGRect(x: 74, y: 36, width: 160, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        titleLabel.textColor = NSColor.systemGreen
        visualEffectView.addSubview(titleLabel)
        
        // Subtítulo con dimensiones
        let dimText = "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px · Arrastra o anota"
        let subtitleLabel = NSTextField(labelWithString: dimText)
        subtitleLabel.frame = CGRect(x: 74, y: 16, width: 160, height: 16)
        subtitleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        visualEffectView.addSubview(subtitleLabel)
        
        // Botón Anotar (Lápiz)
        if let targetURL = fileURL {
            let markupBtn = HUDActionButton(frame: CGRect(x: 242, y: 20, width: 28, height: 28)) { [weak self] in
                self?.dismiss()
                MarkupService.shared.edit(url: targetURL)
            }
            markupBtn.bezelStyle = .inline
            markupBtn.isBordered = false
            markupBtn.wantsLayer = true
            markupBtn.layer?.cornerRadius = 14
            markupBtn.layer?.backgroundColor = NSColor(white: 0.25, alpha: 0.8).cgColor
            if let icon = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Anotar con Marcación") {
                icon.isTemplate = true
                markupBtn.image = icon
                markupBtn.contentTintColor = .white
            }
            markupBtn.toolTip = "Anotar con Marcación"
            visualEffectView.addSubview(markupBtn)
        }
        
        contentView = visualEffectView
    }
    
    public func present() {
        self.alphaValue = 0
        self.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1.0
        }
        
        scheduleDismiss(delay: 2.0)
    }
    
    private func scheduleDismiss(delay: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }
    
    public func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
            self.close()
        })
    }
}

private final class HUDContainerView: NSVisualEffectView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

private final class HUDDraggableThumbView: NSImageView, NSDraggingSource {
    private let fileURL: URL?
    private var dragStart: CGPoint = .zero
    
    init(frame: NSRect, image: NSImage, fileURL: URL?) {
        self.fileURL = fileURL
        super.init(frame: frame)
        self.image = image
        self.imageScaling = .scaleProportionallyUpOrDown
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.layer?.masksToBounds = true
        self.layer?.borderWidth = 0.5
        self.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
    }
    
    override func mouseDragged(with event: NSEvent) {
        let loc = event.locationInWindow
        if abs(loc.x - dragStart.x) > 4 || abs(loc.y - dragStart.y) > 4 {
            let item = NSPasteboardItem()
            if let url = fileURL {
                item.setString(url.path, forType: .fileURL)
            }
            if let tiff = image?.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
            
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            dragItem.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [dragItem], event: event, source: self)
        }
    }
    
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? [.copy, .generic] : [.copy]
    }
}

private final class HUDActionButton: NSButton {
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
