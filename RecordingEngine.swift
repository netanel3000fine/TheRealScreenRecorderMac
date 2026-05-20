import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage
import Combine
import CoreGraphics

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case countdown(Int)
    case recording
    case saving
}

// MARK: - Recording Item (saved file)

struct RecordingItem: Identifiable, Codable {
    let id: UUID
    let filename: String
    let filePath: String
    let date: Date
    var duration: TimeInterval
    var fileSize: Int64

    var url: URL { URL(fileURLWithPath: filePath) }

    var formattedDuration: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }

    var formattedSize: String {
        let mb = Double(fileSize) / 1_000_000
        return mb < 1 ? String(format: T("%.0f KB"), mb * 1000) : String(format: T("%.1f MB"), mb)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var formattedDate: String {
        Self.dateFormatter.string(from: date)
    }
}

// MARK: - RecordingEngine

@MainActor
class RecordingEngine: NSObject, ObservableObject {
    static let shared = RecordingEngine()

    @Published var state: RecordingState = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var errorMessage: String? = nil

    private var stream: SCStream?
    private var recordingDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var recordingWindowID: CGWindowID?
    private var recordingCropRect: CGRect?

    /// Non-isolated container so SCStreamOutput callbacks can access it without @MainActor hops.
    private class SideBySideState: @unchecked Sendable {
        let lock = NSLock()
        var secondaryStream: SCStream?
        var latestFrame: CVPixelBuffer?
        var active: Bool = false
    }
    nonisolated private let sideBySide = SideBySideState()

    private class WriterState: @unchecked Sendable {
        let lock = NSLock()
        var assetWriter: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var sessionStarted = false
        var videoFrameCount = 0
        var frameBorderSize: Int = 0
    }
    nonisolated private let writerState = WriterState()

    nonisolated private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    private var recordingStartTime: Date?
    private var currentOutputURL: URL?
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var playMediaOnStart: Bool = false
    private var pauseMediaOnFinish: Bool = false

    override init() {
        super.init()
    }

    // MARK: - Public API

    func toggleRecording() {
        switch state {
        case .idle:
            if !CGPreflightScreenCaptureAccess() {
                errorMessage = T("Missing Screen Recording permission. If already checked, toggle it off and back on in System Settings > Privacy & Security > Screen Recording.")
                return
            }
            startCountdown()
        case .recording:
            Task { await stopRecording() }
        default:
            break
        }
    }

    func startCountdown() {
        startCountdownWith(seconds: 3)
    }

    func startCountdownWith(seconds: Int, displayID: CGDirectDisplayID = CGMainDisplayID(), sideBySide: Bool = false, windowID: CGWindowID? = nil, cropRect: CGRect? = nil, playMediaOnStart: Bool = false, pauseMediaOnFinish: Bool = false) {
        recordingDisplayID = displayID
        self.sideBySide.active = sideBySide
        recordingWindowID = windowID
        recordingCropRect = cropRect
        self.playMediaOnStart = playMediaOnStart
        self.pauseMediaOnFinish = pauseMediaOnFinish
        guard seconds > 0 else {
            Task { await startRecording() }
            return
        }
        state = .countdown(seconds)
        var count = seconds
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self = self, case .countdown = self.state else {
                    t.invalidate()
                    return
                }
                count -= 1
                if count <= 0 {
                    t.invalidate()
                    await self.startRecording()
                } else {
                    self.state = .countdown(count)
                }
            }
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        state = .idle
    }

    func startRecording() async {
        // Send Play/Pause media key if requested
        if playMediaOnStart {
            playMediaOnStart = false
            sendMediaPlayKey()
        }
        // Ensure permissions are granted before starting to record
        if !CGPreflightScreenCaptureAccess() {
            errorMessage = T("Missing Screen Recording permission. If already checked, toggle it off and back on in System Settings > Privacy & Security > Screen Recording.")
            state = .idle
            return
        }

        do {
            // 1. Get shareable content
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let allDisplays = availableContent.displays
            guard !allDisplays.isEmpty else { errorMessage = T("No display found."); return }

            // Resolve primary display by stored ID (fallback to first)
            let primaryDisplay = allDisplays.first(where: { $0.displayID == recordingDisplayID }) ?? allDisplays[0]

            // 2. Build primary stream config
            let muteAudio = UserDefaults.standard.bool(forKey: "muteSystemAudio")
            let resolutionPct = UserDefaults.standard.integer(forKey: "resolutionScale")
            let resFactor: Double = resolutionPct > 0 ? Double(resolutionPct) / 100.0 : 1.0

            func scaled(_ value: Int) -> Int {
                let s = Int((Double(value) * resFactor).rounded())
                return s % 2 == 0 ? s : s + 1
            }

            func makeConfig(for disp: SCDisplay, extraWidth: Int = 0) -> SCStreamConfiguration {
                let c = SCStreamConfiguration()
                c.width  = scaled(disp.width + extraWidth)
                c.height = scaled(disp.height)
                c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                c.queueDepth = 6
                c.capturesAudio = !muteAudio
                c.excludesCurrentProcessAudio = true
                return c
            }

            // For side-by-side: pick the secondary display (any display that isn't the primary)
            let secondaryDisplay: SCDisplay? = sideBySide.active ? allDisplays.first(where: { $0.displayID != primaryDisplay.displayID }) : nil

            var primaryFilter: SCContentFilter
            var primaryConfig: SCStreamConfiguration
            var outputWidth: Int
            var outputHeight: Int
            
            if let winID = recordingWindowID,
               let targetWindow = availableContent.windows.first(where: { $0.windowID == winID }) {
                primaryFilter = SCContentFilter(desktopIndependentWindow: targetWindow)
                let c = SCStreamConfiguration()
                let backingScale = getBackingScaleFactor(for: recordingDisplayID)
                c.width  = scaled(Int(targetWindow.frame.width  * backingScale))
                c.height = scaled(Int(targetWindow.frame.height * backingScale))
                c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                c.queueDepth = 6
                c.capturesAudio = !muteAudio
                c.excludesCurrentProcessAudio = true
                primaryConfig = c
                outputWidth = c.width
                outputHeight = c.height
            } else if let rect = recordingCropRect {
                primaryFilter = SCContentFilter(display: primaryDisplay, excludingApplications: [], exceptingWindows: [])
                let c = SCStreamConfiguration()
                let backingScale = getBackingScaleFactor(for: recordingDisplayID)
                c.width  = scaled(Int(rect.width  * backingScale))
                c.height = scaled(Int(rect.height * backingScale))
                c.sourceRect = rect
                c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                c.queueDepth = 6
                c.capturesAudio = !muteAudio
                c.excludesCurrentProcessAudio = true
                primaryConfig = c
                outputWidth = c.width
                outputHeight = c.height
            } else {
                primaryFilter = SCContentFilter(display: primaryDisplay, excludingApplications: [], exceptingWindows: [])
                primaryConfig = makeConfig(for: primaryDisplay)

                if let secondaryDisplay = secondaryDisplay {
                    let primaryHeight = primaryDisplay.height
                    let secondaryHeight = secondaryDisplay.height
                    let commonHeight = max(primaryHeight, secondaryHeight)

                    let scaledPrimaryWidth = Int(Double(primaryDisplay.width) * Double(commonHeight) / Double(primaryHeight))
                    let scaledSecondaryWidth = Int(Double(secondaryDisplay.width) * Double(commonHeight) / Double(secondaryHeight))

                    let totalWidth = scaledPrimaryWidth + scaledSecondaryWidth
                    outputWidth = totalWidth % 2 == 0 ? totalWidth : totalWidth + 1
                    outputHeight = commonHeight % 2 == 0 ? commonHeight : commonHeight + 1
                } else {
                    outputWidth = primaryConfig.width
                    outputHeight = primaryConfig.height
                }
            }

            // 3. Prepare output — expand dimensions if video frame border is requested
            let frameEnabled = UserDefaults.standard.bool(forKey: "videoFrame")
            let frameBorder = frameEnabled ? 20 : 0
            if frameBorder > 0 {
                outputWidth  += frameBorder * 2
                outputHeight += frameBorder * 2
            }

            let outputURL = newOutputURL(withFrame: frameEnabled)
            currentOutputURL = outputURL

            try setupAssetWriter(outputURL: outputURL, width: outputWidth, height: outputHeight, sideBySide: sideBySide.active, frameBorder: frameBorder)

            // 4. Start primary stream
            stream = SCStream(filter: primaryFilter, configuration: primaryConfig, delegate: self)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "video.primary"))
            try stream?.addStreamOutput(self, type: .audio,  sampleHandlerQueue: DispatchQueue(label: "audio.primary"))
            try await stream?.startCapture()

            // 5. Start secondary stream (side-by-side only)
            if let secondaryDisplay = secondaryDisplay {
                let secondaryFilter = SCContentFilter(display: secondaryDisplay, excludingApplications: [], exceptingWindows: [])
                let secondaryConfig = makeConfig(for: secondaryDisplay)
                secondaryConfig.capturesAudio = false  // audio only from primary
                sideBySide.secondaryStream = SCStream(filter: secondaryFilter, configuration: secondaryConfig, delegate: self)
                try sideBySide.secondaryStream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "video.secondary"))
                try await sideBySide.secondaryStream?.startCapture()
            }

            // 6. Update state
            recordingStartTime = Date()
            elapsedSeconds = 0
            state = .recording
            startTimer()

        } catch {
            errorMessage = T("Recording failed: ") + error.localizedDescription
            try? "Recording failed: \(error.localizedDescription)\n".write(toFile: "/Applications/The Real Screen Recorder/error.log", atomically: true, encoding: .utf8)
            state = .idle
        }
    }

    func stopRecording() async {
        state = .saving
        timer?.invalidate()

        do { try await stream?.stopCapture() } catch { print("Primary stream stop: \(error)") }
        do { try await sideBySide.secondaryStream?.stopCapture() } catch { print("Secondary stream stop: \(error)") }
        stream = nil
        sideBySide.secondaryStream = nil
        sideBySide.latestFrame = nil

        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())

        writerState.lock.lock()
        let writer = writerState.assetWriter
        let vInput = writerState.videoInput
        let aInput = writerState.audioInput
        let frameCount = writerState.videoFrameCount
        writerState.assetWriter = nil
        writerState.videoInput = nil
        writerState.audioInput = nil
        writerState.sessionStarted = false
        writerState.lock.unlock()

        if frameCount == 0 {
            print("Warning: No video frames recorded. The file might be unplayable.")
        }

        await withCheckedContinuation { continuation in
            vInput?.markAsFinished()
            aInput?.markAsFinished()
            if let writer = writer {
                writer.finishWriting {
                    continuation.resume()
                }
            } else {
                continuation.resume()
            }
        }

        if let error = writer?.error {
            print("AssetWriter finishWriting failed: \(error)")
        }

        // Save to recordings list
        if let url = currentOutputURL {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let item = RecordingItem(
                id: UUID(),
                filename: url.lastPathComponent,
                filePath: url.path,
                date: recordingStartTime ?? Date(),
                duration: duration,
                fileSize: fileSize
            )
            RecordingStore.shared.addRecording(item)
            
            if UserDefaults.standard.bool(forKey: "autoOpenRecording") {
                openFile(url)
            }
        }

        currentOutputURL = nil
        sideBySide.active = false

        // Send Pause media key if requested
        if pauseMediaOnFinish {
            pauseMediaOnFinish = false
            sendMediaPlayKey()
        }

        state = .idle
    }

    func deleteRecording(_ item: RecordingItem) {
        RecordingStore.shared.deleteRecording(item)
    }

    func revealInFinder(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Media Key

    /// Sends a Play/Pause media key event to the system (equivalent to pressing F8).
    private func sendMediaPlayKey() {
        // NX_KEYTYPE_PLAY = 16
        let NX_KEYTYPE_PLAY: Int64 = 16
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: .init(rawValue: 0xa00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((NX_KEYTYPE_PLAY << 16) | (0xa << 8)),
            data2: -1
        )
        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: .init(rawValue: 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((NX_KEYTYPE_PLAY << 16) | (0xb << 8)),
            data2: -1
        )
        keyDown?.cgEvent?.post(tap: .cghidEventTap)
        keyUp?.cgEvent?.post(tap: .cghidEventTap)
    }

    private func openFile(_ url: URL) {
        let playerPath = UserDefaults.standard.string(forKey: "defaultVideoPlayer") ?? ""
        if playerPath.isEmpty {
            NSWorkspace.shared.open(url)
        } else {
            let appURL = URL(fileURLWithPath: playerPath)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
        }
    }

    // MARK: - Recording Setup Helpers

    private func setupAssetWriter(outputURL: URL, width: Int, height: Int, sideBySide: Bool, frameBorder: Int = 0) throws {
        let useFrame = frameBorder > 0
        let fileType: AVFileType = useFrame ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        let videoSettings: [String: Any]
        if useFrame {
            // HEVC with Alpha preserves transparency at a fraction of ProRes 4444's file size
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey:  width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: sideBySide ? 16_000_000 : 8_000_000,
                    AVVideoQualityKey: 0.85
                ]
            ]
        } else {
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey:  width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: sideBySide ? 16_000_000 : 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        writer.add(videoInput)
        writer.add(audioInput)
        writer.startWriting()

        writerState.lock.lock()
        writerState.assetWriter      = writer
        writerState.videoInput       = videoInput
        writerState.audioInput       = audioInput
        writerState.sessionStarted   = false
        writerState.videoFrameCount  = 0
        writerState.frameBorderSize  = frameBorder
        writerState.lock.unlock()
    }

    private func getBackingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            if id == displayID {
                return screen.backingScaleFactor
            }
        }
        return 2.0 // Fallback
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds += 1
            }
        }
    }

    var elapsedFormatted: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Persistence

    private func newOutputURL(withFrame: Bool = false) -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Screen Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = withFrame ? "mov" : "mp4"
        let baseName = "Recording \(DateFormatter.filenameDateFormatter.string(from: Date()))"
        var name = "\(baseName).\(ext)"
        var url = dir.appendingPathComponent(name)

        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            name = "\(baseName) (\(counter)).\(ext)"
            url = dir.appendingPathComponent(name)
            counter += 1
        }

        return url
    }
}

// MARK: - SCStreamDelegate

extension RecordingEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            print("Stream stopped with error: \(error)")
        }
    }
}

// MARK: - SCStreamOutput

extension RecordingEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            handleVideoOutput(stream: stream, sampleBuffer: sampleBuffer)
        case .audio, .microphone:
            handleAudioOutput(stream: stream, sampleBuffer: sampleBuffer)
        @unknown default:
            break
        }
    }

    nonisolated private func handleAudioOutput(stream: SCStream, sampleBuffer: CMSampleBuffer) {
        // Ignore audio from the secondary stream entirely
        guard stream !== sideBySide.secondaryStream else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        writerState.lock.lock()
        defer { writerState.lock.unlock() }

        guard let writer = writerState.assetWriter, writer.status == .writing else { return }

        // Start the session with the first available buffer (audio or video)
        // so we don't drop any audio that arrives before the first video frame.
        if !writerState.sessionStarted {
            writer.startSession(atSourceTime: pts)
            writerState.sessionStarted = true
        }

        guard writerState.audioInput?.isReadyForMoreMediaData == true else { return }
        writerState.audioInput?.append(sampleBuffer)
    }

    nonisolated private func handleVideoOutput(stream: SCStream, sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Secondary video stream → store latest frame for compositing, never write directly
        if stream === sideBySide.secondaryStream {
            sideBySide.lock.lock()
            sideBySide.latestFrame = pixelBuffer
            sideBySide.lock.unlock()
            return
        }

        // Primary video stream
        let writerAndInput: (AVAssetWriter, AVAssetWriterInput, Bool)? = {
            writerState.lock.lock()
            defer { writerState.lock.unlock() }
            guard let w = writerState.assetWriter,
                  w.status == .writing,
                  let v = writerState.videoInput else { return nil }
            return (w, v, writerState.sessionStarted)
        }()

        guard let (writer, vInput, isStarted) = writerAndInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !isStarted {
            writerState.lock.lock()
            if !writerState.sessionStarted {
                writer.startSession(atSourceTime: pts)
                writerState.sessionStarted = true
            }
            writerState.lock.unlock()
        }

        guard vInput.isReadyForMoreMediaData else { return }
        var bufferToAppend: CMSampleBuffer? = nil

        if sideBySide.active {
            sideBySide.lock.lock()
            let secFrame = sideBySide.latestFrame
            sideBySide.lock.unlock()

            if let sec = secFrame {
                // Composite happens directly on the SCStream queue, NOT main thread
                bufferToAppend = compositeSideBySide(primary: pixelBuffer, secondary: sec, pts: pts)
            }
        } else {
            bufferToAppend = sampleBuffer
        }

        if let buf = bufferToAppend {
            let border: Int = {
                writerState.lock.lock()
                defer { writerState.lock.unlock() }
                return writerState.frameBorderSize
            }()
            if border > 0, let framed = applyVideoFrame(to: buf, border: border) {
                vInput.append(framed)
            } else {
                vInput.append(buf)
            }
            writerState.lock.lock()
            writerState.videoFrameCount += 1
            writerState.lock.unlock()
        }
    }

    // MARK: - Video Frame Overlay

    /// Composites the captured frame onto a transparent canvas with `border` pixels
    /// of padding on each side. The output is a ProRes-4444-compatible pixel buffer
    /// with alpha = 0 in the border region, producing a truly transparent frame.
    nonisolated private func applyVideoFrame(to sampleBuffer: CMSampleBuffer, border: Int) -> CMSampleBuffer? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = srcW + border * 2
        let outH = srcH + border * 2

        // Allocate output buffer (BGRA, alpha channel preserved by ProRes 4444)
        var outBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &outBuffer) == kCVReturnSuccess,
              let out = outBuffer else { return nil }

        // Zero-fill → BGRA(0,0,0,0) = fully transparent black in the border region
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(out) * outH)
        }
        CVPixelBufferUnlockBaseAddress(out, [])

        // Translate the source frame so it sits inside the border.
        // CIImage has a bottom-left origin, so y-offset = border as well.
        let ciSource = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: CGFloat(border),
                                               y: CGFloat(border)))

        // Render only within the source extent; the border area is untouched (transparent).
        ciContext.render(ciSource, to: out,
                         bounds: ciSource.extent,
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        // Wrap back into a CMSampleBuffer preserving original timing
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var timingInfo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                           presentationTimeStamp: pts,
                                           decodeTimeStamp: .invalid)
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out,
                                                     formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return nil }

        var newSampleBuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: out,
                                          dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: fd, sampleTiming: &timingInfo,
                                          sampleBufferOut: &newSampleBuf)
        return newSampleBuf
    }

    // MARK: - Side-by-side frame compositor

    nonisolated private func compositeSideBySide(
        primary: CVPixelBuffer,
        secondary: CVPixelBuffer,
        pts: CMTime
    ) -> CMSampleBuffer? {
        let primaryWidth = CVPixelBufferGetWidth(primary)
        let primaryHeight = CVPixelBufferGetHeight(primary)
        let secondaryWidth = CVPixelBufferGetWidth(secondary)
        let secondaryHeight = CVPixelBufferGetHeight(secondary)

        // Scale both screens to share a common height so nothing gets squished.
        let commonHeight = max(primaryHeight, secondaryHeight)

        // Scaled widths preserving each screen's aspect ratio
        let scaledPrimaryWidth = Int((Double(primaryWidth) * Double(commonHeight) / Double(primaryHeight)).rounded())
        let scaledSecondaryWidth = Int((Double(secondaryWidth) * Double(commonHeight) / Double(secondaryHeight)).rounded())
        let totalWidth = scaledPrimaryWidth + scaledSecondaryWidth

        // Ensure even dimensions for H.264
        let outputWidth = totalWidth % 2 == 0 ? totalWidth : totalWidth + 1
        let outputHeight = commonHeight % 2 == 0 ? commonHeight : commonHeight + 1

        var outBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &outBuffer) == kCVReturnSuccess,
              let out = outBuffer else { return nil }

        // Scale each CIImage to the target (scaledWN × outH) rectangle, then
        // place them side-by-side. CIImage origin is bottom-left.
        let ciPrimary = CIImage(cvPixelBuffer: primary)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(scaledPrimaryWidth) / CGFloat(primaryWidth),
                y:      CGFloat(outputHeight) / CGFloat(primaryHeight)))

        let ciSecondary = CIImage(cvPixelBuffer: secondary)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(scaledSecondaryWidth) / CGFloat(secondaryWidth),
                y:      CGFloat(outputHeight) / CGFloat(secondaryHeight)))
            .transformed(by: CGAffineTransform(translationX: CGFloat(scaledPrimaryWidth), y: 0))

        let combined = ciSecondary.composited(over: ciPrimary)
        ciContext.render(combined, to: out)

        // Wrap into a CMSampleBuffer
        var timingInfo = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                           presentationTimeStamp: pts,
                                           decodeTimeStamp: .invalid)
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return nil }

        var sampleBuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: out,
                                          dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: fd, sampleTiming: &timingInfo,
                                          sampleBufferOut: &sampleBuf)
        return sampleBuf
    }
}

// MARK: - DateFormatter helper

extension DateFormatter {
    static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        return f
    }()
}
