import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Inicializar controlador de la barra de menús
        statusBarController = StatusBarController()
        
        // Configurar y registrar el atajo global de teclado (⌥⌘S)
        setupGlobalHotKey()
        
        // Observar cambios en pantallas conectadas (añadir/quitar monitor externo)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        NSLog("[AppDelegate] Screenshooter iniciado y residente en barra de menús.")
    }
    
    private func setupGlobalHotKey() {
        HotKeyManager.shared.onHotKeyTriggered = {
            Task { @MainActor in
                CaptureCoordinator.shared.startCapture()
            }
        }
        HotKeyManager.shared.registerDefaultHotKey()
    }
    
    @objc private func handleScreenParametersChanged() {
        statusBarController?.setupMenu()
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
    }
}
