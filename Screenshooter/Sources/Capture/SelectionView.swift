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
    /// Selección soltada con ⇧ (o con `forcesScrollCapture`): empieza la captura larga en vez de la captura normal.
    public var onScrollCaptureSelected: ((CGRect, NSScreen) -> Void)?
    public var onCancelled: (() -> Void)?
    /// Scroll de trackpad o rueda fuera de un arrastre: el coordinador deja pasar los eventos a la app de debajo.
    public var onScrollPassthrough: ((NSEvent) -> Void)?
    
    /// Velo tenue mientras el scroll pasa a la app de debajo (sin barra de instrucciones ni cursor en cruz).
    public var isPassthrough = false {
        didSet {
            guard isPassthrough != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    
    /// Entrada desde el menú «Captura larga…»: toda selección de esta vista es una captura larga.
    public var forcesScrollCapture = false {
        didSet { if forcesScrollCapture != oldValue { needsDisplay = true } }
    }
    /// Contador de usos de la línea de ayuda (inyectable en tests).
    var helpDefaults: UserDefaults = .standard
    /// ⇧ pulsado durante el arrastre actual.
    private var shiftHeld = false
    private var announcedShiftInDrag = false
    
    /// Decide si una selección soltada es captura larga.
    static func isScrollCapture(flags: NSEvent.ModifierFlags, forces: Bool) -> Bool {
        forces || ScrollCaptureModel.wantsScrollCapture(flags)
    }
    
    private var isScrollMode: Bool { forcesScrollCapture || shiftHeld }
    
    private func updateShift(_ flags: NSEvent.ModifierFlags) {
        let held = ScrollCaptureModel.wantsScrollCapture(flags)
        guard held != shiftHeld else { return }
        shiftHeld = held
        needsDisplay = true
        if held, startPoint != nil, !announcedShiftInDrag, !forcesScrollCapture {
            announcedShiftInDrag = true
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: String(localized: "Long capture", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver announcement when Shift is pressed during a selection drag"),
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }
    
    public override func flagsChanged(with event: NSEvent) {
        updateShift(event.modifierFlags)
        super.flagsChanged(with: event)
    }
    
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
        if !isPassthrough {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
    
    public override func scrollWheel(with event: NSEvent) {
        // Durante un arrastre el scroll no debe romper la selección
        guard startPoint == nil, !isPassthrough else { return }
        onScrollPassthrough?(event)
    }
    
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        announcedShiftInDrag = false
        updateShift(event.modifierFlags)
        needsDisplay = true
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateShift(event.modifierFlags)
        
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
        // Modo continuo: un clic suelto no sale del modo (solo ESC lo hace)
        guard let start = startPoint, let current = currentPoint else { return }

        let rect = currentSelectionRect(start: start, current: current)
        startPoint = nil
        currentPoint = nil
        shiftHeld = false
        announcedShiftInDrag = false
        needsDisplay = true

        // Si el área es menor a 4x4 px (un clic involuntario), ignorarla y seguir seleccionando
        if rect.width < 4 || rect.height < 4 {
            return
        }
        
        // Convertir coordenadas locales de la vista a coordenadas de pantalla (AppKit screen coordinates)
        let screenRect = window?.convertToScreen(rect) ?? rect
        if Self.isScrollCapture(flags: event.modifierFlags, forces: forcesScrollCapture) {
            onScrollCaptureSelected?(screenRect, screen)
        } else {
            onSelectionCompleted?(screenRect, screen)
        }
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
        
        // 1. Dibujar velo oscuro uniforme (tenue mientras el scroll pasa a la app de debajo;
        //    con Reducir transparencia algo más marcado para que se distinga el modo)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let veilAlpha: CGFloat = isPassthrough ? (reduceTransparency ? 0.25 : 0.12) : 0.38
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: veilAlpha))
        context.fill(bounds)
        
        if isPassthrough {
            return
        }
        
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
            
            // 5. Etiqueta de captura larga (⇧ o menú) y, si procede, línea de ayuda
            var extraBelow = badgeRect
            if isScrollMode {
                let label = String(localized: "Long capture ↕", bundle: L10n.bundle, locale: L10n.locale, comment: "Label next to the size badge while Shift is held: releasing starts a long (scrolling) capture")
                var labelRect = pillRect(for: label, font: badgeFont, height: badgeHeight, x: badgeRect.maxX + 6, y: badgeY)
                if labelRect.maxX > bounds.width - 10 {
                    labelRect.origin.x = badgeRect.minX - 6 - labelRect.width
                }
                drawPill(label, in: labelRect, fill: NSColor.controlAccentColor, font: badgeFont)
                extraBelow = extraBelow.union(labelRect)
            } else if ScrollCaptureHelpHint.shouldShow(defaults: helpDefaults) {
                let help = String(localized: "Hold ⇧ when releasing for a long capture", bundle: L10n.bundle, locale: L10n.locale, comment: "Secondary hint under the size badge while selecting an area")
                let helpFont = NSFont.systemFont(ofSize: 11, weight: .regular)
                let helpHeight = badgeHeight - 2
                var helpRect = pillRect(for: help, font: helpFont, height: helpHeight, x: 0, y: 0)
                helpRect.origin.x = max(10, min(rect.midX - helpRect.width / 2, bounds.width - helpRect.width - 10))
                let below = badgeY < rect.minY
                helpRect.origin.y = below ? extraBelow.minY - helpHeight - 4 : extraBelow.maxY + 4
                if helpRect.minY >= 4, helpRect.maxY <= bounds.height - 4 {
                    drawPill(help, in: helpRect, fill: NSColor(white: 0.12, alpha: 0.85), font: helpFont)
                }
            }
        } else {
            // 5. Barra flotante con instrucciones iniciales
            drawInstructionBar()
        }
    }
    
    private func pillRect(for text: String, font: NSFont, height: CGFloat, x: CGFloat, y: CGFloat) -> CGRect {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGRect(x: x, y: y, width: size.width + 16, height: height)
    }
    
    private func drawPill(_ text: String, in rect: CGRect, fill: NSColor, font: NSFont) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        fill.setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: rect.minX + (rect.width - size.width) / 2, y: rect.minY + (rect.height - size.height) / 2),
            withAttributes: attrs
        )
    }
    
    private func drawInstructionBar() {
        let text = String(localized: "Drag to capture  ·  Swipe to scroll  ·  ⌥⌘S to navigate  ·  ESC to exit", bundle: L10n.bundle, locale: L10n.locale, comment: "Instruction bar shown over the dimmed screen during continuous area selection")
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
