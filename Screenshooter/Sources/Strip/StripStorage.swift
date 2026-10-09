import Foundation

/// Ubicación en disco de la caché de capturas de la tira ("Shelf") y migración desde la carpeta anterior.
///
/// Layout actual: `Application Support/Screenshooter/Shelf` (capturas propias) y `…/Shelf/Inbox` (Modo Inbox).
/// Layout anterior: `Application Support/Screenshooter/Screenshots` y `…/Screenshots/Inbox`.
/// Todo recibe la carpeta base inyectable (`Application Support`) para poder probarlo en directorios temporales.
enum StripStorage {
    static let rootFolderName = "Screenshooter"
    static let cacheFolderName = "Shelf"
    static let legacyCacheFolderName = "Screenshots"
    static let inboxFolderName = "Inbox"
    
    /// `Application Support` del usuario.
    static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    
    static func cacheDirectory(base: URL) -> URL {
        base.appendingPathComponent(rootFolderName, isDirectory: true)
            .appendingPathComponent(cacheFolderName, isDirectory: true)
    }
    
    static func inboxDirectory(base: URL) -> URL {
        cacheDirectory(base: base).appendingPathComponent(inboxFolderName, isDirectory: true)
    }
    
    static func legacyCacheDirectory(base: URL) -> URL {
        base.appendingPathComponent(rootFolderName, isDirectory: true)
            .appendingPathComponent(legacyCacheFolderName, isDirectory: true)
    }
    
    static func legacyInboxDirectory(base: URL) -> URL {
        legacyCacheDirectory(base: base).appendingPathComponent(inboxFolderName, isDirectory: true)
    }
    
    /// Mueve el contenido de la caché anterior a la nueva. Idempotente y sin pérdida de datos:
    /// - Solo existe la antigua: `moveItem` de la carpeta entera.
    /// - Existen ambas: se mueve archivo a archivo sin sobrescribir (nombre único si hay colisión).
    /// - Devuelve el número de elementos movidos (0 si no había nada que migrar).
    @discardableResult
    static func migrateLegacyCache(base: URL, fileManager fm: FileManager = .default) -> Int {
        let old = legacyCacheDirectory(base: base)
        let new = cacheDirectory(base: base)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        
        if !fm.fileExists(atPath: new.path) {
            let count = (try? fm.contentsOfDirectory(atPath: old.path).count) ?? 0
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                return count
            } catch {
                NSLog("[StripStorage] No se pudo mover la caché anterior de una vez (%@); se intenta archivo a archivo.", "\(error)")
            }
        }
        
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        let moved = mergeContents(of: old, into: new, fileManager: fm)
        // Solo se elimina la carpeta antigua si quedó vacía (nunca se borra contenido).
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
            try? fm.removeItem(at: old)
        }
        return moved
    }
    
    private static func mergeContents(of source: URL, into destination: URL, fileManager fm: FileManager) -> Int {
        guard let children = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return 0 }
        var moved = 0
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)
            
            if childIsDir && targetExists && targetIsDir.boolValue {
                moved += mergeContents(of: child, into: target, fileManager: fm)
                if (try? fm.contentsOfDirectory(atPath: child.path))?.isEmpty == true {
                    try? fm.removeItem(at: child)
                }
                continue
            }
            let finalTarget = targetExists ? uniqueURL(for: target, fileManager: fm) : target
            do {
                try fm.moveItem(at: child, to: finalTarget)
                moved += 1
            } catch {
                NSLog("[StripStorage] No se pudo migrar %@: %@", child.lastPathComponent, "\(error)")
            }
        }
        return moved
    }
    
    /// "nombre.png" -> "nombre 2.png", "nombre 3.png"… hasta encontrar un nombre libre.
    static func uniqueURL(for url: URL, fileManager fm: FileManager = .default) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
