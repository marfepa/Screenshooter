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
}
