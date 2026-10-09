import AppKit
import QuartzCore

// MARK: - Muelles

/// Muelle descrito por respuesta (s) y razón de amortiguación, como en SwiftUI/UIKit.
/// Se traduce a los parámetros físicos de `CASpringAnimation` (masa 1).
public struct SpringSpec: Equatable {
    public let response: Double
    public let dampingRatio: Double

    public init(response: Double, dampingRatio: Double) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    public var stiffness: Double { pow(2 * Double.pi / response, 2) }
    public var damping: Double { 2 * dampingRatio * stiffness.squareRoot() }
}

// MARK: - Estilo de movimiento

/// Duraciones y curvas de la tira. Con Reducir movimiento no hay muelles, escalas ni rotaciones
/// animadas: solo fundidos de 0,2 s.
public struct MotionStyle: Equatable {
    public let reduceMotion: Bool
    public let revealSpring: SpringSpec?
    public let arrivalSpring: SpringSpec?
    public let hoverSpring: SpringSpec?
    public let repositionSpring: SpringSpec?
    public let revealDuration: TimeInterval
    public let retractDuration: TimeInterval
    public let repositionDuration: TimeInterval
    public let pressDuration: TimeInterval
    public let fallDuration: TimeInterval
    public let fadeDuration: TimeInterval
    public let hoverScale: CGFloat
    public let pressScale: CGFloat
    /// Amplitud inicial (grados) del balanceo al llegar una captura.
    public let arrivalSwingDegrees: Double
    /// Amplitud máxima (grados) del vaivén del primer despliegue.
    public let swayDegrees: Double
    public let swayMaxDelay: TimeInterval
    /// Giro máximo (grados) al descartar.
    public let fallMaxRotation: Double

    public var usesSprings: Bool {
        revealSpring != nil || arrivalSpring != nil || hoverSpring != nil || repositionSpring != nil
    }

    public static func current(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> MotionStyle {
        if reduceMotion {
            return MotionStyle(
                reduceMotion: true,
                revealSpring: nil, arrivalSpring: nil, hoverSpring: nil, repositionSpring: nil,
                revealDuration: 0.2, retractDuration: 0.2, repositionDuration: 0.2,
                pressDuration: 0.2, fallDuration: 0.2, fadeDuration: 0.2,
                hoverScale: 1, pressScale: 1,
                arrivalSwingDegrees: 0, swayDegrees: 0, swayMaxDelay: 0, fallMaxRotation: 0
            )
        }
        return MotionStyle(
            reduceMotion: false,
            revealSpring: SpringSpec(response: 0.42, dampingRatio: 0.82),
            arrivalSpring: SpringSpec(response: 0.42, dampingRatio: 0.8),
            hoverSpring: SpringSpec(response: 0.3, dampingRatio: 0.7),
            repositionSpring: SpringSpec(response: 0.55, dampingRatio: 0.85),
            revealDuration: 0.42, retractDuration: 0.22, repositionDuration: 0.55,
            pressDuration: 0.45, fallDuration: 0.45, fadeDuration: 0.2,
            hoverScale: 1.035, pressScale: 0.95,
            arrivalSwingDegrees: 10, swayDegrees: 1.5, swayMaxDelay: 0.35, fallMaxRotation: 22
        )
    }
}

// MARK: - Preferencias de accesibilidad de pantalla

public enum DisplayAccessibility {
    public static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    public static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

// MARK: - Geometría y transformaciones puras

public enum StripMotion {
    public static let cardSize = CGSize(width: 150, height: 104)
    /// Alto de la "ranura" de una tarjeta: pinza + tarjeta + cápsula de hora/tamaño.
    public static let slotSize = CGSize(width: 150, height: 146)
    /// Distancia entre el borde superior de la ranura y el de la tarjeta.
    public static let cardTopInset: CGFloat = 8
    public static let gap: CGFloat = 14
    public static let minLeading: CGFloat = 24
    /// Margen entre el borde superior de la tira y la cuerda en sus extremos.
    public static let ropeBase: CGFloat = 13
    public static let slotTopBase: CGFloat = 14
    public static let stripHeight: CGFloat = 176
    public static let thumbnailPadding: CGFloat = 5

    /// Rotación (grados, positivo = antihorario) y escala compuestas en una sola transformación.
    /// `pivotOffset` es el vector desde el centro de la capa hasta el punto fijo (la capa de una vista
    /// tiene su anchorPoint en el centro y AppKit no tolera cambiarlo): con `.zero` gira y escala sobre el centro.
    public static func cardTransform(tilt: Double, scale: CGFloat, pivotOffset: CGPoint = .zero) -> CATransform3D {
        let rotation = CATransform3DMakeRotation(CGFloat(tilt * .pi / 180), 0, 0, 1)
        let scaling = CATransform3DMakeScale(scale, scale, 1)
        var m = CATransform3DConcat(scaling, rotation) // escala y luego gira (uniforme: conmutan)
        if pivotOffset != .zero {
            m = CATransform3DConcat(CATransform3DMakeTranslation(-pivotOffset.x, -pivotOffset.y, 0), m)
            m = CATransform3DConcat(m, CATransform3DMakeTranslation(pivotOffset.x, pivotOffset.y, 0))
        }
        return m
    }

    /// Transformación de la tarjeta con el ancla en el centro superior de una capa de alto `height`.
    public static func cardTransform(tilt: Double, scale: CGFloat, anchoredAtTopOfHeight height: CGFloat) -> CATransform3D {
        cardTransform(tilt: tilt, scale: scale, pivotOffset: CGPoint(x: 0, y: height / 2))
    }

    /// Caída máxima de la cuerda en el centro.
    public static func ropeSag(width: CGFloat) -> CGFloat {
        max(0, min(10, width / 120))
    }

    /// Descenso de la cuerda (0 en los extremos, `ropeSag` en el centro) para una `x` dada.
    public static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let t = min(max(x / width, 0), 1)
        return 4 * ropeSag(width: width) * t * (1 - t)
    }

    /// Marcos de las ranuras en coordenadas "de arriba abajo" (y = distancia al borde superior de la tira).
    /// Centradas, con hueco `gap`, x mínima `minLeading` y colgando de la curva de la cuerda.
    public static func cardFrames(count: Int, width: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let total = CGFloat(count) * slotSize.width + CGFloat(count - 1) * gap
        var x = max(minLeading, (width - total) / 2)
        var frames: [CGRect] = []
        for _ in 0..<count {
            let y = slotTopBase + ropeY(x: x + slotSize.width / 2, width: width)
            frames.append(CGRect(x: x, y: y, width: slotSize.width, height: slotSize.height))
            x += slotSize.width + gap
        }
        return frames
    }

    /// Mayor rectángulo con la proporción de `imageSize` que cabe centrado en `rect`.
    public static func aspectFit(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: Textos

    /// Hora corta según la configuración regional (respeta 12/24 h).
    static func timeText(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Píxeles como texto plano: las dimensiones no llevan separador de millares (1440, no 1.440 / 1,440).
    private static func pixelSizeStrings(_ item: StripItem) -> (String, String) {
        (String(Int(item.pixelSize.width)), String(Int(item.pixelSize.height)))
    }

    /// "HH:mm · W×H" (píxeles reales del archivo; la hora sigue 12/24 h del sistema).
    public static func metaText(for item: StripItem, locale: Locale = .current) -> String {
        let time = timeText(item.createdAt, locale: locale)
        let (w, h) = pixelSizeStrings(item)
        return String(localized: "\(time) · \(w)×\(h)", bundle: L10n.bundle, locale: locale, comment: "Caption under a card: time, then size in pixels as width×height")
    }

    /// Etiqueta de VoiceOver: "Captura, HH:mm, W por H" o "Captura no encontrada, HH:mm".
    public static func accessibilityLabel(for item: StripItem, missing: Bool, locale: Locale = .current) -> String {
        let time = timeText(item.createdAt, locale: locale)
        if missing {
            return String(localized: "Capture not found, \(time)", bundle: L10n.bundle, locale: locale, comment: "VoiceOver label of a card whose file is missing; the argument is the capture time")
        }
        let (w, h) = pixelSizeStrings(item)
        return String(localized: "Capture, \(time), \(w) by \(h)", bundle: L10n.bundle, locale: locale, comment: "VoiceOver label of a card: capture time, then pixel width by height")
    }

    public static func positionText(index: Int, count: Int) -> String {
        String(localized: "\(index + 1) of \(count)", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver value of a card: its position out of the total")
    }
}

// MARK: - Animación de capas

extension CALayer {
    /// Fija el valor final en el modelo y anima desde `from` (por defecto, el valor visible actual).
    /// Con `spring` usa `CASpringAnimation`; si no, `CABasicAnimation` con `timing`.
    func animateValue(
        _ keyPath: String,
        to target: Any,
        from: Any? = nil,
        spring: SpringSpec? = nil,
        duration: TimeInterval,
        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut),
        key: String? = nil,
        beginTime: CFTimeInterval = 0
    ) {
        let start = from ?? presentation()?.value(forKeyPath: keyPath) ?? value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setValue(target, forKeyPath: keyPath)
        CATransaction.commit()

        let animation: CABasicAnimation
        if let spring {
            let s = CASpringAnimation(keyPath: keyPath)
            s.mass = 1
            s.stiffness = CGFloat(spring.stiffness)
            s.damping = CGFloat(spring.damping)
            s.initialVelocity = 0
            s.duration = max(s.settlingDuration, duration)
            animation = s
        } else {
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = timing
        }
        animation.fromValue = start
        animation.toValue = target
        if beginTime > 0 {
            animation.beginTime = CACurrentMediaTime() + beginTime
            animation.fillMode = .backwards
        }
        add(animation, forKey: key ?? keyPath)
    }
}
