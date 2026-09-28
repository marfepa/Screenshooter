import AppKit
import CoreGraphics

/// Asistente para verificación de permisos de grabación de pantalla de macOS y deep linking a Ajustes del Sistema.
public final class PermissionsHelper {
    public static let shared = PermissionsHelper()
    
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
    
    /// Muestra un diálogo nativo indicando la necesidad del permiso y ofreciendo el botón directo para abrir Ajustes.
    public func promptPermissionDialogIfNeeded() {
        guard !isScreenCaptureGranted else { return }
        
        // Disparar la petición del sistema (esto hace que macOS registre la app en la lista de Privacidad)
        CGRequestScreenCaptureAccess()
        
        let alert = NSAlert()
        alert.messageText = "Permiso de Grabación de Pantalla Requerido"
        alert.informativeText = "Screenshooter necesita autorización para capturar áreas de la pantalla y copiarlas al portapapeles.\n\nPor favor, concede acceso en Ajustes del Sistema > Privacidad y Seguridad > Grabación de Pantalla."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abrir Ajustes del Sistema")
        alert.addButton(withTitle: "Más tarde")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }
}
