import AppKit

/// Ventana de superposición a pantalla completa para selección de área.
/// Se sitúa por encima de menús emergentes pero por debajo de alertas del sistema,
/// permitiendo cobertura sobre ventanas normales, Dock y barra de menú.
public final class SelectionOverlayWindow: NSWindow {
    public private(set) var selectionView: SelectionView!
    
    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
    }
    
    public convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        self.selectionView = view
        self.contentView = view
        
        // Nivel suficiente para cubrir ventanas normales, Dock y barra de menú,
        // pero por debajo de alertas del sistema y Force Quit (⌥⌘Esc).
        self.level = .init(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Desactivar la liberación automática de AppKit al cerrar para evitar
        // double-free con ARC (NSWindow.close() envía un release extra por defecto).
        self.isReleasedWhenClosed = false
    }
    
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return true
    }
}
