import AppKit
import CoreGraphics

/// Asistente para verificación de permisos de grabación de pantalla de macOS,
/// deep linking a Ajustes del Sistema y reinicio del proceso para aplicar TCC.
public final class PermissionsHelper {
    public static let shared = PermissionsHelper()
    
    private var hasPromptedSystemDialog = false
    
    private init() {}
    
    /// Comprueba si la aplicación tiene autorización para capturar la pantalla.
    public var isScreenCaptureGranted: Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    /// Abre el panel exacto de Ajustes del Sistema en macOS Ventura, Sonoma, Sequoia y posteriores.
    public func openScreenCaptureSettings() {
        let urlStrings = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        
        for urlString in urlStrings {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
    
    /// Muestra un diálogo nativo indicando la necesidad del permiso y ofreciendo
    /// tanto la apertura de Ajustes como el reinicio necesario de la app.
    public func promptPermissionDialogIfNeeded() {
        guard !isScreenCaptureGranted else { return }
        
        // Disparar la petición del sistema una única vez para no spamear el diálogo de macOS en cada pulsación
        if !hasPromptedSystemDialog {
            hasPromptedSystemDialog = true
            CGRequestScreenCaptureAccess()
        }
        
        let alert = NSAlert()
        alert.messageText = "Permiso de Grabación de Pantalla Requerido"
        alert.informativeText = "Screenshooter necesita autorización para leer los píxeles de la pantalla.\n\n1. Ve a Ajustes del Sistema > Privacidad y Seguridad > Grabación de Pantalla y activa Screenshooter.\n\n2. Si ya lo has activado, pulsa 'Reiniciar Screenshooter' para que macOS aplique los permisos."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abrir Ajustes del Sistema")
        alert.addButton(withTitle: "Reiniciar Screenshooter")
        alert.addButton(withTitle: "Cancelar")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        } else if response == .alertSecondButtonReturn {
            relaunchApp()
        }
    }
    
    /// Reinicia la aplicación para que macOS cargue de inmediato la nueva autorización concedida.
    public func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
