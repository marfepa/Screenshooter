import AppKit
import ImageIO

/// Modelo que representa una captura colgada en el Tendedero.
public struct TendederoItem: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public var image: NSImage
    public var cgImage: CGImage
    public private(set) var pixelSize: CGSize
    public private(set) var logicalSize: CGSize
    /// Ligera inclinación aleatoria (-2.5° a +2.5°) para simular una foto colgada con pinzas
    public let tilt: Double
    public let createdAt: Date
    public var isFlying: Bool = false
    
    public init(
        id: UUID = UUID(),
        url: URL,
        cgImage: CGImage,
        pixelSize: CGSize? = nil,
        logicalSize: CGSize? = nil,
        tilt: Double = Double.random(in: -2.5...2.5),
        createdAt: Date = Date(),
        isFlying: Bool = false
    ) {
        self.id = id
        self.url = url
        self.cgImage = cgImage
        let pSize = pixelSize ?? CGSize(width: cgImage.width, height: cgImage.height)
        self.pixelSize = pSize
        let lSize = logicalSize ?? CGSize(width: cgImage.width / 2, height: cgImage.height / 2)
        self.logicalSize = lSize
        self.image = NSImage(cgImage: cgImage, size: lSize)
        self.tilt = tilt
        self.createdAt = createdAt
        self.isFlying = isFlying
    }
    
    /// Recarga la imagen desde el disco tras una edición en Marcación (Markup).
    /// Lee sin caché (el archivo puede haber sido sustituido) y actualiza tamaños si Marcación recortó.
    /// Devuelve `true` si se pudo leer una imagen válida.
    @discardableResult
    public mutating func reloadFromDisk() -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let cgImg = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            return false
        }
        // Conserva la relación píxeles/puntos del item (p. ej. 2x en Retina).
        let scaleX = pixelSize.width > 0 ? logicalSize.width / pixelSize.width : 0.5
        let scaleY = pixelSize.height > 0 ? logicalSize.height / pixelSize.height : 0.5
        let newPixels = CGSize(width: cgImg.width, height: cgImg.height)
        let newLogical = CGSize(width: newPixels.width * scaleX, height: newPixels.height * scaleY)
        self.cgImage = cgImg
        self.pixelSize = newPixels
        self.logicalSize = newLogical
        self.image = NSImage(cgImage: cgImg, size: newLogical)
        return true
    }
    
    public static func == (lhs: TendederoItem, rhs: TendederoItem) -> Bool {
        return lhs.id == rhs.id && lhs.isFlying == rhs.isFlying
    }
}
