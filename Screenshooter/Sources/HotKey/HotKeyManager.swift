import Carbon
import Cocoa

/// Gestor de atajos globales de teclado utilizando la API de Carbon.
/// Esta aproximación permite escuchar combinaciones globales (como ⌥⌘S)
/// sin requerir que el usuario active permisos de accesibilidad (Accessibility) en Ajustes del Sistema.
public final class HotKeyManager {
    public static let shared = HotKeyManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var tendederoHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    public var onHotKeyTriggered: (() -> Void)?
    public var onTendederoHotKeyTriggered: (() -> Void)?
    
    private let signature = OSType(0x5343524E) // 'SCRN'
    private let captureHotKeyIDNumber: UInt32 = 1
    private let tendederoHotKeyIDNumber: UInt32 = 2
    
    private init() {}
    
    /// Registra el atajo por defecto para captura: Option + Command + S (⌥⌘S)
    public func registerDefaultHotKey() {
        registerCapture(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey))
    }
    
    /// Registra el atajo por defecto para el Tendedero: Control + Option + T (⌃⌥T)
    public func registerTendederoHotKey() {
        unregisterTendedero()
        installEventHandlerIfNeeded()
        
        let hotKeyID = EventHotKeyID(signature: signature, id: tendederoHotKeyIDNumber)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &tendederoHotKeyRef
        )
        if status != noErr {
            NSLog("[HotKeyManager] Error al registrar atajo de Tendedero (⌃⌥T): %d", status)
        }
    }
    
    /// Registra una combinación arbitraria de código de tecla y modificadores de Carbon para captura
    public func registerCapture(keyCode: UInt32, modifiers: UInt32) {
        unregisterCapture()
        installEventHandlerIfNeeded()
        
        let hotKeyID = EventHotKeyID(signature: signature, id: captureHotKeyIDNumber)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status != noErr {
            NSLog("[HotKeyManager] Error al registrar atajo de teclado: %d", status)
        } else {
            NSLog("[HotKeyManager] Atajo global registrado correctamente (keyCode: %d, modifiers: %d)", keyCode, modifiers)
        }
    }
    
    /// Da de baja los atajos actualmente registrados
    public func unregister() {
        unregisterCapture()
        unregisterTendedero()
    }
    
    public func unregisterCapture() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
    
    public func unregisterTendedero() {
        if let ref = tendederoHotKeyRef {
            UnregisterEventHotKey(ref)
            tendederoHotKeyRef = nil
        }
    }
    
    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr && hotKeyID.signature == OSType(0x5343524E) {
                DispatchQueue.main.async {
                    if hotKeyID.id == 1 {
                        HotKeyManager.shared.onHotKeyTriggered?()
                    } else if hotKeyID.id == 2 {
                        HotKeyManager.shared.onTendederoHotKeyTriggered?()
                    }
                }
            }
            return noErr
        }
        
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        
        if installStatus != noErr {
            NSLog("[HotKeyManager] Error al instalar el gestor de eventos Carbon: %d", installStatus)
        }
    }
    
    deinit {
        unregister()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }
}
