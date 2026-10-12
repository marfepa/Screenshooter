import AppKit

/// Modelo puro de la captura larga: decide la fase visible (aviso, final, límite, cancelación) a partir
/// de los resultados del cosido y de los intentos de scroll. El reloj (`TimeInterval`) se inyecta; sin
/// temporizadores, para poder probarlo de forma determinista.
struct ScrollCaptureModel {
    enum Phase: Equatable { case capturing, warnTooFast, atEnd, limitReached, confirmingCancel, stitching }
    enum CancelDecision: Equatable { case cancelNow, askConfirmation }
    enum Inactivity: Equatable { case none, warning(secondsLeft: Int), expired }

    struct Timing: Equatable {
        /// Segundos de intentos de scroll hacia el final sin fotograma nuevo para dar por llegado el final.
        var atEndAfter: TimeInterval = 1.5
        /// Antigüedad máxima del último intento para que el usuario siga «intentando» avanzar.
        var attemptFreshness: TimeInterval = 0.5
        var inactivityTimeout: TimeInterval = 120
        var warningLead: TimeInterval = 10
    }

    let timing: Timing
    private(set) var phase: Phase = .capturing
    /// 1 al empezar (el primer fotograma); +1 por cada `.appended`.
    private(set) var acceptedFrames = 1

    private var lastAppendedAt: TimeInterval
    private var firstAttemptAt: TimeInterval?
    private var lastAttemptAt: TimeInterval?
    private var phaseBeforeCancel: Phase = .capturing

    init(startedAt: TimeInterval, timing: Timing = .init()) {
        self.timing = timing
        self.lastAppendedAt = startedAt
    }

    mutating func apply(_ outcome: ScrollStitcher.Outcome, at now: TimeInterval) {
        switch phase {
        case .confirmingCancel, .stitching, .limitReached:
            return
        default:
            break
        }
        switch outcome {
        case .appended:
            acceptedFrames += 1
            phase = .capturing
            lastAppendedAt = now
            firstAttemptAt = nil
            lastAttemptAt = nil
        case .noOverlap:
            phase = .warnTooFast
        case .unchanged:
            // El fotograma volvió a solapar con la referencia: se quita el aviso
            if phase == .warnTooFast { phase = .capturing }
        case .limitReached:
            phase = .limitReached
        }
    }

    /// Intento de scroll observado (monitor global de `.scrollWheel`). Solo cuenta el que va hacia el final.
    mutating func noteScrollAttempt(towardEnd: Bool, at now: TimeInterval) {
        guard towardEnd else { return }
        if firstAttemptAt == nil { firstAttemptAt = now }
        lastAttemptAt = now
    }

    /// Reevalúa si se ha llegado al final del contenido.
    mutating func tick(at now: TimeInterval) {
        guard phase == .capturing || phase == .warnTooFast,
              acceptedFrames > 1,
              let first = firstAttemptAt, let last = lastAttemptAt,
              now - first >= timing.atEndAfter,
              now - last <= timing.attemptFreshness else { return }
        phase = .atEnd
    }

    func inactivity(at now: TimeInterval) -> Inactivity {
        let idle = now - lastAppendedAt
        if idle >= timing.inactivityTimeout { return .expired }
        let left = timing.inactivityTimeout - idle
        if left <= timing.warningLead { return .warning(secondsLeft: Int(left.rounded(.up))) }
        return .none
    }

    mutating func requestCancel() -> CancelDecision {
        guard acceptedFrames > 1 else { return .cancelNow }
        if phase != .confirmingCancel, phase != .stitching {
            phaseBeforeCancel = phase
            phase = .confirmingCancel
        }
        return .askConfirmation
    }

    mutating func dismissCancel() {
        guard phase == .confirmingCancel else { return }
        phase = phaseBeforeCancel
    }

    mutating func beginStitching() {
        phase = .stitching
    }
}

extension ScrollCaptureModel {
    /// ⇧ pulsado, ignorando Bloq Mayús y demás modificadores de estado.
    static func wantsScrollCapture(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift)
    }
}

/// Controla cuántas veces se muestra la línea «Mantén ⇧ al soltar…» en el selector.
enum ScrollCaptureHelpHint {
    static let maxUses = 3
    static let defaultsKey = "scrollCaptureUses"

    static func shouldShow(defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: defaultsKey) < maxUses
    }

    static func recordUse(defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: defaultsKey) + 1, forKey: defaultsKey)
    }
}
