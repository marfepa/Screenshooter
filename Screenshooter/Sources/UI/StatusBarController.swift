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
        
        button.toolTip = String(localized: "Screenshooter (⌥⌘S to capture an area)", bundle: L10n.bundle, locale: L10n.locale, comment: "Status bar icon tooltip")
    }
    
    public func setupMenu() {
        menu.removeAllItems()
        
        // 1. Acción principal de captura
        let captureItem = NSMenuItem(
            title: String(localized: "Capture Selected Area...", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: start an area capture"),
            action: #selector(handleCaptureClicked),
            keyEquivalent: "s"
        )
        captureItem.keyEquivalentModifierMask = [.command, .option]
        captureItem.target = self
        menu.addItem(captureItem)
        
        // 2. Control del Strip
        let stripItem = NSMenuItem(
            title: String(localized: "Show / Hide Shelf", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: toggle the capture shelf (strip)"),
            action: #selector(handleToggleStripClicked),
            keyEquivalent: "t"
        )
        stripItem.keyEquivalentModifierMask = [.control, .option]
        stripItem.target = self
        menu.addItem(stripItem)
        
        let clearStripItem = NSMenuItem(
            title: String(localized: "Clear Shelf", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: move all captures of the shelf to the Trash"),
            action: #selector(handleClearStripClicked),
            keyEquivalent: ""
        )
        clearStripItem.target = self
        menu.addItem(clearStripItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Modo Inbox (Interceptar capturas nativas de macOS)
        let isInboxOn = InboxManager.shared.isEnabled
        let inboxItem = NSMenuItem(
            title: String(localized: "Inbox Mode (native screenshots go straight to the Shelf)", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: inbox mode toggle"),
            action: #selector(handleToggleInboxClicked),
            keyEquivalent: ""
        )
        inboxItem.state = isInboxOn ? .on : .off
        inboxItem.target = self
        menu.addItem(inboxItem)
        
        // Capacidad de la tira (8 · 16 · 32 · Sin límite)
        let capacityItem = NSMenuItem(title: String(localized: "Shelf capacity", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: submenu to choose how many captures the shelf keeps"), action: nil, keyEquivalent: "")
        let capacityMenu = NSMenu(title: String(localized: "Shelf capacity", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: submenu to choose how many captures the shelf keeps"))
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
        let permissionTitle = hasPermission
            ? String(localized: "✓ Screen permission: Granted", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: screen recording permission is granted")
            : String(localized: "⚠️ Screen permission required...", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: screen recording permission is missing")
        let permissionItem = NSMenuItem(
            title: permissionTitle,
            action: #selector(handlePermissionClicked),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)
        
        if !hasPermission {
            let restartItem = NSMenuItem(
                title: String(localized: "🔄 Restart to apply permission", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: relaunch the app so macOS applies the new permission"),
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
            title: String(localized: "Open at Login", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: launch at login toggle"),
            action: #selector(handleToggleLaunchAtLoginClicked),
            keyEquivalent: ""
        )
        launchItem.state = isLaunchAtLogin ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)
        
        let prefsItem = NSMenuItem(
            title: String(localized: "Preferences & Shortcuts...", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: show the shortcuts and gestures help"),
            action: #selector(handlePreferencesClicked),
            keyEquivalent: ","
        )
        prefsItem.keyEquivalentModifierMask = [.command]
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 4. Salir
        let quitItem = NSMenuItem(
            title: String(localized: "Quit Screenshooter", bundle: L10n.bundle, locale: L10n.locale, comment: "Menu item: quit the app"),
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
            alert.messageText = String(localized: "Permission Granted", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert title: screen recording permission already granted")
            alert.informativeText = String(localized: "Screenshooter is already authorized to capture areas of the screen.", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert body: screen recording permission already granted")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: acknowledge"))
            alert.runModal()
        } else {
            PermissionsHelper.shared.promptPermissionDialogIfNeeded()
        }
    }
    
    @objc private func handleRestartClicked() {
        PermissionsHelper.shared.relaunchApp()
    }
    
    @objc private func handlePreferencesClicked() {
        let launchStatus = LaunchAtLoginManager.shared.isEnabled
            ? String(localized: "On", bundle: L10n.bundle, locale: L10n.locale, comment: "Setting state: enabled")
            : String(localized: "Off", bundle: L10n.bundle, locale: L10n.locale, comment: "Setting state: disabled")
        let alert = NSAlert()
        alert.messageText = String(localized: "Screenshooter — Settings & Gestures", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert title: shortcuts and gestures help")
        alert.informativeText = String(localized: """
        • ⌥⌘S: Capture the selected area.
        • ⌃⌥T: Show / Hide the Shelf.
        • Open at Login: \(launchStatus) (you can toggle it from the menu).
        • Menu bar: moving the pointer to the top slides the Shelf down automatically.

        Gestures on each hanging capture:
        • Single click: Copy to the clipboard.
        • Double click: Open in Preview.
        • Press and hold (or pencil button): Annotate with the native macOS Markup.
        • Drag and drop: Drop into Slack, Figma or Finder.
        • ✕ button: Discard with a free fall.
        """, bundle: L10n.bundle, locale: L10n.locale, comment: "Help alert body listing shortcuts and gestures; the argument is the launch-at-login state (On/Off)")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Got it", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: dismiss the help"))
        alert.runModal()
    }
    
    @objc private func handleQuitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
