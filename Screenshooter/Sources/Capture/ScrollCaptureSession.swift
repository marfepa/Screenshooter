import AppKit
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Flujo continuo de fotogramas (ScreenCaptureKit) de un área, para la captura larga.
///
/// Captura el display completo a resolución nativa (sin `sourceRect`, ver Trampas del ámbito) y recorta cada
/// fotograma al área con la misma función que la captura normal (`ScreenCaptureEngine.cropRect`).
/// Excluye todas las ventanas de la propia app (marco, píldora, vista previa, Tira).
final class ScrollCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let rect: CGRect
    private let screen: NSScreen
    private let framesPerSecond: Int
    private let onFrame: (CGImage) -> Void
    private let onStop: @MainActor (Error?) -> Void

    /// Cola donde ScreenCaptureKit entrega los fotogramas (solo decide si descartar).
    private let sampleQueue = DispatchQueue(label: "com.marfepa.Screenshooter.scroll.samples", qos: .userInitiated)
    /// Cola serie propia donde se convierte, recorta y se llama a `onFrame`.
    private let workQueue = DispatchQueue(label: "com.marfepa.Screenshooter.scroll.work", qos: .userInitiated)

    private let lock = NSLock()
    private var stream: SCStream?
    private var isProcessing = false
    private var isStopped = false

    init(
        rect: CGRect,
        screen: NSScreen,
        framesPerSecond: Int = 12,
        onFrame: @escaping (CGImage) -> Void,
        onStop: @escaping @MainActor (Error?) -> Void
    ) {
        self.rect = rect
        self.screen = screen
        self.framesPerSecond = max(1, framesPerSecond)
        self.onFrame = onFrame
        self.onStop = onStop
        super.init()
    }

    // MARK: - Ciclo de vida

    func start() async throws {
        guard ScreenCaptureEngine.shared.hasScreenCapturePermission() else {
            throw ScreenCaptureError.permissionDenied
        }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let scale = screen.backingScaleFactor

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.queueDepth = 3

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        install(newStream)
        do {
            try await newStream.startCapture()
        } catch {
            clearStream()
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }

    /// Para el flujo. Tras llamarla no se vuelve a invocar `onFrame` ni `onStop`.
    func stop() async {
        let current = takeStreamForStop()
        guard let current else { return }
        try? current.removeStreamOutput(self, type: .screen)
        try? await current.stopCapture()
    }

    private func install(_ newStream: SCStream) {
        lock.lock(); defer { lock.unlock() }
        isStopped = false
        stream = newStream
    }

    private func clearStream() {
        lock.lock(); defer { lock.unlock() }
        stream = nil
    }

    private func takeStreamForStop() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        isStopped = true
        let current = stream
        stream = nil
        return current
    }

    private var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return isStopped
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !stopped else { return }
        guard Self.isComplete(sampleBuffer), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Si el anterior sigue en proceso, este se descarta (sin cola creciente).
        lock.lock()
        if isProcessing { lock.unlock(); return }
        isProcessing = true
        lock.unlock()

        let box = PixelBufferBox(pixelBuffer)
        workQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.isProcessing = false
                self.lock.unlock()
            }
            guard !self.stopped, let cropped = self.crop(box.buffer) else { return }
            self.onFrame(cropped)
        }
    }

    private func crop(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        var created: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &created)
        guard let full = created else { return nil }
        let cropRect = ScreenCaptureEngine.cropRect(
            for: rect, screenFrame: screen.frame, scale: screen.backingScaleFactor,
            imageSize: CGSize(width: full.width, height: full.height)
        )
        return full.cropping(to: cropRect)
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        lock.lock()
        isStopped = true
        self.stream = nil
        lock.unlock()
        let handler = onStop
        Task { @MainActor in handler(error) }
    }
}

/// `CVPixelBuffer` no es `Sendable`; el fotograma solo lo lee la cola de trabajo.
private struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
