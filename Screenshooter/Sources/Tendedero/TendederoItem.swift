import AppKit

/// Modelo que representa una captura colgada en el Tendedero.
public struct TendederoItem: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public var image: NSImage
    public var cgImage: CGImage
    public let pixelSize: CGSize
    public let logicalSize: CGSize
    /// Ligera inclinación aleatoria (-2.5° a +2.5°) para simular una foto colgada con pinzas
    public let tilt: Double
    public let createdAt: Date
    public var isFalling: Bool = false
    public var isFlying: Bool = false
    
    public init(
        id: UUID = UUID(),
        url: URL,
        cgImage: CGImage,
        pixelSize: CGSize? = nil,
        logicalSize: CGSize? = nil,
        tilt: Double = Double.random(in: -2.5...2.5),
        createdAt: Date = Date(),
        isFalling: Bool = false,
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
        self.isFalling = isFalling
        self.isFlying = isFlying
    }
    
    /// Recarga la imagen desde el disco tras una edición en Marcación (Markup).
    public mutating func reloadFromDisk() {
        guard let data = try? Data(contentsOf: url),
              let nsImg = NSImage(data: data),
              let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        self.cgImage = cgImg
        self.image = nsImg
    }
    
    public static func == (lhs: TendederoItem, rhs: TendederoItem) -> Bool {
        return lhs.id == rhs.id && lhs.isFalling == rhs.isFalling && lhs.isFlying == rhs.isFlying
    }
}
