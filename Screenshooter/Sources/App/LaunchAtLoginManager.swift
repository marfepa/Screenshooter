import Foundation
import ServiceManagement

/// Gestor responsable de registrar y desregistrar la aplicación
/// para que arranque automáticamente al iniciar sesión en macOS.
/// Utiliza la API moderna SMAppService de Apple (disponible en macOS 13+).
@MainActor
public final class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()
    
    private init() {}
    
    /// Comprueba si la aplicación está configurada para arrancar al iniciar el Mac.
    public var isEnabled: Bool {
        get {
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled { return }
                    try SMAppService.mainApp.register()
                    NSLog("[LaunchAtLoginManager] Screenshooter registrado para arrancar al inicio de sesión.")
                } else {
                    if SMAppService.mainApp.status != .enabled { return }
                    try SMAppService.mainApp.unregister()
                    NSLog("[LaunchAtLoginManager] Screenshooter desregistrado del arranque de sesión.")
                }
            } catch {
                NSLog("[LaunchAtLoginManager] Error al configurar arranque al inicio: %@", error.localizedDescription)
            }
        }
    }
    
    /// Alterna el estado actual de arranque al iniciar sesión.
    public func toggle() {
        isEnabled = !isEnabled
    }
}
