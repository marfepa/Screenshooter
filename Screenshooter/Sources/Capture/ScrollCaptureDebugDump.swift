import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Diagnóstico de captura larga (desactivado por defecto): con `defaults write com.marfepa.Screenshooter scrollCaptureDebugDump -bool YES`
/// vuelca cada fotograma recibido y un `log.txt` en `~/Library/Caches/com.marfepa.Screenshooter/ScrollCaptureDebug/<fecha>/`.
/// La escritura va en una cola serie propia (nunca en main ni en `stitchQueue`).
final class ScrollCaptureDebugDump: @unchecked Sendable {
    static let defaultsKey = "scrollCaptureDebugDump"
    static let maxFrames = 300

    /// Línea de `log.txt`: índice, tiempo relativo, outcome, alto acumulado, bandas fijas.
    static func logLine(index: Int, time: TimeInterval, outcome: String, height: Int, fixedTop: Int, fixedBottom: Int) -> String {
        String(format: "%04d t=%.3f outcome=%@ height=%d fixedTop=%d fixedBottom=%d",
               index, time, outcome, height, fixedTop, fixedBottom)
    }

    static func describe(_ outcome: ScrollStitcher.Outcome?) -> String {
        switch outcome {
        case nil: return "first"
        case .appended(let rows)?: return "appended(\(rows))"
        case .unchanged?: return "unchanged"
        case .noOverlap?: return "noOverlap"
        case .limitReached?: return "limitReached"
        }
    }

    private let queue = DispatchQueue(label: "com.marfepa.Screenshooter.scroll.debugdump", qos: .utility)
    private let directory: URL
    private let start: TimeInterval
    private var count = 0   // solo se toca desde quien llama (stitchQueue)
    private var handle: FileHandle?

    /// Nil si el ajuste está apagado o no se puede crear la carpeta.
    init?(now: TimeInterval, defaults: UserDefaults = .standard, baseURL: URL? = nil) {
        guard defaults.bool(forKey: Self.defaultsKey) else { return nil }
        let base = baseURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.marfepa.Screenshooter/ScrollCaptureDebug", isDirectory: true)
        guard let base else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = base.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        directory = dir
        start = now
    }

    var path: String { directory.path }

    /// Reserva el índice (1…300) del fotograma y encola su PNG; nil si se superó el límite.
    func saveFrame(_ image: CGImage) -> Int? {
        guard count < Self.maxFrames else { return nil }
        count += 1
        let index = count
        let url = directory.appendingPathComponent(String(format: "frame-%04d.png", index))
        let box = UncheckedBox(image)
        queue.async {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, box.value, nil)
            CGImageDestinationFinalize(dest)
        }
        return index
    }

    func log(index: Int, now: TimeInterval, outcome: ScrollStitcher.Outcome?, height: Int, fixedTop: Int, fixedBottom: Int) {
        let line = Self.logLine(index: index, time: now - start, outcome: Self.describe(outcome),
                                height: height, fixedTop: fixedTop, fixedBottom: fixedBottom) + "\n"
        let url = directory.appendingPathComponent("log.txt")
        queue.async { [self] in
            if handle == nil {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
            }
            if let data = line.data(using: .utf8) { try? handle?.write(contentsOf: data) }
        }
    }
}
