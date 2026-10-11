import Foundation

/// Estado del modo de captura continua (⌥⌘S).
public enum ContinuousCaptureState: Equatable {
    /// Sin modo activo.
    case idle
    /// Overlays visibles esperando una selección.
    case selecting
    /// Overlays transparentes a eventos mientras el usuario hace scroll en la app de debajo.
    case scrollPassthrough
    /// Sin overlays mientras se captura la última selección.
    case processing
    /// Overlays ocultos y píldora flotante: el usuario usa el sistema con normalidad.
    case navigating

    /// El modo continuo sigue vivo (todo salvo `idle`).
    public var isActive: Bool { self != .idle }
}

/// Eventos que mueven la máquina de estados del modo continuo.
public enum ContinuousCaptureEvent: Equatable {
    case hotKey
    case scrollBegan
    case scrollEnded
    case selectionCompleted
    case captureFinished
    case cancel
}

/// Transiciones puras del modo continuo; `CaptureCoordinator` aplica los efectos.
public enum ContinuousCaptureMachine {
    public static func next(_ state: ContinuousCaptureState, on event: ContinuousCaptureEvent) -> ContinuousCaptureState {
        switch (state, event) {
        case (_, .cancel):
            return .idle
        case (.idle, .hotKey), (.navigating, .hotKey):
            return .selecting
        case (.selecting, .hotKey), (.scrollPassthrough, .hotKey):
            return .navigating
        case (.selecting, .scrollBegan):
            return .scrollPassthrough
        case (.scrollPassthrough, .scrollEnded):
            return .selecting
        case (.selecting, .selectionCompleted):
            return .processing
        case (.processing, .captureFinished):
            return .selecting
        default:
            // ⌥⌘S durante el procesado, scroll fuera de la selección, etc.: sin cambio
            return state
        }
    }
}

/// Decide cuándo termina el scroll pasante.
///
/// macOS entrega todo un gesto de scroll (inercia incluida) a la ventana donde empezó, así que el gesto
/// que activa el modo lo recibe el overlay y no llega al fondo: el modo debe sobrevivir a ese gesto para
/// que los siguientes sí pasen. Termina cuando el usuario mueve el puntero (va a seleccionar) o tras
/// `quietInterval` sin scroll. El puntero se re-ancla en cada evento de scroll: una rueda de ratón que
/// tiembla al girar no cuenta como movimiento.
public struct ScrollPassthroughTracker {
    public let quietInterval: TimeInterval
    public let pointerTolerance: CGFloat
    public private(set) var lastScroll: TimeInterval?
    public private(set) var anchor: CGPoint?

    public init(quietInterval: TimeInterval = 1.2, pointerTolerance: CGFloat = 6) {
        self.quietInterval = quietInterval
        self.pointerTolerance = pointerTolerance
    }

    public mutating func noteScroll(at time: TimeInterval, pointer: CGPoint) {
        lastScroll = time
        anchor = pointer
    }

    public mutating func reset() {
        lastScroll = nil
        anchor = nil
    }

    /// `true` si hubo scroll y, desde el último evento, el puntero se ha movido más de `pointerTolerance`
    /// o han pasado `quietInterval` segundos.
    public func shouldEnd(at time: TimeInterval, pointer: CGPoint) -> Bool {
        guard let last = lastScroll, let anchor else { return false }
        if hypot(pointer.x - anchor.x, pointer.y - anchor.y) > pointerTolerance {
            return true
        }
        return time - last >= quietInterval
    }
}
