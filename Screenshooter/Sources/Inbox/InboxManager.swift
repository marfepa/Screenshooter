import Foundation
import AppKit

/// Gestor del Modo Inbox:
/// Intercepta las capturas nativas de macOS (⌘⇧3, ⌘⇧4, ⌘⇧5, CleanShot, etc.)
/// 1. Elimina el retraso de 5 segundos de la miniatura flotante de Apple (`show-thumbnail = false`).
/// 2. Redirige el destino de guardado a la carpeta del Tendedero para no ensuciar el Escritorio.
/// 3. Detecta la captura en tiempo real, lee sus coordenadas originales y la cuelga en el Tendedero.
/// 4. Restaura las preferencias originales del usuario de forma segura al desactivarse o al salir la app.
@MainActor
public final class InboxManager {
    public static let shared = InboxManager()
    
    private static let domain = "com.apple.screencapture" as CFString
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    
    private static let isEnabledKey = "inboxModeEnabled"
    private static let savedLocationKey = "inboxSavedLocation"
    private static let savedThumbnailKey = "inboxSavedThumbnail"
    
    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var knownFiles = Set<String>()
    
    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.isEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.isEnabledKey)
            if newValue {
                enableInboxMode()
            } else {
                disableInboxMode()
            }
        }
    }
    
    private init() {
        if isEnabled {
            enableInboxMode()
        }
    }
    
    // MARK: - Activación y Desactivación
    
    public func enableInboxMode() {
        saveOriginalPreferencesIfNeeded()
        
        let destinationPath = TendederoManager.screenshotsDirectory.path
        
        // 1. Redirigir la carpeta donde macOS guarda las capturas
        CFPreferencesSetAppValue(Self.locationKey, destinationPath as CFString, Self.domain)
        CFPreferencesSetAppValue(Self.screenshotLocationKey, destinationPath as CFString, Self.domain)
        
        // 2. Desactivar el thumbnail flotante lento de macOS para que se guarde de inmediato
        CFPreferencesSetAppValue(Self.thumbnailKey, kCFBooleanFalse, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
        
        // Reiniciar demonio de screencapture para aplicar cambios
        killSystemScreencaptureService()
        
        // 3. Comenzar a observar la carpeta
        startWatchingScreenshotsFolder()
        
        NSLog("[InboxManager] Modo Inbox activado. Capturas de macOS redirigidas al Tendedero.")
    }
    
    public func disableInboxMode() {
        stopWatchingScreenshotsFolder()
        restoreOriginalPreferences()
        killSystemScreencaptureService()
        NSLog("[InboxManager] Modo Inbox desactivado. Preferencias de macOS restauradas.")
    }
    
    // MARK: - Preservación y Restauración de Ajustes
    
    private func saveOriginalPreferencesIfNeeded() {
        CFPreferencesAppSynchronize(Self.domain)
        
        // Guardar location previa si aún no se guardó
        if UserDefaults.standard.object(forKey: Self.savedLocationKey) == nil {
            let oldLocation = (CFPreferencesCopyAppValue(Self.screenshotLocationKey, Self.domain) as? String)
                ?? (CFPreferencesCopyAppValue(Self.locationKey, Self.domain) as? String)
                ?? ""
            UserDefaults.standard.set(oldLocation, forKey: Self.savedLocationKey)
        }
        
        // Guardar thumbnail previo si aún no se guardó
        if UserDefaults.standard.object(forKey: Self.savedThumbnailKey) == nil {
            let oldThumb = (CFPreferencesCopyAppValue(Self.thumbnailKey, Self.domain) as? Bool) ?? true
            UserDefaults.standard.set(oldThumb, forKey: Self.savedThumbnailKey)
        }
    }
    
    private func restoreOriginalPreferences() {
        CFPreferencesAppSynchronize(Self.domain)
        
        if let savedLocation = UserDefaults.standard.string(forKey: Self.savedLocationKey) {
            if savedLocation.isEmpty {
                CFPreferencesSetAppValue(Self.locationKey, nil, Self.domain)
                CFPreferencesSetAppValue(Self.screenshotLocationKey, nil, Self.domain)
            } else {
                CFPreferencesSetAppValue(Self.locationKey, savedLocation as CFString, Self.domain)
                CFPreferencesSetAppValue(Self.screenshotLocationKey, savedLocation as CFString, Self.domain)
            }
        }
        
        if let savedThumb = UserDefaults.standard.object(forKey: Self.savedThumbnailKey) as? Bool {
            CFPreferencesSetAppValue(Self.thumbnailKey, (savedThumb ? kCFBooleanTrue : kCFBooleanFalse), Self.domain)
        }
        
        CFPreferencesAppSynchronize(Self.domain)
        
        UserDefaults.standard.removeObject(forKey: Self.savedLocationKey)
        UserDefaults.standard.removeObject(forKey: Self.savedThumbnailKey)
    }
    
    private func killSystemScreencaptureService() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["SystemUIServer"]
        try? task.run()
    }
    
    // MARK: - Observación de Archivos con DispatchSource
    
    private func startWatchingScreenshotsFolder() {
        stopWatchingScreenshotsFolder()
        
        let folder = TendederoManager.screenshotsDirectory
        
        // Inventario inicial
        if let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            knownFiles = Set(contents.map { $0.lastPathComponent })
        }
        
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.checkForNewFiles()
            }
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        self.fileWatcherSource = source
    }
    
    private func stopWatchingScreenshotsFolder() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
    }
    
    private func checkForNewFiles() {
        let folder = TendederoManager.screenshotsDirectory
        guard let current = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        
        for url in current {
            let filename = url.lastPathComponent
            guard !knownFiles.contains(filename),
                  ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) else {
                continue
            }
            
            knownFiles.insert(filename)
            handleNewScreenshot(url: url)
        }
    }
    
    private func handleNewScreenshot(url: URL) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return
        }
        
        // Leer coordenadas originales en pantalla desde el xattr de macOS
        let captureOriginRect = readCaptureRect(from: url)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        
        // Copiar al portapapeles y colgar en el Tendedero con animación
        ClipboardService.shared.copy(cgImage: cgImage, playSound: true)
        TendederoManager.shared.hang(url: url, cgImage: cgImage, fromRect: captureOriginRect, screen: screen)
    }
    
    /// Lee el atributo extendido com.apple.metadata:kMDItemScreenCaptureGlobalRect
    /// que macOS asigna a cada captura nativa con su rectángulo de pantalla.
    private func readCaptureRect(from url: URL) -> CGRect? {
        let attributeName = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
        let data: Data? = url.withUnsafeFileSystemRepresentation { path in
            guard let path = path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, 0) }
            return read == size ? buffer : nil
        }
        
        guard let data = data,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
              values.count == 4,
              let mainScreen = NSScreen.screens.first else {
            return nil
        }
        
        let x = CGFloat(truncating: values[0])
        let y = CGFloat(truncating: values[1])
        let width = CGFloat(truncating: values[2])
        let height = CGFloat(truncating: values[3])
        guard width > 2, height > 2 else { return nil }
        
        // Convertir de coordenadas globales de pantalla de Quartz a coordenadas de AppKit
        return CGRect(x: x, y: mainScreen.frame.maxY - y - height, width: width, height: height)
    }
}
