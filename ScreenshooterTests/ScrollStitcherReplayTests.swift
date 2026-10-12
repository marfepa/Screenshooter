import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Screenshooter

/// Reproduce sesiones reales del volcado de depuración de la captura larga
/// (`~/Library/Caches/com.marfepa.Screenshooter/ScrollCaptureDebug/<sesión>/frame-NNNN.png`).
/// Son datos locales del usuario (no van al repo): sin la carpeta, la prueba se omite.
/// Ruta alternativa con la variable de entorno `SCROLL_REPLAY_DIR`.
final class ScrollStitcherReplayTests: XCTestCase {
    private func replayRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["SCROLL_REPLAY_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.marfepa.Screenshooter/ScrollCaptureDebug")
    }

    private func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func testReplayRealSessions() throws {
        let root = replayRoot()
        let sessions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("frame-0001.png").path) }
        try XCTSkipIf(sessions.isEmpty, "Sin sesiones de depuración en \(root.path)")

        for dir in sessions {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }.sorted()
            guard names.count > 1, let first = load(dir.appendingPathComponent(names[0])),
                  let s = ScrollStitcher(firstFrame: first) else { continue }
            var appended = 0, unchanged = 0, noOverlap = 0
            var moved = false
            var worst = 0.0
            for name in names.dropFirst() {
                guard let img = load(dir.appendingPathComponent(name)) else { continue }
                let t0 = Date()
                let outcome = s.add(img)
                worst = max(worst, Date().timeIntervalSince(t0))
                switch outcome {
                case .appended: appended += 1; moved = true
                case .unchanged: unchanged += 1
                case .noOverlap: noOverlap += 1
                case .limitReached: break
                }
                if !moved {
                    XCTAssertEqual(s.fixedTopRows, 0, "\(dir.lastPathComponent) \(name): banda superior sin movimiento")
                    XCTAssertEqual(s.fixedBottomRows, 0, "\(dir.lastPathComponent) \(name): banda inferior sin movimiento")
                }
            }
            print("REPLAY \(dir.lastPathComponent): fotogramas=\(names.count) appended=\(appended) unchanged=\(unchanged) noOverlap=\(noOverlap) alto=\(s.height) top=\(s.fixedTopRows) bottom=\(s.fixedBottomRows) peor=\(Int(worst * 1000))ms")

            let withMotion = appended + noOverlap
            if withMotion > 0 {
                XCTAssertLessThan(Double(noOverlap) / Double(withMotion), 0.10, "\(dir.lastPathComponent): demasiados noOverlap")
            }
            XCTAssertLessThanOrEqual(s.fixedTopRows + s.fixedBottomRows, s.height / 2)
        }
    }
}
