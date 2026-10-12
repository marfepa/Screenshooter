import CoreGraphics
import Foundation

/// Cose fotogramas de una captura con scroll vertical en una sola imagen alta.
///
/// Lógica pura (CoreGraphics + Foundation): recibe fotogramas del mismo tamaño y solo
/// añade al lienzo las filas nuevas. Detecta cabeceras y pies «sticky» (filas que no se
/// mueven con el scroll) y nunca cose un hueco: si no hay solape fiable devuelve `.noOverlap`
/// y conserva la referencia anterior.
public final class ScrollStitcher {
    public struct Configuration: Equatable {
        /// Alto máximo de la imagen final en píxeles.
        public var maxHeight: Int = 30_000
        /// Paso horizontal al calcular la firma de cada fila.
        public var downsample: Int = 4
        /// Filas de contenido que deben coincidir para aceptar un desplazamiento.
        public var minOverlapRows: Int = 24
        /// Proporción de filas distintivas que deben coincidir.
        public var minMatchRatio: Double = 0.9

        public init(maxHeight: Int = 30_000, downsample: Int = 4, minOverlapRows: Int = 24, minMatchRatio: Double = 0.9) {
            self.maxHeight = maxHeight
            self.downsample = downsample
            self.minOverlapRows = minOverlapRows
            self.minMatchRatio = minMatchRatio
        }
    }

    public enum Outcome: Equatable {
        case appended(rows: Int)
        case unchanged
        case noOverlap
        case limitReached
    }

    // MARK: - Estado público

    public let width: Int
    /// Alto que tendría `makeImage()` ahora mismo (lienzo + pie).
    public var height: Int { canvasRows + footerRows }
    public private(set) var isAtLimit = false
    public private(set) var fixedTopRows = 0
    public private(set) var fixedBottomRows = 0
    public private(set) var acceptedFrameCount = 1

    // MARK: - Estado interno

    private let configuration: Configuration
    private let frameHeight: Int
    private var rowBytes: Int { width * 4 }

    /// Filas RGBA acumuladas (sin el pie).
    private var canvas: [UInt8] = []
    private var canvasRows = 0
    /// Pie fijo guardado aparte; `makeImage()` lo añade al final.
    private var footer: [UInt8] = []
    private var footerRows: Int { footer.count / max(rowBytes, 1) }
    private var bandsFixed = false

    /// Firmas del fotograma de referencia y del fotograma en curso (reutilizadas, sin asignar por fila).
    private var refSigs: [UInt64]
    private var refDistinct: [Bool]
    private var newSigs: [UInt64]
    private var newDistinct: [Bool]
    /// Píxeles del fotograma en curso (buffer reutilizado).
    private var pixels: [UInt8]
    /// Fila del lienzo donde empieza la zona de contenido de la referencia.
    private var refTop = 0

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Coincidencias distintivas mínimas absolutas para no fiarse de un solape casi vacío.
    private static let minAbsoluteMatches = 8

    // MARK: - Init

    public init?(firstFrame: CGImage, configuration: Configuration = .init()) {
        let w = firstFrame.width, h = firstFrame.height
        guard w > 0, h > 0 else { return nil }
        var config = configuration
        config.downsample = max(1, config.downsample)
        self.configuration = config
        self.width = w
        self.frameHeight = h
        self.pixels = [UInt8](repeating: 0, count: w * h * 4)
        self.refSigs = [UInt64](repeating: 0, count: h)
        self.refDistinct = [Bool](repeating: false, count: h)
        self.newSigs = refSigs
        self.newDistinct = refDistinct
        guard render(firstFrame) else { return nil }
        computeSignatures()
        swap(&refSigs, &newSigs)
        swap(&refDistinct, &newDistinct)
        canvas = pixels
        canvasRows = h
        isAtLimit = height >= config.maxHeight
    }

    // MARK: - Añadir fotogramas

    @discardableResult
    public func add(_ frame: CGImage) -> Outcome {
        if isAtLimit { return .limitReached }
        guard frame.width == width, frame.height == frameHeight, render(frame) else { return .noOverlap }
        computeSignatures()

        var top = fixedTopRows, bottom = fixedBottomRows
        if !bandsFixed {
            if newSigs == refSigs { return .unchanged }
            (top, bottom) = detectBands()
        }

        guard let d = bestShift(top: top, bottom: bottom) else {
            // Todo uniforme en ambos lados: no hay información para decidir, no es un salto.
            return hasDistinctRows(top: top, bottom: bottom) ? .noOverlap : .unchanged
        }

        if !bandsFixed {
            bandsFixed = true
            fixedTopRows = top
            fixedBottomRows = bottom
            if bottom > 0, canvasRows >= bottom {
                // El pie del primer fotograma no puede quedar en medio del lienzo.
                let cut = (canvasRows - bottom) * rowBytes
                footer = Array(canvas[cut...])
                canvas.removeSubrange(cut...)
                canvasRows -= bottom
            }
            refTop = top
        }

        let contentH = frameHeight - top - bottom
        let newTop = refTop + d
        let overhang = min(max(0, newTop + contentH - canvasRows), contentH)
        let allowed = max(0, configuration.maxHeight - height)
        let rowsToAdd = min(overhang, allowed)

        if rowsToAdd > 0 {
            let start = (top + contentH - overhang) * rowBytes
            canvas.append(contentsOf: pixels[start..<(start + rowsToAdd * rowBytes)])
            canvasRows += rowsToAdd
        }
        swap(&refSigs, &newSigs)
        swap(&refDistinct, &newDistinct)
        refTop = max(0, newTop)

        if rowsToAdd < overhang {
            isAtLimit = true
            acceptedFrameCount += rowsToAdd > 0 ? 1 : 0
            return .limitReached
        }
        if rowsToAdd > 0 {
            acceptedFrameCount += 1
            if height >= configuration.maxHeight { isAtLimit = true }
            return .appended(rows: rowsToAdd)
        }
        return .unchanged
    }

    // MARK: - Resultado

    public func makeImage() -> CGImage? {
        let data = Data(canvas) + Data(footer)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: Self.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Miniatura del lienzo + pie, muestreada por paso (vecino más cercano) directamente del buffer,
    /// sin copiar el lienzo. Ancho = `min(maxWidth, width)`, alto proporcional (≥ 1).
    public func makePreview(maxWidth: Int) -> CGImage? {
        let outW = min(max(1, maxWidth), width)
        let totalRows = height
        guard totalRows > 0 else { return nil }
        let outH = max(1, Int((Double(totalRows) * Double(outW) / Double(width)).rounded()))
        var out = [UInt32](repeating: 0, count: outW * outH)
        let cRows = canvasRows
        let xTable = (0..<outW).map { $0 * width / outW }
        out.withUnsafeMutableBufferPointer { dst in
            canvas.withUnsafeBytes { cv in
                footer.withUnsafeBytes { ft in
                    xTable.withUnsafeBufferPointer { xs in
                        for y in 0..<outH {
                            let sy = min(totalRows - 1, y * totalRows / outH)
                            let base: UnsafeRawPointer
                            if sy < cRows {
                                base = cv.baseAddress! + sy * rowBytes
                            } else {
                                base = ft.baseAddress! + (sy - cRows) * rowBytes
                            }
                            let row = base.assumingMemoryBound(to: UInt32.self)
                                            let d = dst.baseAddress! + y * outW
                            for x in 0..<outW { d[x] = row[xs[x]] }
                        }
                    }
                }
            }
        }
        let data = out.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: outW, height: outH,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4,
            space: Self.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Render y firmas

    /// Dibuja el fotograma en un bitmap RGBA8 conocido (premultipliedLast, sRGB).
    private func render(_ image: CGImage) -> Bool {
        let w = width, h = frameHeight
        return pixels.withUnsafeMutableBytes { buf -> Bool in
            memset(buf.baseAddress, 0, buf.count)
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: Self.colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
    }

    /// Firma por fila (hash FNV-1a de la luma cuantizada a 6 bits muestreada cada `downsample` píxeles)
    /// y marca de fila «distintiva» (no uniforme).
    private func computeSignatures() {
        let step = configuration.downsample * 4
        let rb = rowBytes
        let h = frameHeight
        pixels.withUnsafeBufferPointer { px in
            newSigs.withUnsafeMutableBufferPointer { sigs in
                newDistinct.withUnsafeMutableBufferPointer { dist in
                    for y in 0..<h {
                        var p = px.baseAddress! + y * rb
                        let end = px.baseAddress! + (y + 1) * rb
                        var hash: UInt64 = 0xcbf29ce484222325
                        var first: UInt8 = 0
                        var uniform = true
                        var isFirst = true
                        while p < end {
                            let luma = (UInt32(p[0]) * 77 + UInt32(p[1]) * 150 + UInt32(p[2]) * 29) >> 8
                            let q = UInt8(truncatingIfNeeded: luma >> 2)
                            hash = (hash ^ UInt64(q)) &* 0x100000001b3
                            if isFirst { first = q; isFirst = false } else if q != first { uniform = false }
                            p += step
                        }
                        sigs[y] = hash
                        dist[y] = !uniform
                    }
                }
            }
        }
    }

    // MARK: - Bandas fijas y desplazamiento

    /// Filas iniciales/finales idénticas entre referencia y fotograma nuevo (≤ 40 % cada una).
    /// Las filas uniformes del borde interior se descartan: coinciden por casualidad al desplazar.
    private func detectBands() -> (top: Int, bottom: Int) {
        let h = frameHeight
        let cap = Int(Double(h) * 0.4)
        var top = 0
        while top < cap, refSigs[top] == newSigs[top] { top += 1 }
        while top > 0, !refDistinct[top - 1] { top -= 1 }
        var bottom = 0
        while bottom < cap, refSigs[h - 1 - bottom] == newSigs[h - 1 - bottom] { bottom += 1 }
        while bottom > 0, !refDistinct[h - bottom] { bottom -= 1 }
        return (top, bottom)
    }

    private func hasDistinctRows(top: Int, bottom: Int) -> Bool {
        for i in top..<(frameHeight - bottom) where newDistinct[i] || refDistinct[i] { return true }
        return false
    }

    /// Mejor `d` tal que la fila `i` del nuevo coincide con la fila `i + d` de la referencia (en la zona de contenido).
    private func bestShift(top: Int, bottom: Int) -> Int? {
        let n = frameHeight - top - bottom
        let minOverlap = max(1, configuration.minOverlapRows)
        guard n >= minOverlap else { return nil }
        let maxD = n - minOverlap
        let ratio = configuration.minMatchRatio
        let minMatches = min(Self.minAbsoluteMatches, minOverlap)

        var bestD: Int?
        var bestMatches = 0
        refSigs.withUnsafeBufferPointer { rs in
            refDistinct.withUnsafeBufferPointer { rd in
                newSigs.withUnsafeBufferPointer { ns in
                    newDistinct.withUnsafeBufferPointer { nd in
                        // Orden 0, +1, -1, +2, ...: con empate gana el menor |d| (y el positivo).
                        for k in 0...(2 * maxD) {
                            let d = k == 0 ? 0 : (k % 2 == 1 ? (k + 1) / 2 : -(k / 2))
                            let lo = max(0, -d), hi = min(n, n - d)
                            var matches = 0, total = 0
                            var i = lo
                            while i < hi {
                                let a = top + i, b = top + i + d
                                if nd[a] || rd[b] {
                                    total += 1
                                    if ns[a] == rs[b] && nd[a] { matches += 1 }
                                }
                                i += 1
                            }
                            guard total > 0, matches >= minMatches, matches > bestMatches,
                                  Double(matches) >= ratio * Double(total) else { continue }
                            bestMatches = matches
                            bestD = d
                        }
                    }
                }
            }
        }
        return bestD
    }
}
