import AppKit

/// Ventana flotante translúcida tipo HUD (Toast) que confirma la captura
/// y la copia automática al portapapeles durante 1.5 segundos.
public final class HUDNotificationWindow: NSWindow {
    private var dismissTimer: Timer?
    
    public init(cgImage: CGImage, pixelSize: CGSize) {
        let width: CGFloat = 260
        let height: CGFloat = 64
        
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
        // Desactivar la liberación automática de AppKit al cerrar para evitar
        // double-free con ARC (NSWindow.close() envía un release extra por defecto).
        self.isReleasedWhenClosed = false
        
        setupContent(cgImage: cgImage, pixelSize: pixelSize)
    }
    
    public override var canBecomeKey: Bool {
        return false
    }
    
    private func setupContent(cgImage: CGImage, pixelSize: CGSize) {
        let visualEffectView = NSVisualEffectView(frame: contentView?.bounds ?? .zero)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 10
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        
        // Miniatura
        let thumbView = NSImageView(frame: CGRect(x: 12, y: 12, width: 50, height: 40))
        let thumbImage = NSImage(cgImage: cgImage, size: NSSize(width: 50, height: 40))
        thumbView.image = thumbImage
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 4
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.borderWidth = 0.5
        thumbView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        visualEffectView.addSubview(thumbView)
        
        // Título "✓ Copiado al portapapeles"
        let titleLabel = NSTextField(labelWithString: "✓ Copiado al portapapeles")
        titleLabel.frame = CGRect(x: 70, y: 32, width: 175, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NSColor.systemGreen
        visualEffectView.addSubview(titleLabel)
        
        // Subtítulo con dimensiones
        let dimText = "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px · En memoria"
        let subtitleLabel = NSTextField(labelWithString: dimText)
        subtitleLabel.frame = CGRect(x: 70, y: 14, width: 175, height: 16)
        subtitleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.textColor = NSColor.secondaryLabelColor
        visualEffectView.addSubview(subtitleLabel)
        
        contentView = visualEffectView
    }
    
    public func present() {
        self.alphaValue = 0
        self.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1.0
        }
        
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
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
