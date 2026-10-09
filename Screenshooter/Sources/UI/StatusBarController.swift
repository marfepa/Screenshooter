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
        
        // 2. Control del Strip
        let stripItem = NSMenuItem(
            title: "Mostrar / Ocultar Tira",
            action: #selector(handleToggleStripClicked),
            keyEquivalent: "t"
        )
        stripItem.keyEquivalentModifierMask = [.control, .option]
        stripItem.target = self
        menu.addItem(stripItem)
        
        let clearStripItem = NSMenuItem(
            title: "Vaciar Tira",
            action: #selector(handleClearStripClicked),
            keyEquivalent: ""
        )
        clearStripItem.target = self
        menu.addItem(clearStripItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Modo Inbox (Interceptar capturas nativas de macOS)
        let isInboxOn = InboxManager.shared.isEnabled
        let inboxItem = NSMenuItem(
            title: "Modo Inbox (Capturas nativas directas a la Tira)",
            action: #selector(handleToggleInboxClicked),
            keyEquivalent: ""
        )
        inboxItem.state = isInboxOn ? .on : .off
        inboxItem.target = self
        menu.addItem(inboxItem)
        
        // Capacidad de la tira (8 · 16 · 32 · Sin límite)
        let capacityItem = NSMenuItem(title: "Capturas en la tira", action: nil, keyEquivalent: "")
        let capacityMenu = NSMenu(title: "Capturas en la tira")
        let currentCapacity = StripManager.shared.capacity
        for value in StripCapacity.options {
            let entry = NSMenuItem(
                title: StripCapacity.title(for: value),
                action: #selector(handleCapacityClicked(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.tag = value
            entry.state = value == currentCapacity ? .on : .off
            capacityMenu.addItem(entry)
        }
        capacityItem.submenu = capacityMenu
        menu.addItem(capacityItem)
        
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
        let isLaunchAtLogin = LaunchAtLoginManager.shared.isEnabled
        let launchItem = NSMenuItem(
            title: "Abrir al iniciar el Mac",
            action: #selector(handleToggleLaunchAtLoginClicked),
            keyEquivalent: ""
        )
        launchItem.state = isLaunchAtLogin ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)
        
        let prefsItem = NSMenuItem(
            title: "Preferencias y Atajos...",
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
    
    @objc private func handleToggleStripClicked() {
        StripManager.shared.toggle()
    }
    
    @objc private func handleClearStripClicked() {
        StripManager.shared.clear()
    }
    
    @objc private func handleToggleInboxClicked() {
        InboxManager.shared.isEnabled.toggle()
        setupMenu()
    }
    
    @objc private func handleCapacityClicked(_ sender: NSMenuItem) {
        StripManager.shared.setCapacity(sender.tag)
        setupMenu()
    }
    
    @objc private func handleToggleLaunchAtLoginClicked() {
        LaunchAtLoginManager.shared.toggle()
        setupMenu()
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
        let launchStatus = LaunchAtLoginManager.shared.isEnabled ? "Activado" : "Desactivado"
        let alert = NSAlert()
        alert.messageText = "Screenshooter — Ajustes y Gestos"
        alert.informativeText = """
        • ⌥⌘S: Capturar área seleccionada.
        • ⌃⌥T: Mostrar / Ocultar la Tira.
        • Abrir al iniciar el Mac: \(launchStatus) (puedes alternarlo desde el menú).
        • Barra de menús: Posar el cursor arriba desliza la Tira automáticamente.
        
        Gestos en cada captura colgada:
        • Clic simple: Copiar al portapapeles.
        • Doble clic: Abrir en Vista Previa.
        • Mantener pulsado (o botón lápiz): Anotar con Marcación nativa de macOS (Markup).
        • Arrastrar (Drag & Drop): Soltar en Slack, Figma o Finder.
        • Botón ✕: Descartar con caída libre.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Entendido")
        alert.runModal()
    }
    
    @objc private func handleQuitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
