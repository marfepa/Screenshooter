import CoreGraphics
import XCTest
@testable import Screenshooter

final class ScrollStitcherTests: XCTestCase {
    private let w = 300
    private let fh = 400

    // MARK: - Utilidades

    /// Generador determinista (xorshift64).
    private struct RNG {
        var s: UInt64
        mutating func next() -> UInt8 {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return UInt8(truncatingIfNeeded: s >> 24)
        }
    }

    /// Página RGBA con filas pseudoaleatorias y franjas blancas uniformes.
    private func makePage(rows: Int, seed: UInt64 = 42, white: [Range<Int>] = []) -> [UInt8] {
        var rng = RNG(s: seed)
        var out = [UInt8](repeating: 255, count: rows * w * 4)
        for y in 0..<rows where !white.contains(where: { $0.contains(y) }) {
            for x in 0..<w {
                let o = (y * w + x) * 4
                out[o] = rng.next(); out[o + 1] = rng.next(); out[o + 2] = rng.next()
            }
        }
        return out
    }

    private func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rows(_ bytes: [UInt8], _ r: Range<Int>) -> [UInt8] {
        Array(bytes[(r.lowerBound * w * 4)..<(r.upperBound * w * 4)])
    }

    /// Fotograma = cabecera + página[off+top ..< off+fh-bottom] + pie.
    private func frame(_ page: [UInt8], at off: Int, header: [UInt8] = [], footer: [UInt8] = []) -> CGImage {
        let t = header.count / (w * 4), b = footer.count / (w * 4)
        return image(header + rows(page, (off + t)..<(off + fh - b)) + footer, width: w, height: fh)
    }

    private func pixels(of img: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height,
                                bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setBlendMode(.copy)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return out
    }

    private func assertResult(_ s: ScrollStitcher, equals expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        guard let img = s.makeImage() else { return XCTFail("makeImage nil", file: file, line: line) }
        XCTAssertEqual(img.height, expected.count / (w * 4), file: file, line: line)
        XCTAssertTrue(pixels(of: img) == expected, "La imagen cosida difiere de lo esperado", file: file, line: line)
    }

    // MARK: - Casos

    func testKnownShifts() throws {
        let page = makePage(rows: 3000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        XCTAssertEqual(s.add(frame(page, at: 120)), .appended(rows: 120))
        XCTAssertEqual(s.add(frame(page, at: 260)), .appended(rows: 140))
        XCTAssertEqual(s.add(frame(page, at: 400)), .appended(rows: 140))
        XCTAssertEqual(s.acceptedFrameCount, 4)
        XCTAssertEqual(s.fixedTopRows, 0)
        assertResult(s, equals: rows(page, 0..<800))
    }

    func testFixedHeader() throws {
        let page = makePage(rows: 3000)
        let header = makePage(rows: 40, seed: 7)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0, header: header)))
        XCTAssertEqual(s.add(frame(page, at: 100, header: header)), .appended(rows: 100))
        XCTAssertEqual(s.add(frame(page, at: 250, header: header)), .appended(rows: 150))
        XCTAssertEqual(s.fixedTopRows, 40)
        XCTAssertEqual(s.fixedBottomRows, 0)
        assertResult(s, equals: header + rows(page, 40..<650))
    }

    func testFixedHeaderAndFooter() throws {
        let page = makePage(rows: 3000)
        let header = makePage(rows: 40, seed: 7)
        let footer = makePage(rows: 30, seed: 9)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0, header: header, footer: footer)))
        XCTAssertEqual(s.add(frame(page, at: 100, header: header, footer: footer)), .appended(rows: 100))
        XCTAssertEqual(s.add(frame(page, at: 250, header: header, footer: footer)), .appended(rows: 150))
        XCTAssertEqual(s.fixedTopRows, 40)
        XCTAssertEqual(s.fixedBottomRows, 30)
        assertResult(s, equals: header + rows(page, 40..<(650 - 30)) + footer)
    }

    func testNoOverlapThenRecovers() throws {
        let page = makePage(rows: 3000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        XCTAssertEqual(s.add(frame(page, at: 120)), .appended(rows: 120))
        let h = s.height
        XCTAssertEqual(s.add(frame(page, at: 1500)), .noOverlap)
        XCTAssertEqual(s.height, h)
        XCTAssertEqual(s.add(frame(page, at: 260)), .appended(rows: 140))
        assertResult(s, equals: rows(page, 0..<660))
    }

    func testScrollUpThenDown() throws {
        let page = makePage(rows: 3000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        XCTAssertEqual(s.add(frame(page, at: 200)), .appended(rows: 200))
        XCTAssertEqual(s.add(frame(page, at: 100)), .unchanged)
        XCTAssertEqual(s.height, 600)
        XCTAssertEqual(s.add(frame(page, at: 300)), .appended(rows: 100))
        assertResult(s, equals: rows(page, 0..<700))
    }

    func testScrollUpAboveStartThenDownDoesNotRepeatRows() throws {
        let page = makePage(rows: 3000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 1000)))
        XCTAssertEqual(s.add(frame(page, at: 850)), .unchanged)
        XCTAssertEqual(s.height, fh)
        XCTAssertEqual(s.add(frame(page, at: 1150)), .appended(rows: 150))
        XCTAssertEqual(s.add(frame(page, at: 1300)), .appended(rows: 150))
        assertResult(s, equals: rows(page, 1000..<1700))
    }

    func testIdenticalFrame() throws {
        let page = makePage(rows: 1000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        XCTAssertEqual(s.add(frame(page, at: 0)), .unchanged)
        XCTAssertEqual(s.height, fh)
        XCTAssertEqual(s.acceptedFrameCount, 1)
    }

    func testMaxHeightLimit() throws {
        let page = makePage(rows: 3000)
        var cfg = ScrollStitcher.Configuration()
        cfg.maxHeight = 600
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0), configuration: cfg))
        XCTAssertEqual(s.add(frame(page, at: 120)), .appended(rows: 120))
        XCTAssertFalse(s.isAtLimit)
        XCTAssertEqual(s.add(frame(page, at: 240)), .limitReached)
        XCTAssertEqual(s.height, 600)
        XCTAssertTrue(s.isAtLimit)
        XCTAssertEqual(s.add(frame(page, at: 360)), .limitReached)
        assertResult(s, equals: rows(page, 0..<600))
    }

    func testSingleFrame() throws {
        let page = makePage(rows: 1000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        assertResult(s, equals: rows(page, 0..<fh))
    }

    func testDifferentSizeIsNoOverlap() throws {
        let page = makePage(rows: 1000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        let other = image(rows(page, 0..<300), width: w, height: 300)
        XCTAssertEqual(s.add(other), .noOverlap)
        XCTAssertEqual(s.height, fh)
    }

    func testUniformZonesDoNotCauseFalseShifts() throws {
        let page = makePage(rows: 3000, white: [150..<350, 600..<850, 1100..<1300, 1500..<1750])
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        var off = 0
        while off < 1600 {
            off += 100
            XCTAssertEqual(s.add(frame(page, at: off)), .appended(rows: 100), "offset \(off)")
        }
        assertResult(s, equals: rows(page, 0..<(off + fh)))
    }

    func testPerformance() throws {
        let big = 2400, hh = 1000
        var rng = RNG(s: 5)
        let a = (0..<(big * (hh + 100) * 4)).map { _ in rng.next() }
        func f(_ off: Int) -> CGImage {
            image(Array(a[(off * big * 4)..<((off + hh) * big * 4)]), width: big, height: hh)
        }
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: f(0)))
        let next = f(60)
        measure { _ = s.add(next) }
    }

    // MARK: - Encaje tolerante (fondo fijo, subpíxel, barra de scroll, filas repetidas)

    /// Capa de contenido de una página de «chat»: burbujas translúcidas (alfa 0,7) con texto opaco.
    /// RGBA en Float; `a` es la opacidad de la capa.
    private func makeBubbleLayer(rows: Int, seed: UInt64 = 11) -> [Float] {
        var rng = RNG(s: seed)
        var layer = [Float](repeating: 0, count: rows * w * 4)
        func put(_ x: Int, _ y: Int, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            guard x >= 0, x < w, y >= 0, y < rows else { return }
            let o = (y * w + x) * 4
            layer[o] = r; layer[o + 1] = g; layer[o + 2] = b; layer[o + 3] = a
        }
        var y = 10
        while y < rows - 80 {
            let h = 36 + Int(rng.next()) % 24
            let x0 = 10 + Int(rng.next()) % 120
            let bw = 90 + Int(rng.next()) % 160
            let blue = rng.next() % 2 == 0
            for yy in y..<(y + h) {
                for x in x0..<(x0 + bw) { blue ? put(x, yy, 20, 130, 255, 0.7) : put(x, yy, 110, 110, 120, 0.7) }
            }
            var ly = y + 8
            while ly + 10 < y + h {
                var x = x0 + 8
                while x + 3 < x0 + bw - 8 {
                    if rng.next() % 2 == 1 {
                        for yy in ly..<(ly + 9) { for dx in 0..<3 { put(x + dx, yy, 255, 255, 255, 1) } }
                    }
                    x += 3
                }
                ly += 16
            }
            y += h + 10 + Int(rng.next()) % 40
        }
        return layer
    }

    /// Fotograma de la página de burbujas en un desplazamiento (posiblemente fraccionario, interpolación
    /// lineal entre filas) sobre un fondo de degradado suave FIJO en coordenadas de pantalla.
    private func bubbleFrame(_ layer: [Float], rows: Int, offset: Double) -> CGImage {
        var out = [UInt8](repeating: 255, count: fh * w * 4)
        for r in 0..<fh {
            let pos = offset + Double(r)
            let i0 = min(rows - 1, Int(pos.rounded(.down)))
            let i1 = min(rows - 1, i0 + 1)
            let f = Float(pos - Double(i0))
            for x in 0..<w {
                let bg: [Float] = [90 + 0.15 * Float(x) + 0.05 * Float(r), 140 + 0.1 * Float(x), 190 - 0.1 * Float(x)]
                let a0 = (i0 * w + x) * 4, a1 = (i1 * w + x) * 4
                let a = layer[a0 + 3] * (1 - f) + layer[a1 + 3] * f
                let o = (r * w + x) * 4
                for c in 0..<3 {
                    let col = layer[a0 + c] * layer[a0 + 3] * (1 - f) + layer[a1 + c] * layer[a1 + 3] * f
                    out[o + c] = UInt8(max(0, min(255, bg[c] * (1 - a) + col)))
                }
            }
        }
        return image(out, width: w, height: fh)
    }

    func testFixedSoftBackgroundWithTranslucentBubbles() throws {
        let rows = 3000
        let layer = makeBubbleLayer(rows: rows)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: bubbleFrame(layer, rows: rows, offset: 0)))
        var off = 0
        while off < 1440 {
            off += 90
            XCTAssertEqual(s.add(bubbleFrame(layer, rows: rows, offset: Double(off))), .appended(rows: 90), "offset \(off)")
        }
        XCTAssertEqual(s.height, fh + 1440)
        XCTAssertEqual(s.fixedTopRows, 0)
        XCTAssertEqual(s.fixedBottomRows, 0)
    }

    func testSubpixelScrollStepsAreAccepted() throws {
        let rows = 3000
        let layer = makeBubbleLayer(rows: rows, seed: 23)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: bubbleFrame(layer, rows: rows, offset: 0)))
        let steps = 30
        for k in 1...steps {
            let outcome = s.add(bubbleFrame(layer, rows: rows, offset: 2.5 * Double(k)))
            XCTAssertNotEqual(outcome, .noOverlap, "paso \(k)")
        }
        XCTAssertEqual(Double(s.height), Double(fh) + 2.5 * Double(steps), accuracy: 2)
    }

    func testMovingScrollbarOnRightEdgeIsIgnored() throws {
        let page = makePage(rows: 3000)
        func withBar(_ off: Int, _ k: Int) -> CGImage {
            var bytes = rows(page, off..<(off + fh))
            let y0 = 20 + 3 * k
            for y in y0..<(y0 + 80) { for x in (w - 5)..<w {
                let o = (y * w + x) * 4
                bytes[o] = 200; bytes[o + 1] = 200; bytes[o + 2] = 200
            } }
            return image(bytes, width: w, height: fh)
        }
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: withBar(0, 0)))
        for k in 1...5 {
            XCTAssertEqual(s.add(withBar(100 * k, k)), .appended(rows: 100), "k \(k)")
        }
        XCTAssertEqual(s.height, fh + 500)
    }

    /// Lista de elementos de 24 filas con el mismo «nombre» (texto idéntico) y, si `distinctDates`, una
    /// «fecha» distinta por elemento a la derecha.
    private func makeRepeatedList(rows: Int, distinctDates: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: rows * w * 4)
        var nameRng = RNG(s: 99)
        let name = (0..<60).map { _ in nameRng.next() % 2 == 0 }
        for item in 0..<(rows / 24) {
            var dateRng = RNG(s: UInt64(1000 + item * 7919))
            for ry in 6..<15 {
                let y = item * 24 + ry
                for seg in 0..<60 where name[seg] {
                    for dx in 0..<3 { let o = (y * w + 10 + seg * 3 + dx) * 4; out[o] = 20; out[o + 1] = 20; out[o + 2] = 20 }
                }
                guard distinctDates else { continue }
                var dr = dateRng
                for seg in 0..<30 where dr.next() % 2 == 0 {
                    for dx in 0..<3 { let o = (y * w + 205 + seg * 3 + dx) * 4; out[o] = 20; out[o + 1] = 20; out[o + 2] = 20 }
                }
            }
            _ = dateRng.next()
        }
        return out
    }

    func testPerfectlyRepeatedRowsNeverProduceFalseShifts() throws {
        let page = makeRepeatedList(rows: 3000, distinctDates: false)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        for off in [7, 14, 31, 55, 100] {
            let outcome = s.add(frame(page, at: off))
            if case .appended = outcome { XCTFail("desplazamiento falso en \(off): \(outcome)") }
        }
        XCTAssertEqual(s.height, fh)
    }

    func testRepeatedNamesWithDistinctDatesStitchExactly() throws {
        let page = makeRepeatedList(rows: 3000, distinctDates: true)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        for k in 1...20 {
            XCTAssertEqual(s.add(frame(page, at: 9 * k)), .appended(rows: 9), "k \(k)")
        }
        assertResult(s, equals: rows(page, 0..<(fh + 180)))
    }

    // MARK: - Vista previa

    func testMakePreviewSizeAndSampledPixel() throws {
        let page = makePage(rows: 3000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        XCTAssertEqual(s.add(frame(page, at: 120)), .appended(rows: 120))
        let prev = try XCTUnwrap(s.makePreview(maxWidth: 100))
        XCTAssertEqual(prev.width, 100)
        XCTAssertEqual(prev.height, 173) // 520 * 100 / 300
        let src = pixels(of: try XCTUnwrap(s.makeImage()))
        let out = pixels(of: prev)
        let (px, py) = (40, 77)
        let sx = px * 300 / 100, sy = py * 520 / prev.height
        let so = (sy * 300 + sx) * 4, po = (py * 100 + px) * 4
        XCTAssertEqual(Array(out[po..<(po + 4)]), Array(src[so..<(so + 4)]))
    }

    func testMakePreviewNeverUpscalesAndKeepsMinimumHeight() throws {
        let page = makePage(rows: 400)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0)))
        let prev = try XCTUnwrap(s.makePreview(maxWidth: 1000))
        XCTAssertEqual(prev.width, 300)
        XCTAssertEqual(prev.height, 400)
        XCTAssertEqual(try XCTUnwrap(s.makePreview(maxWidth: 1)).height, 1)
    }

    func testMakePreviewIsFastWithTallCanvas() throws {
        let cfg = ScrollStitcher.Configuration(maxHeight: 30_000)
        let page = makePage(rows: 30_000)
        let s = try XCTUnwrap(ScrollStitcher(firstFrame: frame(page, at: 0), configuration: cfg))
        var off = 0
        while off < 29_000, !s.isAtLimit {
            off += 300
            if case .noOverlap = s.add(frame(page, at: min(off, 29_600))) { break }
        }
        XCTAssertGreaterThan(s.height, 20_000)
        let t0 = Date()
        // 80 px de ancho sobre 300 ≈ los píxeles de salida de 220 sobre un lienzo real de 2400 (compilación Debug).
        _ = s.makePreview(maxWidth: 80)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.25)
    }
}
