import AppKit

/// Coordinador principal del ciclo de vida de captura de pantalla.
/// Administra la apertura de ventanas de superposición multi-pantalla,
/// la interacción con el usuario y la canalización del resultado hacia el portapapeles.
@MainActor
public final class CaptureCoordinator {
    public static let shared = CaptureCoordinator()
    
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var isCapturing = false
    private var activeHUD: HUDNotificationWindow?
    private var safetyTimer: Timer?
    
    private init() {}
    
    /// Inicia el modo de captura continua: el usuario selecciona áreas una tras otra
    /// hasta pulsar ESC (o hasta que salte el temporizador de inactividad).
    public func startCapture() {
        guard !isCapturing else { return }
        
        // Verificar permisos antes de oscurecer pantallas
        if !PermissionsHelper.shared.isScreenCaptureGranted {
            PermissionsHelper.shared.promptPermissionDialogIfNeeded()
            return
        }
        
        isCapturing = true
        presentOverlays()
    }
    
    /// Presenta una ventana de superposición transparente por cada monitor activo.
    private func presentOverlays() {
        dismissOverlays()
        
        // Activar la aplicación explícitamente para que reciba eventos de ratón y teclado siendo LSUIElement
        NSApp.activate(ignoringOtherApps: true)
        
        for screen in NSScreen.screens {
            let overlay = SelectionOverlayWindow(screen: screen)
            
            overlay.selectionView.onSelectionCompleted = { [weak self] selectedRect, targetScreen in
                self?.handleSelectionCompleted(rect: selectedRect, on: targetScreen)
            }
            
            overlay.selectionView.onCancelled = { [weak self] in
                self?.cancelCapture()
            }
            
            overlay.orderFrontRegardless()
            overlayWindows.append(overlay)
        }
        
        // Asegurar foco y primer respondedor en la ventana de la pantalla activa para capturar atajos como ESC
        if let keyWindow = overlayWindows.first(where: { $0.screen == NSScreen.main }) ?? overlayWindows.first {
            keyWindow.makeKey()
            keyWindow.makeFirstResponder(keyWindow.selectionView)
        }
        
        // Temporizador de seguridad: si el overlay lleva más de 30 segundos
        // sin interacción completada, cancelar automáticamente para evitar bloqueos.
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                NSLog("[CaptureCoordinator] Temporizador de seguridad: cancelando captura por inactividad.")
                self?.cancelCapture()
            }
        }
    }
    
    /// Cancela la captura en curso cerrando todas las superposiciones sin alterar el portapapeles.
    public func cancelCapture() {
        dismissOverlays()
        isCapturing = false
    }
    
    /// Procesa la selección completada por el usuario. `isCapturing` sigue en `true`:
    /// el modo continuo solo termina en `cancelCapture()` o si la captura falla.
    private func handleSelectionCompleted(rect: CGRect, on screen: NSScreen) {
        // Cerrar inmediatamente todas las superposiciones para que no aparezcan en la captura
        dismissOverlays()
        
        Task {
            do {
                // Capturar el área seleccionada
                let result = try await ScreenCaptureEngine.shared.captureArea(rect: rect, on: screen)
                
                // Copiar al portapapeles y reproducir sonido de obturador
                let copied = ClipboardService.shared.copy(
                    cgImage: result.image,
                    logicalSize: rect.size,
                    playSound: true
                )
                
                // Guardar en la caché del Strip y colgar la captura con animación de vuelo
                let savedURL = StripManager.shared.saveToCache(cgImage: result.image)
                if let url = savedURL {
                    StripManager.shared.hang(
                        url: url,
                        cgImage: result.image,
                        fromRect: rect,
                        screen: screen
                    )
                }
                
                if copied && savedURL == nil {
                    // Solo HUD si no hay tira: con savedURL, la tira + vuelo + sonido ya confirman la captura
                    self.activeHUD?.dismiss()
                    let hud = HUDNotificationWindow(
                        cgImage: result.image,
                        pixelSize: CGSize(width: result.image.width, height: result.image.height),
                        fileURL: savedURL
                    )
                    self.activeHUD = hud
                    hud.present()
                }
                
                // Modo continuo: volver a mostrar los overlays para la siguiente selección
                // (también reinicia el temporizador de inactividad)
                if self.isCapturing {
                    self.presentOverlays()
                }
            } catch {
                // Salir del modo antes de la alerta: un overlay la taparía
                self.isCapturing = false
                NSLog("[CaptureCoordinator] Error al capturar área: %@", error.localizedDescription)
                self.showErrorAlert(message: error.localizedDescription)
            }
        }
    }
    
    private func dismissOverlays() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
    }
    
    /// Muestra una alerta de error visible por encima de cualquier ventana.
    /// Es seguro usar runModal() aquí porque los overlays ya están cerrados
    /// y la ventana de la alerta se eleva a nivel flotante para garantizar
    /// visibilidad en apps LSUIElement.
    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Capture Error", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert title: capturing the screen failed")
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK", bundle: L10n.bundle, locale: L10n.locale, comment: "Alert button: acknowledge"))
        
        // Activar la app para que reciba foco de teclado siendo LSUIElement
        NSApp.activate(ignoringOtherApps: true)
        // Elevar la ventana de la alerta al nivel flotante para que sea visible
        alert.window.level = .floating
        alert.runModal()
    }
}
