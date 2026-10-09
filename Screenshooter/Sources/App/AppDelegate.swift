import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Host de tests (la app lanzada por XCTest): nada que toque Application Support, UserDefaults
        // ni com.apple.screencapture reales. La base de la caché ya es un temporal (`StripStorage.defaultBase`).
        if StripStorage.isRunningTests {
            StripManager.shared.defaults = UserDefaults(suiteName: "screenshooter-tests-\(UUID().uuidString)") ?? UserDefaults()
            return
        }
        
        // Inicializar controlador de la barra de menús
        statusBarController = StatusBarController()
        
        // Inicializar subsistemas del Strip y Modo Inbox
        _ = StripManager.shared
        _ = InboxManager.shared
        
        // Configurar y registrar los atajos globales de teclado (⌥⌘S y ⌃⌥T)
        setupGlobalHotKey()
        
        // Observar cambios en pantallas conectadas (añadir/quitar monitor externo)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        NSLog("[AppDelegate] Screenshooter iniciado con Strip y Modo Inbox.")
    }
    
    private func setupGlobalHotKey() {
        HotKeyManager.shared.onHotKeyTriggered = {
            Task { @MainActor in
                CaptureCoordinator.shared.startCapture()
            }
        }
        HotKeyManager.shared.onStripHotKeyTriggered = {
            Task { @MainActor in
                StripManager.shared.toggle()
            }
        }
        HotKeyManager.shared.registerDefaultHotKey()
        HotKeyManager.shared.registerStripHotKey()
    }
    
    @objc private func handleScreenParametersChanged() {
        statusBarController?.setupMenu()
        StripManager.shared.setupPanel()
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        if StripStorage.isRunningTests { return }
        HotKeyManager.shared.unregister()
        
        // Si el modo Inbox estaba activo, restaurar preferencias originales de macOS
        if InboxManager.shared.isEnabled {
            InboxManager.shared.disableInboxMode()
        }
    }
}
