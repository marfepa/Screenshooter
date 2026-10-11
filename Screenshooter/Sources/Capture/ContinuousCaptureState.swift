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

/// Detecta el final de un gesto de scroll (incluida la inercia) por silencio:
/// los eventos de inercia siguen llegando, así que basta con esperar `quietInterval` sin ninguno.
public struct ScrollQuietTracker {
    public let quietInterval: TimeInterval
    public private(set) var lastScroll: TimeInterval?

    public init(quietInterval: TimeInterval = 0.35) {
        self.quietInterval = quietInterval
    }

    public mutating func noteScroll(at time: TimeInterval) {
        lastScroll = time
    }

    public mutating func reset() {
        lastScroll = nil
    }

    /// `true` si hubo scroll y ya han pasado `quietInterval` segundos desde el último evento.
    public func isQuiet(at time: TimeInterval) -> Bool {
        guard let last = lastScroll else { return false }
        return time - last >= quietInterval
    }
}
