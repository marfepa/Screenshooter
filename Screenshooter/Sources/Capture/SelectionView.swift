import AppKit

/// Vista personalizada encargada de dibujar el velo de pantalla completa,
/// el recuadro de recorte interactivo y la insignia con las dimensiones en tiempo real.
public final class SelectionView: NSView {
    public let screen: NSScreen
    
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var isSpaceDragging = false
    private var spaceDragOffset: CGPoint = .zero
    
    public var onSelectionCompleted: ((CGRect, NSScreen) -> Void)?
    public var onCancelled: (() -> Void)?
    
    public init(frame: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frame)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override var acceptsFirstResponder: Bool {
        return true
    }
    
    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }
    
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        
        if event.modifierFlags.contains(.numericPad) || isSpaceDragging {
            // Mover recuadro existente
            let dx = point.x - (currentPoint?.x ?? point.x)
            let dy = point.y - (currentPoint?.y ?? point.y)
            startPoint = CGPoint(x: start.x + dx, y: start.y + dy)
        }
        
        currentPoint = point
        needsDisplay = true
    }
    
    public override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let current = currentPoint else {
            onCancelled?()
            return
        }
        
        let rect = currentSelectionRect(start: start, current: current)
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
        
        // Si el área es menor a 4x4 px (un clic involuntario), cancelar
        if rect.width < 4 || rect.height < 4 {
            onCancelled?()
            return
        }
        
        // Convertir coordenadas locales de la vista a coordenadas de pantalla (AppKit screen coordinates)
        let screenRect = window?.convertToScreen(rect) ?? rect
        onSelectionCompleted?(screenRect, screen)
    }
    
    public override func keyDown(with event: NSEvent) {
        // Tecla ESC (código 53)
        if event.keyCode == 53 {
            onCancelled?()
            return
        }
        
        // Barra espaciadora para mover el recuadro durante el arrastre
        if event.keyCode == 49 {
            isSpaceDragging = true
        }
        
        // Consumir el evento silenciosamente para evitar el sonido de error del sistema
    }
    
    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDragging = false
        }
        super.keyUp(with: event)
    }
    
    private func currentSelectionRect(start: CGPoint, current: CGPoint) -> CGRect {
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(current.x - start.x)
        let height = abs(current.y - start.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        // 1. Dibujar velo oscuro uniforme
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        context.fill(bounds)
        
        if let start = startPoint, let current = currentPoint {
            let rect = currentSelectionRect(start: start, current: current)
            
            // 2. Despejar el área seleccionada para que el escritorio brille con claridad total
            context.setBlendMode(.clear)
            context.fill(rect)
            context.setBlendMode(.normal)
            
            // 3. Dibujar marco de selección azul acentuado de macOS
            let strokeColor = NSColor.systemBlue.withAlphaComponent(0.9)
            strokeColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()
            
            // 4. Insignia flotante con dimensiones (Ancho × Alto)
            let pointsText = "\(Int(rect.width)) × \(Int(rect.height))"
            let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: NSColor.white
            ]
            let textSize = (pointsText as NSString).size(withAttributes: badgeAttrs)
            
            let badgePaddingH: CGFloat = 8
            let badgePaddingV: CGFloat = 4
            let badgeWidth = textSize.width + badgePaddingH * 2
            let badgeHeight = textSize.height + badgePaddingV * 2
            
            var badgeX = rect.midX - (badgeWidth / 2)
            badgeX = max(10, min(badgeX, bounds.width - badgeWidth - 10))
            
            var badgeY = rect.minY - badgeHeight - 6
            if badgeY < 10 {
                badgeY = rect.maxY + 6
            }
            
            let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
            NSColor(white: 0.12, alpha: 0.95).setFill()
            badgePath.fill()
            
            NSColor(white: 1.0, alpha: 0.15).setStroke()
            badgePath.lineWidth = 0.5
            badgePath.stroke()
            
            let textRect = CGRect(
                x: badgeX + badgePaddingH,
                y: badgeY + badgePaddingV - 0.5,
                width: textSize.width,
                height: textSize.height
            )
            (pointsText as NSString).draw(in: textRect, withAttributes: badgeAttrs)
        } else {
            // 5. Barra flotante con instrucciones iniciales
            drawInstructionBar()
        }
    }
    
    private func drawInstructionBar() {
        let text = String(localized: "Drag to select  ·  ESC to cancel", bundle: L10n.bundle, locale: L10n.locale, comment: "Instruction bar shown over the dimmed screen during area selection")
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        
        let padH: CGFloat = 16
        let padV: CGFloat = 8
        let barW = textSize.width + padH * 2
        let barH = textSize.height + padV * 2
        let barX = (bounds.width - barW) / 2
        let barY = bounds.height - barH - 40
        
        let barRect = CGRect(x: barX, y: barY, width: barW, height: barH)
        let path = NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2)
        NSColor(white: 0.1, alpha: 0.92).setFill()
        path.fill()
        
        NSColor(white: 1.0, alpha: 0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        
        let textDrawRect = CGRect(x: barX + padH, y: barY + padV, width: textSize.width, height: textSize.height)
        (text as NSString).draw(in: textDrawRect, withAttributes: attrs)
    }
}
