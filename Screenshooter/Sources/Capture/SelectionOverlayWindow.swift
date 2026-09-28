import AppKit

/// Ventana de superposición a pantalla completa para selección de área.
/// Se sitúa en el nivel .screenSaver para garantizar cobertura sobre cualquier ventana,
/// menú o espacio virtual de macOS.
public final class SelectionOverlayWindow: NSWindow {
    public let selectionView: SelectionView
    
    public init(screen: NSScreen) {
        let contentRect = screen.frame
        self.selectionView = SelectionView(frame: NSRect(origin: .zero, size: contentRect.size), screen: screen)
        
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.contentView = selectionView
    }
    
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return true
    }
}
