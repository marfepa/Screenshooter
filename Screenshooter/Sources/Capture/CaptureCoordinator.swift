import AppKit

/// Coordinador principal del ciclo de vida de captura de pantalla.
/// Administra la apertura de ventanas de superposición multi-pantalla,
/// la interacción con el usuario y la canalización del resultado hacia el portapapeles.
@MainActor
public final class CaptureCoordinator {
    public static let shared = CaptureCoordinator()
    
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var isCapturing = false
    
    private init() {}
    
    /// Inicia el flujo de selección interactiva de área en pantalla.
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
    }
    
    /// Cancela la captura en curso cerrando todas las superposiciones sin alterar el portapapeles.
    public func cancelCapture() {
        dismissOverlays()
        isCapturing = false
    }
    
    /// Procesa la selección completada por el usuario.
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
                
                if copied {
                    // Mostrar notificación HUD flotante durante 1.5s
                    let hud = HUDNotificationWindow(
                        cgImage: result.image,
                        pixelSize: CGSize(width: result.image.width, height: result.image.height)
                    )
                    hud.present()
                }
            } catch {
                NSLog("[CaptureCoordinator] Error al capturar área: %@", error.localizedDescription)
            }
            
            self.isCapturing = false
        }
    }
    
    private func dismissOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
    }
}
