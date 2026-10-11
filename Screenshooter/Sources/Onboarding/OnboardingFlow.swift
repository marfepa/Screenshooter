import Foundation

/// Pasos de la bienvenida, en orden.
public enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permission
    case capture
    /// Dos dedos en el trackpad: la captura se aparta (scroll o cambio de app) y vuelve sola.
    case touch
    case strip

    public var isFirst: Bool { self == Self.allCases.first }
    public var isLast: Bool { self == Self.allCases.last }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// Reglas puras de la bienvenida: cuándo se muestra y en qué paso empieza.
public enum OnboardingFlow {
    /// Sube cuando la bienvenida explique algo nuevo y deba volver a verse una vez.
    public static let currentVersion = 1

    /// Al arrancar: si no se ha visto la versión actual o hay que reanudarla tras el reinicio por el permiso.
    /// Nunca durante una captura (el overlay la taparía).
    public static func shouldShowAtLaunch(seenVersion: Int, resumeStep: OnboardingStep?, isCaptureActive: Bool) -> Bool {
        guard !isCaptureActive else { return false }
        return resumeStep != nil || seenVersion < currentVersion
    }

    /// Paso inicial: el de reanudación si lo hay; al reabrirla desde el menú con el permiso ya concedido,
    /// directamente los gestos (el icono y el permiso ya no aportan nada); si no, el principio.
    public static func initialStep(resumeStep: OnboardingStep?, reopenedFromMenu: Bool, permissionGranted: Bool) -> OnboardingStep {
        if let resumeStep { return resumeStep }
        if reopenedFromMenu && permissionGranted { return .capture }
        return .welcome
    }

    /// Paso en el que seguir tras reiniciar la app para aplicar el permiso.
    public static let stepAfterPermissionRestart: OnboardingStep = .capture
}

/// Persistencia de la bienvenida en `UserDefaults` (inyectable en tests: el host de tests ES la app).
public struct OnboardingStore {
    static let seenVersionKey = "onboardingVersion"
    static let resumeStepKey = "onboardingResumeStep"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var seenVersion: Int {
        defaults.integer(forKey: Self.seenVersionKey)
    }

    public var resumeStep: OnboardingStep? {
        guard defaults.object(forKey: Self.resumeStepKey) != nil else { return nil }
        return OnboardingStep(rawValue: defaults.integer(forKey: Self.resumeStepKey))
    }

    /// Cerrada con «Saltar», «Empezar» o el botón de cerrar: no vuelve a salir sola.
    public func markSeen() {
        defaults.set(OnboardingFlow.currentVersion, forKey: Self.seenVersionKey)
        defaults.removeObject(forKey: Self.resumeStepKey)
    }

    public func saveResumeStep(_ step: OnboardingStep) {
        defaults.set(step.rawValue, forKey: Self.resumeStepKey)
    }

    public func clearResumeStep() {
        defaults.removeObject(forKey: Self.resumeStepKey)
    }
}
