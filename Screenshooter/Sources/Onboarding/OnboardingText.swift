import Foundation

/// Textos de la bienvenida. Los atajos se escriben con glifos (⌥⌘S) en pantalla
/// y deletreados para VoiceOver (`spokenShortcuts`).
enum OnboardingText {
    static func title(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome:
            return String(localized: "Welcome to Screenshooter", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 1 title")
        case .permission:
            return String(localized: "Allow screen recording", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 2 title")
        case .capture:
            return String(localized: "Press ⌥⌘S and drag", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 3 title")
        case .touch:
            return String(localized: "Touch with two fingers to move it aside", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 4 title: a two-finger touch on the trackpad lets events through the capture overlay")
        case .strip:
            return String(localized: "Everything stays on the Shelf", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 5 title")
        }
    }

    static func body(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome:
            return String(localized: "Capture any part of the screen and have it instantly on the clipboard and on the Shelf. It lives up here, in the menu bar.", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 1 body")
        case .permission:
            return String(localized: "macOS needs your permission so Screenshooter can read the screen. Once you turn it on, Screenshooter restarts once and this welcome continues where you left it.", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 2 body")
        case .capture:
            return String(localized: "Select whatever you want, like here. Each capture is copied and hung on the Shelf; you can take several in a row until you press esc.", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 3 body")
        case .touch:
            return String(localized: "While capturing, touch the trackpad with two fingers: the screen lightens and you can scroll or switch apps. If you do nothing, it comes back by itself in a moment.", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 4 body")
        case .strip:
            return String(localized: "Your captures hang up here. Drag them into any app, click to copy, or press ⌃⌥T to show or hide the Shelf.", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding step 5 body")
        }
    }

    /// Descripción de la demostración animada para VoiceOver (la animación no se lee sola).
    static func illustration(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome:
            return String(localized: "Screenshooter icon, pointing to its place in the menu bar", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver description of the onboarding step 1 illustration")
        case .permission:
            return ""
        case .capture:
            return String(localized: "Animation: press Option Command S and drag to select; the capture flies to the Shelf", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver description of the onboarding step 3 animation")
        case .touch:
            return String(localized: "Animation: two fingers on the trackpad lighten the screen so you can scroll or switch apps; then it comes back", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver description of the onboarding step 4 animation")
        case .strip:
            return String(localized: "Captures hanging on the Shelf at the top of the screen", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver description of the onboarding step 5 illustration")
        }
    }

    /// Sustituye los glifos de atajos por su lectura («Opción Comando S»).
    static func spokenShortcuts(_ text: String) -> String {
        text
            .replacingOccurrences(of: "⌥⌘S", with: String(localized: "Option Command S", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver reading of the ⌥⌘S shortcut"))
            .replacingOccurrences(of: "⌃⌥T", with: String(localized: "Control Option T", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver reading of the ⌃⌥T shortcut"))
    }

    static var permissionAllowed: String {
        String(localized: "Screen recording: allowed", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding permission status when granted")
    }
    static var permissionMissing: String {
        String(localized: "Screen recording: not allowed yet", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding permission status when not granted")
    }
    static var permissionRestartHint: String {
        String(localized: "If you already turned it on, restart Screenshooter to apply it.", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding permission hint after opening System Settings")
    }

    static var skip: String { String(localized: "Skip", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: close the welcome") }
    static var back: String { String(localized: "Back", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: previous step") }
    static var next: String { String(localized: "Next", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: next step") }
    static var getStarted: String { String(localized: "Get Started", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button on the last step: close the welcome") }
    static var openSettings: String { String(localized: "Open System Settings…", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: open the screen recording settings") }
    static var restartNow: String { String(localized: "Restart Now", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: relaunch the app to apply the permission") }
    static var later: String { String(localized: "Later", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: continue without granting the permission") }
    static var pause: String { String(localized: "Pause animation", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: pause the demonstration") }
    static var play: String { String(localized: "Play animation", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding button: resume or replay the demonstration") }

    static func stepCounter(_ step: OnboardingStep) -> String {
        String(localized: "Step \(String(step.rawValue + 1)) of \(String(OnboardingStep.allCases.count))", bundle: L10n.bundle, locale: L10n.locale, comment: "VoiceOver label of the onboarding page dots; arguments are the current step and the total")
    }

    static var hereItIs: String { String(localized: "Here it is", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding hint next to the menu bar icon") }
    static var hintTouch: String { String(localized: "Two fingers: the capture moves aside", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding animation caption 1 of step 4") }
    static var hintScroll: String { String(localized: "Scroll or switch apps", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding animation caption 2 of step 4") }
    static var hintBack: String { String(localized: "Do nothing and it comes back", bundle: L10n.bundle, locale: L10n.locale, comment: "Onboarding animation caption 3 of step 4") }
}
