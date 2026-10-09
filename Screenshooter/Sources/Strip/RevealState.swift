import Foundation

/// Accion que debe ejecutar el panel tras evaluar un tick.
public enum RevealAction: Equatable {
    case reveal, retract, none
}

/// Maquina de estados pura (sin AppKit) que decide cuando se revela y se retrae la tira.
public struct RevealState {
    public static let revealDelay: TimeInterval = 0.25
    public static let retractDelay: TimeInterval = 0.5

    public private(set) var isRevealed = false
    public private(set) var hotZoneSince: Date?
    public private(set) var awaySince: Date?
    public private(set) var menuBarSuppressed = false
    public private(set) var pinned = false
    public private(set) var peekUntil = Date.distantPast

    public init() {}

    public mutating func tick(now: Date, inMenuBar: Bool, inZone: Bool, fullScreen: Bool, busy: Bool) -> RevealAction {
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            if inMenuBar && !menuBarSuppressed && !fullScreen {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    return .reveal
                }
            } else {
                hotZoneSince = nil
            }
            return .none
        }

        if inZone && pinned { pinned = false }
        if inZone || pinned || busy || now < peekUntil {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                return .retract
            }
        }
        return .none
    }

    /// Clic en la barra de menus: suprime la revelacion hasta salir de la franja y retrae si estaba revelada.
    public mutating func menuBarClicked() -> RevealAction {
        menuBarSuppressed = true
        hotZoneSince = nil
        if isRevealed {
            pinned = false
            return .retract
        }
        return .none
    }

    public mutating func pin() { pinned = true }
    public mutating func peek(until date: Date) { peekUntil = date }

    public mutating func didReveal() {
        isRevealed = true
        hotZoneSince = nil
        awaySince = nil
    }

    public mutating func didRetract() {
        isRevealed = false
        awaySince = nil
        pinned = false
        peekUntil = .distantPast
    }
}
