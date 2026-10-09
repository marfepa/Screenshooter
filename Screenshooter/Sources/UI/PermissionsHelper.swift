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
        alert.messageText = String(localized: "Screen Recording Permission Required", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert title: the app needs screen recording permission")
        alert.informativeText = String(localized: """
        Screenshooter needs authorization to read the pixels of the screen.

        1. Go to System Settings > Privacy & Security > Screen Recording and turn on Screenshooter.

        2. If you have already turned it on, click 'Restart Screenshooter' so macOS applies the permission.
        """, bundle: L10n.bundle, locale: L10n.locale, comment: "Alert body explaining how to grant screen recording permission")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Open System Settings", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: open System Settings"))
        alert.addButton(withTitle: String(localized: "Restart Screenshooter", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: relaunch the app"))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: cancel"))
        
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
