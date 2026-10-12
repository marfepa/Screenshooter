import CoreGraphics
import Foundation

/// Cose fotogramas de una captura con scroll vertical en una sola imagen alta.
///
/// Lógica pura (CoreGraphics + Foundation): recibe fotogramas del mismo tamaño y solo
/// añade al lienzo las filas nuevas. Detecta cabeceras y pies «sticky» (filas que no se
/// mueven con el scroll) y nunca cose un hueco: si no hay solape fiable devuelve `.noOverlap`
/// y conserva la referencia anterior.
///
/// Encaje tolerante: no exige filas idénticas (fondos fijos translúcidos, re-rasterizado
/// subpíxel de la inercia). Cada fila se resume en rasgos de borde (gradiente de la luma a baja
/// resolución, con un suelo de ruido que anula los degradados suaves) y el desplazamiento se elige
/// por coste mínimo en dos fases: perfil grueso para todo desplazamiento y refinado con los rasgos
/// completos. Un segundo mínimo no adyacente parecido (filas repetidas) hace el encaje ambiguo.
///
/// Al coser se copian los píxeles reales del fotograma nuevo: sobre un fondo fijo con elementos
/// translúcidos (Mensajes) pueden verse costuras suaves en el fondo.
public final class ScrollStitcher {
    public struct Configuration: Equatable {
        /// Alto máximo de la imagen final en píxeles.
        public var maxHeight: Int = 30_000
        /// Paso horizontal (en píxeles) al muestrear la luma de cada fila.
        public var downsample: Int = 4
        /// Filas de contenido que deben solaparse para aceptar un desplazamiento.
        public var minOverlapRows: Int = 24
        /// Coste normalizado máximo (0 = idéntico, 1 = sin relación) para aceptar un encaje.
        public var acceptCost: Double = 0.50
        /// El segundo mejor mínimo (no adyacente) debe costar al menos esto × el mejor.
        public var ambiguityRatio: Double = 1.5
        /// Filas distintivas mínimas dentro del solape para fiarse de un encaje.
        public var minDistinctRows: Int = 8
        /// Por debajo de este coste con desplazamiento 0 el fotograma se considera sin cambios.
        public var unchangedCost: Double = 0.04
        /// Coste por fila máximo para considerar una fila como parte de una banda fija.
        public var bandRowCost: Double = 0.12

        public init(maxHeight: Int = 30_000, downsample: Int = 4, minOverlapRows: Int = 24,
                    acceptCost: Double = 0.50, ambiguityRatio: Double = 1.5, minDistinctRows: Int = 8,
                    unchangedCost: Double = 0.04, bandRowCost: Double = 0.12) {
            self.maxHeight = maxHeight
            self.downsample = downsample
            self.minOverlapRows = minOverlapRows
            self.acceptCost = acceptCost
            self.ambiguityRatio = ambiguityRatio
            self.minDistinctRows = minDistinctRows
            self.unchangedCost = unchangedCost
            self.bandRowCost = bandRowCost
        }
    }

    public enum Outcome: Equatable {
        case appended(rows: Int)
        case unchanged
        case noOverlap
        case limitReached
    }

    /// Datos del último encaje intentado (depuración y calibración).
    public struct Diagnostics: Equatable {
        public var shift: Int?
        public var cost: Double = 1
        public var secondCost: Double?
        public var secondShift: Int?
    }

    // MARK: - Estado público

    public let width: Int
    /// Alto que tendría `makeImage()` ahora mismo (lienzo + pie).
    public var height: Int { canvasRows + footerRows }
    public private(set) var isAtLimit = false
    public private(set) var fixedTopRows = 0
    public private(set) var fixedBottomRows = 0
    public private(set) var acceptedFrameCount = 1
    public private(set) var lastDiagnostics = Diagnostics()

    // MARK: - Estado interno

    /// Rasgos por fila de un fotograma (buffers reutilizados).
    private final class Features {
        /// Magnitud de gradiente por celda (`cols` × alto).
        var feat: [UInt8]
        /// Suma de `feat` por banda de columnas (`bands` × alto).
        var prof: [Int32]
        /// Energía total por fila.
        var energy: [Int32]
        var distinct: [Bool]
        init(cols: Int, bands: Int, height: Int) {
            feat = [UInt8](repeating: 0, count: cols * height)
            prof = [Int32](repeating: 0, count: bands * height)
            energy = [Int32](repeating: 0, count: height)
            distinct = [Bool](repeating: false, count: height)
        }
    }

    private enum SearchResult {
        case found(Int)
        case noMatch
        case noContent
    }

    private let configuration: Configuration
    private let frameHeight: Int
    private var rowBytes: Int { width * 4 }
    /// Columnas de rasgos (sin la franja derecha de la barra de scroll) y bandas del perfil grueso.
    private let cols: Int
    private let bands: Int
    private let bandEdges: [Int]

    /// Filas RGBA acumuladas (sin el pie).
    private var canvas: [UInt8] = []
    private var canvasRows = 0
    /// Pie fijo guardado aparte; `makeImage()` lo añade al final.
    private var footer: [UInt8] = []
    private var footerRows: Int { footer.count / max(rowBytes, 1) }
    private var bandsFixed = false

    private var ref: Features
    private var new: Features
    private var luma: [UInt8]
    /// Píxeles del fotograma en curso (buffer reutilizado).
    private var pixels: [UInt8]
    /// Fila del lienzo donde empieza la zona de contenido de la referencia.
    private var refTop = 0

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Suelo de ruido del gradiente: lo que queda por debajo (degradados suaves) cuenta 0.
    private static let noiseFloor = 12
    /// Franja derecha ignorada (barra de scroll superpuesta).
    private static let ignoredRightFraction = 0.02
    private static let poolRows = 4
    private static let maxCandidates = 5
    /// Candidatos a menos de esta distancia son la misma familia (deformación no rígida), no ambiguos.
    private static let familyWindow = 32
    private static let seamStripRows = 80
    /// Fracciones del contenido (por abajo de la referencia) que usan las primeras búsquedas, locales a la costura.
    private static let stripFractions = [0.1, 0.3]
    private static let seamWindow = 32
    /// Filas distintivas mínimas para fijar una banda.
    private static let minBandDistinctRows = 6

    // MARK: - Init

    public init?(firstFrame: CGImage, configuration: Configuration = .init()) {
        let w = firstFrame.width, h = firstFrame.height
        guard w > 0, h > 0 else { return nil }
        var config = configuration
        config.downsample = max(1, config.downsample)
        self.configuration = config
        self.width = w
        self.frameHeight = h
        let usable = w - Int((Double(w) * Self.ignoredRightFraction).rounded())
        let c = max(2, min(w, usable / config.downsample))
        self.cols = c
        let b = min(16, c)
        self.bands = b
        self.bandEdges = (0...b).map { $0 * c / b }
        self.pixels = [UInt8](repeating: 0, count: w * h * 4)
        self.luma = [UInt8](repeating: 0, count: c * h)
        self.ref = Features(cols: c, bands: b, height: h)
        self.new = Features(cols: c, bands: b, height: h)
        guard render(firstFrame) else { return nil }
        computeFeatures(into: ref)
        canvas = pixels
        canvasRows = h
        isAtLimit = height >= config.maxHeight
    }

    // MARK: - Añadir fotogramas

    @discardableResult
    public func add(_ frame: CGImage) -> Outcome {
        if isAtLimit { return .limitReached }
        guard frame.width == width, frame.height == frameHeight, render(frame) else { return .noOverlap }
        computeFeatures(into: new)
        lastDiagnostics = Diagnostics()

        var top = fixedTopRows, bottom = fixedBottomRows
        let n0 = frameHeight - top - bottom

        // Sin contenido distintivo en ninguno de los dos: no hay información, no es un salto.
        if !hasDistinctRows(top: top, bottom: bottom) { return .unchanged }
        // Sin movimiento (coste bajo con desplazamiento 0).
        let zero = cost(shift: 0, top: top, count: n0, rowStep: 2, colStep: 2)
        if zero.rows > 0, zero.cost < configuration.unchangedCost {
            lastDiagnostics = Diagnostics(shift: 0, cost: zero.cost, secondCost: nil)
            return .unchanged
        }

        var d = 0
        if bandsFixed {
            guard let found = locate(top: top, bottom: bottom) else { return .noOverlap }
            d = found
        } else {
            // Primer movimiento: las bandas solo se fijan si el encaje es válido y d ≠ 0.
            var attempt = detectBands()
            var result = locate(top: attempt.top, bottom: attempt.bottom)
            if result == nil, attempt.top > 0 || attempt.bottom > 0 {
                attempt = (0, 0)
                result = locate(top: 0, bottom: 0)
            }
            guard let found = result else { return .noOverlap }
            if found == 0 { return .unchanged }
            d = found
            (top, bottom) = attempt
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
        swap(&ref, &new)
        // Posición real (puede ser negativa al subir por encima del inicio): solo se usa en aritmética
        // de `newTop`, nunca como índice al lienzo, y así al volver a bajar no se repiten filas.
        refTop = newTop

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


    // MARK: - Rasgos

    /// Luma a 1/`downsample` del ancho y, sobre ella, magnitud del gradiente horizontal y vertical
    /// (menos el suelo de ruido). Resume cada fila en un perfil de bandas y una energía.
    private func computeFeatures(into f: Features) {
        let edges = bandEdges
        pixels.withUnsafeBufferPointer { px in
            luma.withUnsafeMutableBufferPointer { lm in
                f.feat.withUnsafeMutableBufferPointer { ft in
                    f.prof.withUnsafeMutableBufferPointer { pf in
                        f.energy.withUnsafeMutableBufferPointer { en in
                            f.distinct.withUnsafeMutableBufferPointer { di in
                                edges.withUnsafeBufferPointer { ed in
                                    Self.featuresKernel(
                                        px: px.baseAddress!, luma: lm.baseAddress!, feat: ft.baseAddress!,
                                        prof: pf.baseAddress!, energy: en.baseAddress!, distinct: di.baseAddress!,
                                        edges: ed.baseAddress!, height: frameHeight, cols: cols, bands: bands,
                                        rowBytes: rowBytes, step: configuration.downsample * 4, floor: Self.noiseFloor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Núcleos numéricos: funciones estáticas sobre punteros crudos y bucles `while` (sin iteradores de rango)
    // para que Debug no sea órdenes de magnitud más lento que Release.
    private static func featuresKernel(
        px: UnsafePointer<UInt8>, luma lp: UnsafeMutablePointer<UInt8>, feat ft: UnsafeMutablePointer<UInt8>,
        prof pf: UnsafeMutablePointer<Int32>, energy en: UnsafeMutablePointer<Int32>,
        distinct di: UnsafeMutablePointer<Bool>, edges: UnsafePointer<Int>,
        height h: Int, cols: Int, bands: Int, rowBytes rb: Int, step: Int, floor: Int
    ) {
        let distinctEnergy = Int32(cols) // media ≥ 1 por celda
        // Bucles `while`: `for … in rango` es ~25× más lento en Debug.
        var y = 0
        while y < h {
            let row = px + y * rb
            let out = lp + y * cols
            var c = 0
            while c < cols {
                let p = row + c * step
                out[c] = UInt8(truncatingIfNeeded: (Int(p[0]) &* 77 &+ Int(p[1]) &* 150 &+ Int(p[2]) &* 29) >> 8)
                c &+= 1
            }
            y &+= 1
        }
        y = 0
        while y < h {
            let l = lp + y * cols
            let ln = y + 1 < h ? lp + (y + 1) * cols : l
            let fr = ft + y * cols
            let pr = pf + y * bands
            var total: Int32 = 0
            var b = 0
            while b < bands {
                var s = 0
                var c = edges[b]
                let cEnd = edges[b + 1]
                while c < cEnd {
                    let cur = Int(l[c])
                    var dx = c + 1 < cols ? Int(l[c + 1]) &- cur : 0
                    if dx < 0 { dx = 0 &- dx }
                    var dy = Int(ln[c]) &- cur
                    if dy < 0 { dy = 0 &- dy }
                    var g = dx &+ dy &- floor
                    if g < 0 { g = 0 } else if g > 255 { g = 255 }
                    fr[c] = UInt8(truncatingIfNeeded: g)
                    s &+= g
                    c &+= 1
                }
                pr[b] = Int32(truncatingIfNeeded: s)
                total &+= Int32(truncatingIfNeeded: s)
                b &+= 1
            }
            en[y] = total
            di[y] = total >= distinctEnergy
            y &+= 1
        }
    }

    // MARK: - Coste

    /// Coste normalizado (Σ|a−b| / Σ(a+b), 0 = idéntico) de los rasgos completos entre la fila `i` del
    /// nuevo y la `i + shift` de la referencia, solo en filas distintivas de cualquiera de las dos.
    private func cost(shift d: Int, top: Int, count n: Int, rowStep: Int, colStep: Int, strip: Int? = nil) -> (cost: Double, rows: Int) {
        let range = overlap(shift: d, count: n, strip: strip)
        let lo = range.lowerBound, hi = range.upperBound
        guard hi > lo else { return (1, 0) }
        let cols = cols
        var sad = 0, sum = 0, rows = 0
        ref.feat.withUnsafeBufferPointer { rf in
            new.feat.withUnsafeBufferPointer { nf in
                ref.distinct.withUnsafeBufferPointer { rd in
                    new.distinct.withUnsafeBufferPointer { nd in
                        (sad, sum, rows) = Self.costKernel(
                            nf: nf.baseAddress!, rf: rf.baseAddress!, nd: nd.baseAddress!, rd: rd.baseAddress!,
                            lo: lo, hi: hi, shift: d, top: top, cols: cols, frameHeight: frameHeight,
                            rowStep: rowStep, colStep: colStep)
                    }
                }
            }
        }
        return (sum > 0 ? Double(sad) / Double(sum) : 1, rows)
    }

    private static func costKernel(
        nf: UnsafePointer<UInt8>, rf: UnsafePointer<UInt8>, nd: UnsafePointer<Bool>, rd: UnsafePointer<Bool>,
        lo: Int, hi: Int, shift d: Int, top: Int, cols: Int, frameHeight: Int, rowStep: Int, colStep: Int
    ) -> (Int, Int, Int) {
        var sad = 0, sum = 0, rows = 0
        var i = lo
        while i < hi {
            let a = top + i, b = top + i + d
            if nd[a] || rd[b] {
                let pa = nf + a * cols
                let pb = rf + b * cols
                let pu = b > 0 ? pb - cols : pb
                let pd = b + 1 < frameHeight ? pb + cols : pb
                var c = 0
                while c < cols {
                    let x = Int(pa[c]), y = Int(pb[c])
                    var diff = x > y ? x &- y : y &- x
                    let u = Int(pu[c]), v = Int(pd[c])
                    let du = x > u ? x &- u : u &- x
                    let dv = x > v ? x &- v : v &- x
                    if du < diff { diff = du }
                    if dv < diff { diff = dv }
                    sad &+= diff
                    sum &+= x &+ y
                    c &+= colStep
                }
                rows &+= 1
            }
            i &+= rowStep
        }
        return (sad, sum, rows)
    }

    // MARK: - Bandas fijas

    /// Filas iniciales/finales con coste por fila bajo entre referencia y fotograma nuevo (≤ 40 % cada una).
    /// Las filas uniformes (sin bordes) son neutras: no cortan la banda, pero las del borde interior se
    /// descartan, y la banda debe contener filas distintivas (un fondo liso fijo no es una banda).
    private func detectBands() -> (top: Int, bottom: Int) {
        let h = frameHeight
        let cap = Int(Double(h) * 0.4)
        // 1 = coincide, 0 = neutra, -1 = difiere
        func state(_ y: Int) -> Int {
            let r = ref.distinct[y], n = new.distinct[y]
            if !r && !n { return 0 }
            let (c, _) = rowCost(y)
            return c <= configuration.bandRowCost ? 1 : -1
        }
        var top = 0
        while top < cap, state(top) >= 0 { top += 1 }
        // El gradiente vertical de la última fila de la banda depende de la primera de contenido: difiere
        // aunque la fila sea idéntica. La fila donde se cortó la racha pertenece a la banda.
        if top > 0, top < cap { top += 1 }
        while top > 0, !ref.distinct[top - 1] { top -= 1 }
        if distinctCount(rows: 0..<top) < Self.minBandDistinctRows { top = 0 }
        var bottom = 0
        while bottom < cap, state(h - 1 - bottom) >= 0 { bottom += 1 }
        while bottom > 0, !ref.distinct[h - bottom] { bottom -= 1 }
        if distinctCount(rows: (h - bottom)..<h) < Self.minBandDistinctRows { bottom = 0 }
        return (top, bottom)
    }

    private func distinctCount(rows: Range<Int>) -> Int {
        var n = 0
        for y in rows where ref.distinct[y] { n += 1 }
        return n
    }

    private func rowCost(_ y: Int) -> (Double, Int) {
        let cols = cols
        var sad = 0, sum = 0
        ref.feat.withUnsafeBufferPointer { rf in
            new.feat.withUnsafeBufferPointer { nf in
                let pa = nf.baseAddress! + y * cols, pb = rf.baseAddress! + y * cols
                for c in 0..<cols {
                    let x = Int(pa[c]), v = Int(pb[c])
                    sad &+= x > v ? x &- v : v &- x
                    sum &+= x &+ v
                }
            }
        }
        return (sum > 0 ? Double(sad) / Double(sum) : 1, sum)
    }

    /// Filas del nuevo (relativas al contenido) que se solapan con la referencia para el desplazamiento `d`.
    /// Con `strip`, solo cuentan las `strip` últimas filas de la referencia (la costura del lienzo).
    private func overlap(shift d: Int, count n: Int, strip: Int?) -> Range<Int> {
        var lo = max(0, -d)
        let hi = min(n, n - d)
        if let strip { lo = max(lo, n - strip - d) }
        return lo < hi ? lo..<hi : 0..<0
    }

    private func hasDistinctRows(top: Int, bottom: Int) -> Bool {
        for i in top..<(frameHeight - bottom) where new.distinct[i] || ref.distinct[i] { return true }
        return false
    }

    // MARK: - Desplazamiento

    /// Primero busca solo contra la costura (las últimas filas de la referencia: aguanta deformaciones
    /// no rígidas del resto de la página); si no basta (franja sin bordes, scroll hacia arriba), usa todo
    /// el solape y re-estima el desplazamiento en la costura.
    private func locate(top: Int, bottom: Int) -> Int? {
        let n = frameHeight - top - bottom
        for fraction in Self.stripFractions {
            let strip = max(configuration.minOverlapRows * 2, Int(Double(n) * fraction))
            if strip < n, case .found(let d) = search(top: top, bottom: bottom, strip: strip) {
                return refineAtSeam(shift: d, top: top, count: n) ?? d
            }
        }
        guard case .found(let d) = search(top: top, bottom: bottom) else { return nil }
        return refineAtSeam(shift: d, top: top, count: n)
    }

    /// Mejor `d` tal que la fila `i` del nuevo coincide con la fila `i + d` de la referencia (en la zona de
    /// contenido), por perfil grueso (todo `d`, filas agrupadas) y refinado con los rasgos completos.
    private func search(top: Int, bottom: Int, strip: Int? = nil) -> SearchResult {
        let n = frameHeight - top - bottom
        let minOverlap = max(1, configuration.minOverlapRows)
        guard n >= minOverlap else { return .noMatch }
        guard hasDistinctRows(top: top, bottom: bottom) else { return .noContent }
        let maxD = n - minOverlap
        let bands = bands
        let P = Self.poolRows
        let R = n / P
        let kMax = min(maxD / P, R - (minOverlap + P - 1) / P)
        guard R >= 2, kMax >= 0 else { return .noMatch }

        // Perfil agrupado de P filas.
        var pn = [Int32](repeating: 0, count: R * bands), pr = pn
        var sn = [Int](repeating: 0, count: R + 1), sr = sn
        for r in 0..<R {
            for j in 0..<P {
                let y = top + r * P + j
                for b in 0..<bands {
                    pn[r * bands + b] &+= new.prof[y * bands + b]
                    pr[r * bands + b] &+= ref.prof[y * bands + b]
                }
                sn[r + 1] += Int(new.energy[y]); sr[r + 1] += Int(ref.energy[y])
            }
        }
        for r in 0..<R { sn[r + 1] += sn[r]; sr[r + 1] += sr[r] }

        // Coste grueso para cada k = d/P.
        var coarse = [Double](repeating: 2, count: 2 * kMax + 1)
        pn.withUnsafeBufferPointer { a in
            pr.withUnsafeBufferPointer { r in
                for k in -kMax...kMax {
                    var lo = max(0, -k)
                    let hi = min(R, R - k)
                    if let strip { lo = max(lo, (n - strip) / P - k) }
                    guard hi > lo else { continue }
                    let sad = Self.sadKernel(a: a.baseAddress!, r: r.baseAddress!, bands: bands, lo: lo, hi: hi, k: k)
                    let den = (sn[hi] - sn[lo]) + (sr[hi + k] - sr[lo + k])
                    coarse[k + kMax] = den > 0 ? Double(sad) / Double(den) : 1
                }
            }
        }

        // Mínimos locales → candidatos.
        var minima: [(k: Int, c: Double)] = []
        for i in 0..<coarse.count where coarse[i] < 1.0 {
            let left = i > 0 ? coarse[i - 1] : 3, right = i + 1 < coarse.count ? coarse[i + 1] : 3
            if coarse[i] <= left, coarse[i] <= right { minima.append((i - kMax, coarse[i])) }
        }
        minima.sort { $0.c < $1.c }
        if minima.count > Self.maxCandidates { minima.removeLast(minima.count - Self.maxCandidates) }
        guard !minima.isEmpty else { return .noMatch }

        // Refinado: d exacto por perfil fila a fila y coste con rasgos completos.
        var results: [(d: Int, cost: Double, rows: Int)] = []
        for m in minima {
            var bestD = m.k * P, bestC = Double.infinity
            for d in (m.k * P - P - 1)...(m.k * P + P + 1) where abs(d) <= maxD {
                let c = profileCost(shift: d, top: top, rows: overlap(shift: d, count: n, strip: strip))
                if c < bestC { bestC = c; bestD = d }
            }
            guard bestC.isFinite else { continue }
            let full = cost(shift: bestD, top: top, count: n, rowStep: 2, colStep: 2, strip: strip)
            if let idx = results.firstIndex(where: { abs($0.d - bestD) <= Self.familyWindow }) {
                if full.cost < results[idx].cost { results[idx] = (bestD, full.cost, full.rows) }
            } else {
                results.append((bestD, full.cost, full.rows))
            }
        }
        results.sort { $0.cost < $1.cost }
        guard let best = results.first else { return .noMatch }
        // Un mínimo en d ≈ 0 lejos del mejor es el fondo fijo (fondo de pantalla con textura), no un rival.
        let second = results.dropFirst().first { abs(best.d) <= Self.familyWindow || abs($0.d) > 3 }
        lastDiagnostics = Diagnostics(shift: best.d, cost: best.cost, secondCost: second?.cost, secondShift: second?.d)

        let overlapRows = overlap(shift: best.d, count: n, strip: strip).count
        guard best.cost < configuration.acceptCost,
              overlapRows >= minOverlap,
              best.rows >= min(configuration.minDistinctRows, max(1, minOverlap / 2)) else { return .noMatch }
        // Suelo 0,02: con un mejor coste ≈ 0 (página periódica exacta) otro mínimo igual de bueno sigue siendo ambiguo.
        if let second, second.cost < configuration.ambiguityRatio * max(best.cost, 0.02) { return .noMatch }
        return .found(best.d)
    }

    /// Coste con el perfil por bandas a resolución de fila (refinado barato de un candidato grueso).
    private func profileCost(shift d: Int, top: Int, count n: Int) -> Double {
        profileCost(shift: d, top: top, rows: max(0, -d)..<min(n, n - d))
    }

    private func profileCost(shift d: Int, top: Int, rows: Range<Int>) -> Double {
        guard !rows.isEmpty else { return .infinity }
        var sad = 0, sum = 0
        ref.prof.withUnsafeBufferPointer { rp in
            new.prof.withUnsafeBufferPointer { np in
                ref.energy.withUnsafeBufferPointer { re in
                    new.energy.withUnsafeBufferPointer { ne in
                        (sad, sum) = Self.profileKernel(
                            np: np.baseAddress!, rp: rp.baseAddress!, ne: ne.baseAddress!, re: re.baseAddress!,
                            bands: bands, top: top, shift: d, lo: rows.lowerBound, hi: rows.upperBound)
                    }
                }
            }
        }
        return sum > 0 ? Double(sad) / Double(sum) : 1
    }

    private static func sadKernel(a: UnsafePointer<Int32>, r: UnsafePointer<Int32>, bands: Int, lo: Int, hi: Int, k: Int) -> Int {
        var sad = 0
        var row = lo
        while row < hi {
            let pa = a + row * bands, pb = r + (row + k) * bands
            var b = 0
            while b < bands {
                let x = Int(pa[b]), y = Int(pb[b])
                sad &+= x > y ? x &- y : y &- x
                b &+= 1
            }
            row &+= 1
        }
        return sad
    }

    private static func profileKernel(
        np: UnsafePointer<Int32>, rp: UnsafePointer<Int32>, ne: UnsafePointer<Int32>, re: UnsafePointer<Int32>,
        bands: Int, top: Int, shift d: Int, lo: Int, hi: Int
    ) -> (Int, Int) {
        var sad = 0, sum = 0
        var i = lo
        while i < hi {
            let a = top + i, b = top + i + d
            let pa = np + a * bands, pb = rp + b * bands
            var k = 0
            while k < bands {
                let x = Int(pa[k]), y = Int(pb[k])
                sad &+= x > y ? x &- y : y &- x
                k &+= 1
            }
            sum &+= Int(ne[a]) &+ Int(re[b])
            i &+= 1
        }
        return (sad, sum)
    }

    /// Algunas apps (Mensajes con scroll rápido) desplazan cada burbuja una cantidad algo distinta: el
    /// encaje global es aproximado. La costura solo necesita ser coherente donde se une el lienzo, así que
    /// el desplazamiento final se re-estima en la franja que rodea la costura (±`seamWindow`).
    /// Devuelve nil si la franja no encaja (costura incoherente).
    private func refineAtSeam(shift d: Int, top: Int, count n: Int) -> Int? {
        guard d > 0 else { return d }
        let seam = n - d
        let first = max(0, seam - Self.seamStripRows)
        guard seam - first >= configuration.minOverlapRows else { return d }
        var bestE = d, bestC = Double.infinity
        for e in max(1, d - Self.seamWindow)...min(n - configuration.minOverlapRows, d + Self.seamWindow) {
            let hi = min(seam, n - e)
            guard hi - first >= configuration.minOverlapRows else { continue }
            let c = profileCost(shift: e, top: top, rows: first..<hi)
            // Empate: gana el más cercano al global.
            if c < bestC - 1e-9 || (abs(c - bestC) <= 1e-9 && abs(e - d) < abs(bestE - d)) { bestC = c; bestE = e }
        }
        // Franja sin bordes (todo fondo liso): sin información local, se conserva el global.
        if bestC >= 1 { return d }
        return bestC < configuration.acceptCost ? bestE : nil
    }
}
