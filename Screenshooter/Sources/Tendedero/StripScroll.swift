import CoreGraphics
import Foundation

// MARK: - Constantes y funciones puras del desplazamiento

/// Física y geometría puras del desplazamiento de la tira (sin AppKit): se prueban sin ventana.
/// Las constantes salen de la maqueta `mockup/tira.html` (bloque "Constantes de la física").
public enum StripScroll {
    public static let cardWidth: CGFloat = StripMotion.slotSize.width
    public static let gap: CGFloat = StripMotion.gap
    /// Margen lateral mínimo (también el inicio de la primera tarjeta cuando la tira se desplaza).
    public static let pad: CGFloat = StripMotion.minLeading
    /// Margen que `ensureVisible` deja entre la tarjeta enfocada y el borde.
    public static let viewMargin: CGFloat = 64

    /// Fricción por fotograma a 60 fps (inercia estilo macOS) y la versión corta de Reducir movimiento.
    public static let friction: CGFloat = 0.95
    public static let frictionReduced: CGFloat = 0.86
    /// Resistencia al estirar más allá del borde y tope de estiramiento.
    public static let rubber: CGFloat = 0.55
    public static let rubberMax: CGFloat = 160
    /// Muelle de vuelta desde el rebote (casi crítico).
    public static let backK: CGFloat = 140
    public static let backC: CGFloat = 22
    /// Inclinación: grados por (pt/s), tope en grados y muelle (ζ≈0,7; reposo < 0,6 s).
    public static let tiltK: CGFloat = 0.0025
    public static let tiltMax: CGFloat = 3.5
    public static let tiltKS: CGFloat = 220
    public static let tiltCS: CGFloat = 20.8
    /// Retraso de fase máximo entre tarjetas, en fotogramas.
    public static let lagMax: CGFloat = 1
    /// Desvanecimiento de los extremos (pt) y su versión con Aumentar contraste.
    public static let fadeZone: CGFloat = 40
    public static let fadeZoneContrast: CGFloat = 16
    /// Semianchura (pt) de la franja de la cuerda que captura el ratón.
    public static let ropeBandHalfWidth: CGFloat = 10
    /// Una página es esta fracción del ancho visible.
    public static let pageFraction: CGFloat = 0.8
    /// Umbral (pt) para contar una tarjeta como parcialmente oculta.
    public static let hiddenThreshold: CGFloat = 1
    /// Líneas → puntos para ratones de rueda (sin deltas precisos).
    public static let wheelLineHeight: CGFloat = 12

    public static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

    // MARK: Geometría

    public struct Metrics: Equatable {
        public let count: Int
        public let viewWidth: CGFloat

        public init(count: Int, viewWidth: CGFloat) {
            self.count = max(0, count)
            self.viewWidth = max(0, viewWidth)
        }

        public var step: CGFloat { StripScroll.cardWidth + StripScroll.gap }
        /// Ancho de las tarjetas con sus huecos.
        public var totalCards: CGFloat { count == 0 ? 0 : CGFloat(count) * StripScroll.cardWidth + CGFloat(count - 1) * StripScroll.gap }
        public var contentWidth: CGFloat { totalCards + 2 * StripScroll.pad }
        public var isScrollable: Bool { contentWidth > viewWidth }
        public var maxOffset: CGFloat { isScrollable ? contentWidth - viewWidth : 0 }
        /// `x` de la primera tarjeta en el contenido: centrada si caben todas.
        public var start: CGFloat { isScrollable ? StripScroll.pad : max(StripScroll.pad, (viewWidth - totalCards) / 2) }
        public func slotX(_ index: Int) -> CGFloat { start + CGFloat(index) * step }
    }

    // MARK: Rubber band

    /// Desplazamiento visible de un delta de usuario: con el offset fuera de rango y empujando hacia fuera,
    /// el factor 0,55 decrece hasta 0,05 al acercarse a `rubberMax`. Con Reducir movimiento, tope duro.
    public static func rubberDelta(_ d: CGFloat, offset: CGFloat, maxOffset: CGFloat, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return clamp(offset + d, 0, maxOffset) - offset }
        let over = offset < 0 ? -offset : (offset > maxOffset ? offset - maxOffset : 0)
        let outward = (offset <= 0 && d < 0) || (offset >= maxOffset && d > 0)
        return outward ? d * rubber * max(0.05, 1 - over / rubberMax) : d
    }

    /// Cuánto se sale `offset` del rango `[0, maxOffset]` (negativo a la izquierda).
    public static func overscroll(offset: CGFloat, maxOffset: CGFloat) -> CGFloat {
        offset < 0 ? offset : (offset > maxOffset ? offset - maxOffset : 0)
    }

    // MARK: Inclinación

    /// Inclinación objetivo (grados): contraria a la velocidad y con tope. Sin inclinación con Reducir movimiento.
    public static func tiltTarget(velocity: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : -clamp(velocity * tiltK, -tiltMax, tiltMax)
    }

    /// Retraso de fase (fotogramas) de una tarjeta según su posición `f` (0 izquierda … 1 derecha) y el sentido.
    public static func lag(fraction f: CGFloat, movingRight: Bool, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : lagMax * (movingRight ? f : 1 - f)
    }

    /// Muestra interpolada de un historial (índice 0 = fotograma actual).
    public static func sample(_ history: [CGFloat], lag: CGFloat) -> CGFloat {
        guard !history.isEmpty else { return 0 }
        let l = max(0, min(lag, CGFloat(history.count - 1)))
        let i = Int(l.rounded(.down)), f = l - CGFloat(i)
        return history[i] * (1 - f) + history[min(i + 1, history.count - 1)] * f
    }

    // MARK: Rango visible y contadores

    /// Índices con alguna parte dentro de la ventana `[0, viewWidth]`.
    public static func visibleRange(_ m: Metrics, offset: CGFloat) -> Range<Int> {
        guard m.count > 0, m.step > 0 else { return 0..<0 }
        let first = Int(((offset - m.start - cardWidth) / m.step).rounded(.down)) + 1
        let last = Int(((offset + m.viewWidth - m.start) / m.step).rounded(.up)) - 1
        let lo = max(0, first), hi = min(m.count - 1, last)
        return lo <= hi ? lo..<(hi + 1) : 0..<0
    }

    /// Índices a montar: los visibles más `margin` a cada lado (reciclaje).
    public static func mountedRange(_ m: Metrics, offset: CGFloat, margin: Int = 1) -> Range<Int> {
        let v = visibleRange(m, offset: offset)
        if v.isEmpty {
            // Sin visibles (offset muy fuera de rango): monta la más cercana al borde que toque.
            guard m.count > 0 else { return 0..<0 }
            let edge = offset < 0 ? 0 : m.count - 1
            return max(0, edge - margin)..<min(m.count, edge + margin + 1)
        }
        return max(0, v.lowerBound - margin)..<min(m.count, v.upperBound + margin)
    }

    /// Tarjetas ocultas a la izquierda y a la derecha. Una tarjeta parcialmente fuera ya cuenta
    /// si sobresale más de `hiddenThreshold` pt.
    public static func hiddenCounts(_ m: Metrics, offset: CGFloat) -> (left: Int, right: Int) {
        guard m.count > 0, m.isScrollable, m.step > 0 else { return (0, 0) }
        // Izquierda: start + i·step − offset < −umbral
        let q = (offset - hiddenThreshold - m.start) / m.step
        let left = q > 0 ? min(m.count, Int(q.rounded(.up))) : 0
        // Derecha: start + i·step + ancho − offset > viewWidth + umbral
        let r = (m.viewWidth + hiddenThreshold - cardWidth - m.start + offset) / m.step
        let firstRight = Int(r.rounded(.down)) + 1
        let right = max(0, m.count - max(0, firstRight))
        return (left, right)
    }

    // MARK: Destinos

    /// Offset destino de una página (0,8 del ancho) a partir de `base`.
    public static func pageTarget(base: CGFloat, direction: Int, viewWidth: CGFloat, maxOffset: CGFloat) -> CGFloat {
        clamp(base + CGFloat(direction) * viewWidth * pageFraction, 0, maxOffset)
    }

    /// Offset que deja la tarjeta `index` a la vista con `margin` de holgura; `current` si ya lo está.
    public static func ensureVisibleTarget(index: Int, current: CGFloat, _ m: Metrics, margin: CGFloat = viewMargin) -> CGFloat {
        guard m.isScrollable else { return current }
        let tx = m.slotX(index)
        var t = current
        if tx - current < margin { t = tx - margin }
        else if tx + cardWidth - current > m.viewWidth - margin { t = tx + cardWidth - m.viewWidth + margin }
        return clamp(t, 0, m.maxOffset)
    }

    /// Zona de desvanecimiento en puntos.
    public static func fadeZone(highContrast: Bool) -> CGFloat { highContrast ? fadeZoneContrast : fadeZone }

    /// Opacidad (0…1) de una tarjeta cuyo centro está a `cx` en una ventana de ancho `w` (equivale a la máscara de degradado).
    public static func edgeOpacity(centerX cx: CGFloat, viewWidth w: CGFloat, zone: CGFloat) -> CGFloat {
        clamp((min(cx, w - cx) + zone * 0.75) / (zone * 1.75), 0, 1)
    }

    // MARK: Frontera de precisión

    /// Un `Double` de velocidad tras `dt` s con fricción por fotograma `f` (independiente de la tasa de refresco).
    public static func decayedVelocity(_ v: CGFloat, dt: CGFloat, friction f: CGFloat) -> CGFloat {
        v * CGFloat(pow(Double(f), Double(dt) * 60))
    }
}

// MARK: - Inclinación por velocidad

/// Muelle de la inclinación de una tarjeta (grados).
public struct TiltState: Equatable {
    public var angle: CGFloat
    public var velocity: CGFloat

    public init(angle: CGFloat = 0, velocity: CGFloat = 0) {
        self.angle = angle
        self.velocity = velocity
    }

    /// Avanza `dt` s hacia `target`. Devuelve `true` mientras siga en movimiento.
    @discardableResult
    public mutating func step(target: CGFloat, dt: CGFloat, reduceMotion: Bool) -> Bool {
        if reduceMotion { angle = 0; velocity = 0; return false }
        if dt > 0 {
            velocity += (-StripScroll.tiltKS * (angle - target) - StripScroll.tiltCS * velocity) * dt
            angle += velocity * dt
        }
        if abs(angle) < 0.01 && abs(velocity) < 0.05 && abs(target) < 0.01 {
            angle = 0
            velocity = 0
            return false
        }
        return true
    }
}

// MARK: - Histéresis de eje

/// Fija el eje dominante al empezar un gesto y solo lo cambia si el otro supera 3× al fijado.
public struct AxisLock: Equatable {
    public enum Axis: Equatable { case horizontal, vertical }
    public private(set) var axis: Axis?

    public init() {}

    public mutating func reset() { axis = nil }

    /// Delta del eje activo (sin tocar el signo: el sistema ya aplica el desplazamiento natural).
    public mutating func resolve(dx: CGFloat, dy: CGFloat) -> CGFloat {
        if axis == nil {
            guard dx != 0 || dy != 0 else { return 0 }
            axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        } else if axis == .horizontal, abs(dy) > 3 * abs(dx), abs(dy) > 4 {
            axis = .vertical
        } else if axis == .vertical, abs(dx) > 3 * abs(dy), abs(dx) > 4 {
            axis = .horizontal
        }
        return axis == .horizontal ? dx : dy
    }
}

// MARK: - Simulación del desplazamiento

/// Máquina de estados del offset horizontal: arrastre, rueda/trackpad, inercia, rebote y animaciones programáticas.
/// Se avanza con `tick(_:)` (dt en segundos), sin depender de AppKit.
public struct StripScroller: Equatable {
    public enum Mode: Equatable { case idle, drag, wheel, free, anim }

    public var offset: CGFloat = 0
    public var velocity: CGFloat = 0
    public private(set) var mode: Mode = .idle
    public var maxOffset: CGFloat = 0
    public var reduceMotion = false
    /// Hubo movimiento desde el último reposo anunciado.
    public var moved = false
    public private(set) var pending: CGFloat = 0

    private struct Anim: Equatable { var from: CGFloat, to: CGFloat, t: CGFloat, dur: CGFloat }
    private var anim: Anim?
    /// `true` cuando el sistema envía las fases y el momentum (trackpad): sin inercia propia.
    private var systemDriven = false
    private var sinceInput: CGFloat = 0
    /// Una rueda de ratón sin fases pasa a inercia propia tras este silencio.
    public static let wheelIdleTimeout: CGFloat = 0.1

    public init() {}

    /// Hay algo que impide recoger la tira (arrastre, rueda, inercia o animación).
    public var isBusy: Bool { mode != .idle }
    /// Desplazamiento programático (teclado, contadores, volver al inicio): sin inclinación.
    public var isProgrammatic: Bool { mode == .anim }
    public var targetOffset: CGFloat { mode == .anim ? (anim?.to ?? offset) : offset }

    // Entradas

    public mutating func cancelAnimation() {
        anim = nil
        if mode == .anim { mode = .idle }
    }

    public mutating func beginDrag() {
        cancelAnimation()
        mode = .drag
        pending = 0
        systemDriven = false
    }

    public mutating func drag(by delta: CGFloat) { if mode == .drag { pending += delta } }

    public mutating func endDrag() {
        guard mode == .drag else { return }
        applyPending()
        mode = .free
    }

    /// Delta de rueda/trackpad ya en coordenadas de offset. `systemDriven`: el sistema envía las fases y el momentum.
    public mutating func wheel(delta: CGFloat, systemDriven: Bool) {
        if mode != .drag {
            cancelAnimation()
            mode = .wheel
            self.systemDriven = systemDriven
        }
        pending += delta
        sinceInput = 0
    }

    /// Fin del gesto del sistema (`phase` ended/cancelled o fin del momentum): sin inercia propia, solo vuelve de un rebote.
    public mutating func endSystemWheel() {
        guard mode == .wheel else { return }
        applyPending()
        mode = .free
        if systemDriven { velocity = 0 }
    }

    public mutating func fling(_ v: CGFloat) {
        cancelAnimation()
        mode = .free
        velocity = v
        pending = 0
    }

    /// Anima hasta `target`. Con Reducir movimiento salta al instante y devuelve `true`.
    @discardableResult
    public mutating func animate(to target: CGFloat, duration: CGFloat) -> Bool {
        let t = StripScroll.clamp(target, 0, maxOffset)
        pending = 0
        if reduceMotion {
            anim = nil; mode = .idle; velocity = 0; offset = t; moved = true
            return true
        }
        if mode == .drag { return false }
        anim = Anim(from: offset, to: t, t: 0, dur: duration)
        mode = .anim
        return false
    }

    public mutating func jump(to target: CGFloat) {
        anim = nil; mode = .idle; velocity = 0; pending = 0
        offset = StripScroll.clamp(target, 0, maxOffset)
    }

    /// Desplaza el origen (se insertaron tarjetas por la izquierda sin querer mover la vista).
    public mutating func shift(by delta: CGFloat) {
        offset += delta
        if var a = anim { a.from += delta; a.to += delta; anim = a }
    }

    /// Tras cambiar `maxOffset`: si quedó fuera de rango en reposo, el muelle lo devuelve (o clamp con Reducir movimiento).
    public mutating func boundsChanged() {
        if var a = anim { a.to = StripScroll.clamp(a.to, 0, maxOffset); anim = a }
        if reduceMotion {
            if mode != .drag && mode != .wheel { offset = StripScroll.clamp(offset, 0, maxOffset) }
        } else if mode == .idle, offset < 0 || offset > maxOffset {
            mode = .free
            velocity = 0
        }
    }

    // Simulación

    private mutating func applyPending() {
        if pending != 0 {
            offset += StripScroll.rubberDelta(pending, offset: offset, maxOffset: maxOffset, reduceMotion: reduceMotion)
            pending = 0
        }
    }

    /// Avanza `dt` segundos. Devuelve `true` mientras la simulación siga activa.
    @discardableResult
    public mutating func tick(_ dt: CGFloat) -> Bool {
        let prev = offset
        switch mode {
        case .drag, .wheel:
            let d = pending
            pending = 0
            if d != 0 { offset += StripScroll.rubberDelta(d, offset: offset, maxOffset: maxOffset, reduceMotion: reduceMotion) }
            if dt > 0 {
                // Una rueda sin fases conserva su última velocidad entre notches para lanzarla al soltar.
                if d != 0 || mode == .drag || systemDriven { velocity = velocity * 0.5 + ((offset - prev) / dt) * 0.5 }
                if mode == .wheel && !systemDriven {
                    sinceInput += dt
                    if sinceInput >= Self.wheelIdleTimeout { mode = .free }
                }
            }
        case .anim:
            if var a = anim {
                a.t += dt
                let p = a.dur > 0 ? min(1, a.t / a.dur) : 1
                offset = a.from + (a.to - a.from) * (1 - pow(1 - p, 3)) // easeOutCubic
                if dt > 0 { velocity = (offset - prev) / dt }
                if p >= 1 { mode = .idle; velocity = 0; anim = nil } else { anim = a }
            } else {
                mode = .idle
            }
        case .free:
            guard dt > 0 else { break }
            let over = StripScroll.overscroll(offset: offset, maxOffset: maxOffset)
            if reduceMotion { // inercia corta, sin rebote
                velocity = StripScroll.decayedVelocity(velocity, dt: dt, friction: StripScroll.frictionReduced)
                offset += velocity * dt
                if offset < 0 || offset > maxOffset { offset = StripScroll.clamp(offset, 0, maxOffset); velocity = 0 }
                if abs(velocity) < 8 { velocity = 0; mode = .idle }
            } else if over != 0 { // rebote: muelle hacia el borde
                velocity += (-StripScroll.backK * over - StripScroll.backC * velocity) * dt
                offset += velocity * dt
                offset = StripScroll.clamp(offset, -StripScroll.rubberMax * 1.5, maxOffset + StripScroll.rubberMax * 1.5)
                let o2 = StripScroll.overscroll(offset: offset, maxOffset: maxOffset)
                if abs(o2) < 0.4 && abs(velocity) < 10 {
                    offset = StripScroll.clamp(offset, 0, maxOffset)
                    velocity = 0
                    mode = .idle
                }
            } else { // inercia
                velocity = StripScroll.decayedVelocity(velocity, dt: dt, friction: StripScroll.friction)
                offset += velocity * dt
                if abs(velocity) < 6 { velocity = 0; mode = .idle }
            }
        case .idle:
            break
        }
        if mode != .idle { moved = true }
        return mode != .idle
    }
}

// MARK: - Capacidad de la tira

/// Capacidad configurable de la tira (menú "Capturas en la tira"). `0` = sin límite.
public enum StripCapacity {
    public static let defaultsKey = "stripCapacity"
    public static let options: [Int] = [8, 16, 32, 0]
    public static let defaultValue = 32

    /// Valor guardado; si falta o no es una de las opciones, el predeterminado (32).
    public static func load(from defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: defaultsKey) as? Int, options.contains(stored) else { return defaultValue }
        return stored
    }

    public static func save(_ value: Int, to defaults: UserDefaults = .standard) {
        defaults.set(options.contains(value) ? value : defaultValue, forKey: defaultsKey)
    }

    /// Capturas a retirar (las más antiguas) para respetar `limit`; `0` = sin límite.
    public static func overflow(count: Int, limit: Int) -> Int {
        limit > 0 ? max(0, count - limit) : 0
    }

    public static func title(for value: Int) -> String { value == 0 ? "Sin límite" : "\(value)" }

    public static func removalAnnouncement(_ n: Int) -> String {
        "Se quitaron \(n) \(n == 1 ? "captura más antigua" : "capturas más antiguas")"
    }
}

// MARK: - Textos de accesibilidad de la tira

extension StripScroll {
    public static func countsDescription(_ n: Int) -> String { "\(n) \(n == 1 ? "captura" : "capturas")" }

    public static func counterLabel(count n: Int, side: Side) -> String {
        "Mostrar \(n) \(n == 1 ? "captura más" : "capturas más") a la \(side == .left ? "izquierda" : "derecha")"
    }

    public static func restAnnouncement(hiddenLeft: Int, hiddenRight: Int, total: Int) -> String {
        "Mostrando de la \(hiddenLeft + 1) a la \(total - hiddenRight) de \(total)"
    }

    public enum Side { case left, right }

    /// Nota al reposar tras colgar una captura con la tira en su inicio (`{n}` = total).
    public static let newCaptureAtStartNote = "Nueva captura. Tira al inicio, {n} capturas"
    /// Anuncio inmediato cuando entra una captura mientras el usuario interactúa (la vista no se mueve).
    public static let newCaptureLeftNote = "Nueva captura añadida a la izquierda"
}
