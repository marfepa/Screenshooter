import AppKit

/// Ventana de superposición a pantalla completa para selección de área.
/// Se sitúa en el nivel .screenSaver para garantizar cobertura sobre cualquier ventana,
/// menú o espacio virtual de macOS.
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
        
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    
    public override var canBecomeKey: Bool {
        return true
    }
    
    public override var canBecomeMain: Bool {
        return true
    }
}
