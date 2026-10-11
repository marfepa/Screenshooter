import AppKit
import QuartzCore

/// Demostraciones de la bienvenida dibujadas directamente sobre la pantalla del usuario
/// (velo, cruz fantasma, huellas, Tira de ejemplo) con Core Animation.
///
/// Cada demo corre en bucle un máximo de `loops` veces (WCAG 2.2.2) y después queda en un
/// fotograma explicativo fijo, que es también lo único que se ve con Reducir movimiento:
/// los valores del modelo son ese fotograma y las animaciones se añaden encima.
final class OnboardingDemoView: NSView {
    /// Rectángulo del icono de la barra de menús, en coordenadas de esta vista con origen arriba-izquierda.
    var statusItemRect: CGRect?
    /// Altura de la barra de menús de esta pantalla (la Tira cuelga justo debajo).
    var menuBarHeight: CGFloat = 24
    /// Hueco inferior reservado al texto (el degradado oscuro lo cubre).
    var scrimHeight: CGFloat = 320
    /// Solo el velo (pantallas secundarias).
    var veilOnly = false

    private(set) var isPaused = false
    private let loops: Float = 3
    private let canvas = CALayer()
    private let veil = CAShapeLayer()
    private let scrim = CAGradientLayer()
    private let content = CALayer()
    private var step: OnboardingStep?

    private static let veilAlpha: CGFloat = 0.55

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(canvas)
        canvas.isGeometryFlipped = true
        veil.fillRule = .evenOdd
        veil.fillColor = NSColor.black.cgColor
        canvas.addSublayer(veil)
        canvas.addSublayer(content)
        scrim.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                        NSColor.black.withAlphaComponent(0.55).cgColor,
                        NSColor.black.withAlphaComponent(0.72).cgColor]
        scrim.locations = [0, 0.45, 1]
        canvas.addSublayer(scrim)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// El velo intercepta los clics: nada llega a las apps de debajo mientras dura la bienvenida.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        content.frame = bounds
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        scrim.isHidden = veilOnly
        scrim.frame = CGRect(x: 0, y: bounds.height - scrimHeight, width: bounds.width, height: scrimHeight)
        scrim.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                        NSColor.black.withAlphaComponent(contrast ? 0.72 : 0.55).cgColor,
                        NSColor.black.withAlphaComponent(contrast ? 0.85 : 0.72).cgColor]
        CATransaction.commit()
        if let step { show(step) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        canvas.contentsScale = scale
    }

    // MARK: - Control

    func show(_ step: OnboardingStep) {
        self.step = step
        isPaused = false
        canvas.speed = 1
        canvas.timeOffset = 0
        canvas.beginTime = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Puede llamarse antes del primer `layout()`: el lienzo debe medir ya la pantalla
        canvas.frame = bounds
        content.frame = bounds
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        veil.removeAllAnimations()
        veil.opacity = 1
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        veil.fillColor = NSColor.black.withAlphaComponent(contrast ? 0.72 : Self.veilAlpha).cgColor
        veil.path = Self.veilPath(bounds, hole: nil)
        setAccessibilityLabel(OnboardingText.illustration(step))

        if !veilOnly {
            switch step {
            case .welcome: buildWelcome()
            case .permission: break
            case .capture: buildCapture()
            case .touch: buildTouch()
            case .strip: buildStrip()
            }
        } else if step == .touch {
            buildTouchVeilOnly()
        }
        CATransaction.commit()
    }

    /// Pausa o reanuda. Si el bucle ya terminó, «reproducir» lo vuelve a empezar.
    func togglePause() {
        if isPaused {
            let paused = canvas.timeOffset
            canvas.speed = 1
            canvas.timeOffset = 0
            canvas.beginTime = 0
            canvas.beginTime = canvas.convertTime(CACurrentMediaTime(), from: nil) - paused
            isPaused = false
        } else if hasRunningAnimations {
            let now = canvas.convertTime(CACurrentMediaTime(), from: nil)
            canvas.speed = 0
            canvas.timeOffset = now
            isPaused = true
        } else if let step {
            show(step)
        }
    }

    var hasRunningAnimations: Bool {
        let layers = [veil] + (content.sublayers ?? []) + (content.sublayers ?? []).flatMap { $0.sublayers ?? [] }
        return layers.contains { !($0.animationKeys() ?? []).isEmpty }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Pasos

    private func buildWelcome() {
        let iconSize: CGFloat = 168
        let center = CGPoint(x: bounds.midX, y: max(menuBarHeight + iconSize, (bounds.height - scrimHeight) * 0.5))
        let icon = CALayer()
        icon.contents = NSApp.applicationIconImage
        icon.contentsGravity = .resizeAspect
        icon.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        icon.position = center
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.45
        icon.shadowRadius = 20
        icon.shadowOffset = CGSize(width: 0, height: 12)
        content.addSublayer(icon)
        if !reduceMotion {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.6
            spring.toValue = 1
            spring.damping = 12
            spring.initialVelocity = 4
            spring.duration = spring.settlingDuration
            icon.add(spring, forKey: "in")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            icon.add(fade, forKey: "fade")
        }

        guard let item = statusItemRect else { return }
        let hole = item.insetBy(dx: -4, dy: -2)
        veil.path = Self.veilPath(bounds, hole: hole, radius: 6)

        let ring = CAShapeLayer()
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: hole.size), cornerWidth: 6, cornerHeight: 6, transform: nil)
        ring.bounds = CGRect(origin: .zero, size: hole.size)
        ring.position = CGPoint(x: hole.midX, y: hole.midY)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 2
        ring.shadowColor = NSColor.controlAccentColor.cgColor
        ring.shadowOpacity = 1
        ring.shadowRadius = 4
        ring.shadowOffset = .zero
        content.addSublayer(ring)
        if !reduceMotion {
            let pulse = CAAnimationGroup()
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            pulse.animations = [scale, fade]
            pulse.duration = 1.6
            pulse.repeatCount = loops
            ring.add(pulse, forKey: "pulse")
        }

        let hint = Self.hintLayer(OnboardingText.hereItIs, scale: contentsScale)
        hint.position = CGPoint(x: min(max(hole.midX, hint.bounds.width / 2 + 8), bounds.width - hint.bounds.width / 2 - 8),
                                y: hole.maxY + 14 + hint.bounds.height / 2)
        content.addSublayer(hint)
    }

    private func buildCapture() {
        let duration: CFTimeInterval = 6
        let size = CGSize(width: 300, height: 170)
        let usable = bounds.height - scrimHeight
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: max(menuBarHeight + 120, usable * 0.5 - size.height / 2))
        let rect = CGRect(origin: origin, size: size)
        let empty = CGRect(origin: origin, size: .zero)

        // Fotograma fijo: selección hecha, cruz en la esquina, medida visible
        veil.path = Self.veilPath(bounds, hole: rect)
        animate(veil, duration: duration, [
            Self.keyframes("path",
                           [Self.veilPath(bounds, hole: empty), Self.veilPath(bounds, hole: empty), Self.veilPath(bounds, hole: rect),
                            Self.veilPath(bounds, hole: rect), Self.veilPath(bounds, hole: empty), Self.veilPath(bounds, hole: empty)],
                           [0, 0.18, 0.5, 0.58, 0.6, 1])
        ])

        let border = CALayer()
        border.anchorPoint = .zero
        border.position = origin
        border.bounds = CGRect(origin: .zero, size: size)
        border.borderColor = NSColor.systemBlue.cgColor
        border.borderWidth = 2
        content.addSublayer(border)
        animate(border, duration: duration, [
            Self.keyframes("bounds.size", [CGSize.zero, CGSize.zero, size, size, size], [0, 0.18, 0.5, 0.58, 1]),
            Self.keyframes("opacity", [0, 0, 1, 1, 0, 0], [0, 0.18, 0.2, 0.58, 0.6, 1])
        ])

        let ghost = Self.crosshairLayer()
        ghost.position = CGPoint(x: rect.maxX, y: rect.maxY)
        content.addSublayer(ghost)
        animate(ghost, duration: duration, [
            Self.keyframes("position", [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY),
                                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)],
                           [0, 0.16, 0.5, 1])
        ])

        let badge = Self.hintLayer("\(Int(size.width)) × \(Int(size.height))", scale: contentsScale, mono: true)
        badge.position = CGPoint(x: rect.midX, y: rect.maxY + 8 + badge.bounds.height / 2)
        content.addSublayer(badge)
        animate(badge, duration: duration, [Self.keyframes("opacity", [0, 0, 1, 1, 0, 0], [0, 0.46, 0.5, 0.58, 0.6, 1])])

        let flash = CALayer()
        flash.frame = rect
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        content.addSublayer(flash)
        animate(flash, duration: duration, [Self.keyframes("opacity", [0, 0, 0.85, 0, 0], [0, 0.58, 0.6, 0.68, 1])])

        // Miniatura que vuela a la Tira, justo bajo la barra de menús
        let target = CGPoint(x: bounds.midX, y: menuBarHeight + 52)
        let thumb = Self.cardLayer(size: size)
        thumb.position = CGPoint(x: rect.midX, y: rect.midY)
        thumb.opacity = 0
        content.addSublayer(thumb)
        var landed = CATransform3DMakeTranslation(target.x - rect.midX, target.y - rect.midY, 0)
        landed = CATransform3DScale(landed, 0.3, 0.3, 1)
        landed = CATransform3DRotate(landed, -0.07, 0, 0, 1)
        animate(thumb, duration: duration, [
            Self.keyframes("opacity", [0, 0, 1, 1], [0, 0.6, 0.62, 1]),
            Self.keyframes("transform", [CATransform3DIdentity, CATransform3DIdentity, landed, landed], [0, 0.6, 0.82, 1])
        ])

        let rope = Self.ropeLayer(width: 600, y: menuBarHeight + 16, midX: bounds.midX)
        rope.opacity = 0
        content.addSublayer(rope)
        animate(rope, duration: duration, [Self.keyframes("opacity", [0, 0, 1, 1], [0, 0.6, 0.66, 1])])

        let keys = Self.keysLayer(["⌥", "⌘", "S"], scale: contentsScale)
        keys.position = CGPoint(x: bounds.midX, y: max(menuBarHeight + 70, origin.y - 60))
        content.addSublayer(keys)
        animate(keys, duration: duration, [
            Self.keyframes("opacity", [0, 0, 1, 1, 0, 0], [0, 0.02, 0.05, 0.3, 0.36, 1]),
            Self.keyframes("transform.scale", [1, 1, 0.9, 1, 1], [0, 0.05, 0.08, 0.11, 1])
        ])
    }

    private func buildTouch() {
        let duration: CFTimeInterval = 8
        let usable = bounds.height - scrimHeight
        let center = CGPoint(x: bounds.midX, y: max(menuBarHeight + 160, usable * 0.55))

        // Fotograma fijo: pantalla aclarada con las huellas y «Haz scroll o cambia de app»
        veil.opacity = 0.15
        animate(veil, duration: duration, [Self.keyframes("opacity", [1, 1, 0.15, 0.15, 1, 1], [0, 0.1, 0.16, 0.78, 0.86, 1])])

        let fingers = CALayer()
        fingers.bounds = CGRect(x: 0, y: 0, width: 66, height: 26)
        fingers.position = center
        for x in [13.0, 53.0] {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
            dot.position = CGPoint(x: x, y: 13)
            dot.cornerRadius = 13
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
            dot.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
            dot.borderWidth = 6
            dot.shadowOpacity = 0.4
            dot.shadowRadius = 6
            dot.shadowOffset = CGSize(width: 0, height: -3)
            fingers.addSublayer(dot)
        }
        content.addSublayer(fingers)
        let up = CGPoint(x: center.x, y: center.y - 60)
        animate(fingers, duration: duration, [
            Self.keyframes("opacity", [0, 0, 1, 1, 0, 0], [0, 0.04, 0.08, 0.3, 0.34, 1]),
            Self.keyframes("position", [center, center, center, up, up], [0, 0.08, 0.14, 0.3, 1]),
            Self.keyframes("transform.scale", [1.4, 1.4, 1, 1], [0, 0.04, 0.08, 1])
        ])

        let hints = [OnboardingText.hintTouch, OnboardingText.hintScroll, OnboardingText.hintBack]
        let windows: [[Double]] = [[0, 0.06, 0.09, 0.32, 0.35, 1], [0, 0.36, 0.39, 0.62, 0.65, 1], [0, 0.66, 0.69, 0.96, 0.99, 1]]
        for (i, text) in hints.enumerated() {
            let hint = Self.hintLayer(text, scale: contentsScale)
            hint.position = CGPoint(x: bounds.midX, y: menuBarHeight + 40 + hint.bounds.height / 2)
            hint.opacity = i == 1 ? 1 : 0
            content.addSublayer(hint)
            animate(hint, duration: duration, [Self.keyframes("opacity", [0, 0, 1, 1, 0, 0], windows[i])])
        }
    }

    private func buildTouchVeilOnly() {
        veil.opacity = 0.15
        animate(veil, duration: 8, [Self.keyframes("opacity", [1, 1, 0.15, 0.15, 1, 1], [0, 0.1, 0.16, 0.78, 0.86, 1])])
    }

    private func buildStrip() {
        let ropeY = menuBarHeight + 16
        let rope = Self.ropeLayer(width: min(640, bounds.width - 120), y: ropeY, midX: bounds.midX)
        content.addSublayer(rope)
        let card = CGSize(width: 120, height: 80)
        for (i, offset) in [-225.0, -75.0, 75.0, 225.0].enumerated() {
            let hang = CALayer()
            hang.bounds = CGRect(x: 0, y: 0, width: card.width, height: card.height + 12)
            hang.anchorPoint = CGPoint(x: 0.5, y: 0)
            hang.position = CGPoint(x: bounds.midX + offset, y: ropeY - 6)
            let body = Self.cardLayer(size: card)
            body.position = CGPoint(x: card.width / 2, y: 12 + card.height / 2)
            body.opacity = Float(1 - Double(i) * 0.1)
            let peg = CALayer()
            peg.bounds = CGRect(x: 0, y: 0, width: 8, height: 16)
            peg.position = CGPoint(x: card.width / 2, y: 10)
            peg.cornerRadius = 2
            peg.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            hang.addSublayer(body)
            hang.addSublayer(peg)
            content.addSublayer(hang)
            if !reduceMotion {
                let sway = CABasicAnimation(keyPath: "transform.rotation.z")
                sway.fromValue = -0.05
                sway.toValue = 0.05
                sway.duration = 1.5
                sway.autoreverses = true
                sway.repeatCount = loops * 2
                sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sway.beginTime = canvas.convertTime(CACurrentMediaTime(), from: nil) - (i.isMultiple(of: 2) ? 0 : 0.75)
                hang.add(sway, forKey: "sway")
            }
        }
        let keys = Self.keysLayer(["⌃", "⌥", "T"], scale: contentsScale)
        keys.position = CGPoint(x: bounds.midX, y: ropeY + 150)
        content.addSublayer(keys)
    }

    private var contentsScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: - Utilidades

    private func animate(_ layer: CALayer, duration: CFTimeInterval, _ animations: [CAAnimation]) {
        guard !reduceMotion else { return }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.repeatCount = loops
        layer.add(group, forKey: "demo")
    }

    private static func keyframes(_ keyPath: String, _ values: [Any], _ times: [Double]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values.map { value -> Any in
            switch value {
            case let size as CGSize: return NSValue(size: size)
            case let point as CGPoint: return NSValue(point: point)
            case let transform as CATransform3D: return NSValue(caTransform3D: transform)
            default: return value
            }
        }
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(times.count - 1, 1))
        return animation
    }

    /// Velo de pantalla completa con un hueco opcional (regla par-impar).
    static func veilPath(_ bounds: CGRect, hole: CGRect?, radius: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        let rect = hole ?? CGRect(origin: .zero, size: .zero)
        path.addRoundedRect(in: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2))
        return path
    }

    private static func hintLayer(_ text: String, scale: CGFloat, mono: Bool = false) -> CALayer {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold) : NSFont.systemFont(ofSize: 13, weight: .semibold)
        let textLayer = CATextLayer()
        textLayer.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        textLayer.contentsScale = scale
        textLayer.alignmentMode = .center
        let size = (text as NSString).size(withAttributes: [.font: font])
        let pill = CALayer()
        pill.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 24, height: ceil(size.height) + 10)
        pill.cornerRadius = pill.bounds.height / 2
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pill.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        pill.borderWidth = 1
        textLayer.frame = CGRect(x: 12, y: 5, width: ceil(size.width), height: ceil(size.height))
        pill.addSublayer(textLayer)
        return pill
    }

    private static func keysLayer(_ keys: [String], scale: CGFloat) -> CALayer {
        let keySize = CGSize(width: 40, height: 40)
        let gap: CGFloat = 8
        let group = CALayer()
        group.bounds = CGRect(x: 0, y: 0, width: CGFloat(keys.count) * keySize.width + CGFloat(keys.count - 1) * gap, height: keySize.height)
        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        for (i, key) in keys.enumerated() {
            let cap = CALayer()
            cap.frame = CGRect(x: CGFloat(i) * (keySize.width + gap), y: 0, width: keySize.width, height: keySize.height)
            cap.cornerRadius = 9
            cap.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            cap.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
            cap.borderWidth = 1
            let label = CATextLayer()
            label.string = NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: NSColor.white])
            label.alignmentMode = .center
            label.contentsScale = scale
            let height = (key as NSString).size(withAttributes: [.font: font]).height
            label.frame = CGRect(x: 0, y: (keySize.height - height) / 2, width: keySize.width, height: height)
            cap.addSublayer(label)
            group.addSublayer(cap)
        }
        return group
    }

    private static func crosshairLayer() -> CALayer {
        let cross = CALayer()
        cross.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        for frame in [CGRect(x: 10, y: 0, width: 2, height: 22), CGRect(x: 0, y: 10, width: 22, height: 2)] {
            let bar = CALayer()
            bar.frame = frame
            bar.backgroundColor = NSColor.white.cgColor
            bar.borderColor = NSColor.black.withAlphaComponent(0.7).cgColor
            bar.borderWidth = 0.5
            cross.addSublayer(bar)
        }
        return cross
    }

    private static func cardLayer(size: CGSize) -> CALayer {
        let card = CAGradientLayer()
        card.bounds = CGRect(origin: .zero, size: size)
        card.colors = [NSColor(srgbRed: 0.91, green: 0.34, blue: 0.23, alpha: 0.85).cgColor,
                       NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.75).cgColor]
        card.startPoint = CGPoint(x: 0, y: 0)
        card.endPoint = CGPoint(x: 1, y: 1)
        card.cornerRadius = 8
        card.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        card.borderWidth = 1
        card.shadowOpacity = 0.4
        card.shadowRadius = 10
        card.shadowOffset = CGSize(width: 0, height: -6)
        return card
    }

    private static func ropeLayer(width: CGFloat, y: CGFloat, midX: CGFloat) -> CALayer {
        let rope = CALayer()
        rope.frame = CGRect(x: midX - width / 2, y: y, width: width, height: 2)
        rope.cornerRadius = 1
        rope.backgroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        return rope
    }
}
