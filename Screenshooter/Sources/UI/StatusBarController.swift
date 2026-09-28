import AppKit

/// Controlador del elemento residente en la barra de menús del sistema (NSStatusItem).
@MainActor
public final class StatusBarController {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    
    public init() {
        setupStatusItem()
        setupMenu()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        
        // Usar SF Symbol si está disponible (macOS 11+) con fallback gráfico
        if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshooter") {
            image.isTemplate = true
            button.image = image
        } else if let fallback = NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshooter") {
            fallback.isTemplate = true
            button.image = fallback
        }
        
        button.toolTip = "Screenshooter (⌥⌘S para capturar área)"
    }
    
    public func setupMenu() {
        menu.removeAllItems()
        
        // 1. Acción principal de captura
        let captureItem = NSMenuItem(
            title: "Capturar área seleccionada...",
            action: #selector(handleCaptureClicked),
            keyEquivalent: "s"
        )
        captureItem.keyEquivalentModifierMask = [.command, .option]
        captureItem.target = self
        menu.addItem(captureItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Estado de permisos
        let hasPermission = PermissionsHelper.shared.isScreenCaptureGranted
        let permissionTitle = hasPermission ? "✓ Permiso de pantalla: Concedido" : "⚠️ Permiso de pantalla requerido..."
        let permissionItem = NSMenuItem(
            title: permissionTitle,
            action: #selector(handlePermissionClicked),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)
        
        if !hasPermission {
            let restartItem = NSMenuItem(
                title: "🔄 Reiniciar para aplicar permiso",
                action: #selector(handleRestartClicked),
                keyEquivalent: "r"
            )
            restartItem.keyEquivalentModifierMask = [.command]
            restartItem.target = self
            menu.addItem(restartItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Ajustes / Preferencias
        let prefsItem = NSMenuItem(
            title: "Preferencias...",
            action: #selector(handlePreferencesClicked),
            keyEquivalent: ","
        )
        prefsItem.keyEquivalentModifierMask = [.command]
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. Salir
        let quitItem = NSMenuItem(
            title: "Salir de Screenshooter",
            action: #selector(handleQuitClicked),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func handleCaptureClicked() {
        CaptureCoordinator.shared.startCapture()
    }
    
    @objc private func handlePermissionClicked() {
        if PermissionsHelper.shared.isScreenCaptureGranted {
            let alert = NSAlert()
            alert.messageText = "Permiso Concedido"
            alert.informativeText = "Screenshooter ya cuenta con autorización para capturar áreas de la pantalla."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Aceptar")
            alert.runModal()
        } else {
            PermissionsHelper.shared.promptPermissionDialogIfNeeded()
        }
    }
    
    @objc private func handleRestartClicked() {
        PermissionsHelper.shared.relaunchApp()
    }
    
    @objc private func handlePreferencesClicked() {
        let alert = NSAlert()
        alert.messageText = "Screenshooter — Ajustes"
        alert.informativeText = "Atajo global activo: ⌥⌘S (Option + Command + S)\n\nLa captura se guarda automáticamente en el portapapeles y se reproduce el sonido de obturador del sistema."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Entendido")
        alert.runModal()
    }
    
    @objc private func handleQuitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
