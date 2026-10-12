import AppKit

/// Vista previa lateral del cosido: miniatura del lienzo junto al área, ignorada por el ratón.
@MainActor
final class ScrollCapturePreviewWindow: NSPanel {
    static let panelWidth: CGFloat = 122
    static let gap: CGFloat = 14
    static let inset: CGFloat = 6
    static var innerWidth: CGFloat { panelWidth - inset * 2 }

    /// Colocación: a la derecha del área con 14 pt de separación; si no cabe, a la izquierda; si tampoco, `nil`.
    /// Alto = alto del área, acotado verticalmente al `visibleFrame`.
    static func previewFrame(for rect: CGRect, in visibleFrame: CGRect) -> CGRect? {
        let minY = max(rect.minY, visibleFrame.minY)
        let maxY = min(rect.maxY, visibleFrame.maxY)
        guard maxY > minY else { return nil }
        let height = maxY - minY
        let right = CGRect(x: rect.maxX + gap, y: minY, width: panelWidth, height: height)
        if right.maxX <= visibleFrame.maxX { return right }
        let left = CGRect(x: rect.minX - gap - panelWidth, y: minY, width: panelWidth, height: height)
        if left.minX >= visibleFrame.minX { return left }
        return nil
    }

    private let targetFrame: CGRect?
    private let glass = GlassSurface(shape: .rounded(10))
    private let imageView = ScrollCapturePreviewImageView()

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        targetFrame = nil
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    init(rect: CGRect, screen: NSScreen) {
        targetFrame = Self.previewFrame(for: rect, in: screen.visibleFrame)
        super.init(
            contentRect: targetFrame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Evitar double-free con ARC (ver Trampas del ámbito)
        isReleasedWhenClosed = false
        buildContent()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `false` si no cabe en ningún lado: `present()` y `update(preview:)` no hacen nada.
    var isPlaceable: Bool { targetFrame != nil }

    private func buildContent() {
        let root = NSView()
        // Redundante con el contador de la píldora: oculta a VoiceOver.
        root.setAccessibilityElement(false)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        imageView.autoresizingMask = [.width, .height]
        imageView.setAccessibilityElement(false)
        root.addSubview(imageView)
        contentView = root
        layoutContent()
    }

    private func layoutContent() {
        guard let root = contentView else { return }
        glass.frame = root.bounds
        imageView.frame = root.bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    func present() {
        guard let targetFrame else { return }
        setFrame(targetFrame, display: false)
        layoutContent()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
            orderFrontRegardless()
        } else {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    func update(preview: CGImage) {
        guard targetFrame != nil else { return }
        imageView.image = preview
    }

    func dismiss() {
        orderOut(nil)
        close()
    }
}

/// Dibuja la miniatura al ancho interior, alineada arriba; si es más alta que la vista, muestra la parte de abajo
/// (lo último cosido) con un degradado superior.
final class ScrollCapturePreviewImageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    private static let fadeHeight: CGFloat = 14

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Rectángulo (en coordenadas de la vista, origen abajo) donde se dibuja la imagen.
    static func drawRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0 else { return .zero }
        let scaledHeight = imageSize.height * bounds.width / imageSize.width
        if scaledHeight <= bounds.height {
            return CGRect(x: bounds.minX, y: bounds.maxY - scaledHeight, width: bounds.width, height: scaledHeight)
        }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: scaledHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        clip.addClip()
        ctx.interpolationQuality = .medium
        let target = Self.drawRect(imageSize: CGSize(width: image.width, height: image.height), in: bounds)
        ctx.draw(image, in: target)
        if target.height > bounds.height {
            let top = NSRect(x: bounds.minX, y: bounds.maxY - Self.fadeHeight, width: bounds.width, height: Self.fadeHeight)
            let fill = NSColor.windowBackgroundColor
            NSGradient(colors: [fill.withAlphaComponent(0), fill.withAlphaComponent(0.9)])?.draw(in: top, angle: 90)
        }
        ctx.restoreGState()
    }
}
