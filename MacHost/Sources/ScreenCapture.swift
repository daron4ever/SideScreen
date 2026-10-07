import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import CoreVideo
import IOSurface
import os

// MARK: - SCStreamDelegate

private class StreamDelegate: NSObject, SCStreamDelegate {
    var onStreamError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        debugLog("SCStream stopped with error — domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)")
        onStreamError?(error)
    }
}

// MARK: - ScreenCapture

class ScreenCapture {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var encoder: VideoEncoder?
    private var display: SCDisplay?
    private var virtualDisplayID: CGDirectDisplayID?
    private var refreshRate: Int = 60

    // Thread-safe state for cross-thread access (frame output queue + main queue)
    private let stateLock = OSAllocatedUnfairLock(initialState: FrameMonitorState())

    private struct FrameMonitorState {
        var lastFrameTime: DispatchTime?
        var hasReceivedFirstFrame = false
        var fallbackActive = false
        var lifecycle = CaptureSleepLifecycle()
        var captureEncoder: VideoEncoder?
        var framePipeline: CaptureFramePipeline?
    }

    private struct KeyframeRequestState {
        var lastKeyframeOrReplayRequestNs: UInt64 = 0
    }
    private let keyframeRequestLock = OSAllocatedUnfairLock(initialState: KeyframeRequestState())
    private static let keyframeRequestThrottleNs: UInt64 = 500_000_000

    // Main-thread-only state
    private var frameMonitorTimer: DispatchSourceTimer?
    private var restartAttempted = false
    private var captureTask: Task<Void, Never>?
    private var wakeRestartTask: Task<Void, Never>?

    private func permitsCapture(_ generation: UInt64) -> Bool {
        stateLock.withLock { $0.lifecycle.permitsCapture(generation) }
    }

    // CGDisplayStream fallback
    private var cgDisplayStream: CGDisplayStream?

    // Streaming parameters (saved for restart)
    private weak var currentServer: StreamingServer?
    private var currentBitrateMbps: Int = 20
    private var currentQuality: String = "medium"
    private var currentGamingBoost: Bool = false
    private var currentFrameRate: Int = 60

    /// Callback when capture method changes (e.g. SCStream → CGDisplayStream fallback)
    var onPermissionDenied: (() -> Void)?
    var onCaptureMethodChanged: ((String) -> Void)?

    /// Every new encoder starts with an IDR; request another from an active one.
    func requestKeyframe() {
        if let encoder = stateLock.withLock({ state in
            state.lifecycle.permitsCapture(state.lifecycle.generation) ? state.captureEncoder : nil
        }) {
            encoder.requestKeyframe()
            return
        }
    }

    /// Force a keyframe for the next captured frame, AND immediately re-encode
    /// the last cached frame as a forced keyframe if the display is currently
    /// idle. Without this, a client connecting during a static screen would
    /// wait up to one full GOP duration before its decoder could start.
    func requestKeyframeOrReplayCachedFrame(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldRequest = keyframeRequestLock.withLock { state -> Bool in
            if !force,
               state.lastKeyframeOrReplayRequestNs > 0,
               now - state.lastKeyframeOrReplayRequestNs < Self.keyframeRequestThrottleNs {
                return false
            }
            state.lastKeyframeOrReplayRequestNs = now
            return true
        }
        guard shouldRequest else { return }

        requestKeyframe()

        let pipeline = stateLock.withLock { state in
            state.framePipeline
        }

        let pts = CMTime(
            value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000),
            timescale: 1_000_000
        )

        pipeline?.replayCachedFrame(timestamp: pts)
    }

    var displayWidth: Int {
        guard let id = virtualDisplayID else { return display?.width ?? 0 }
        return ScreenCapture.physicalSize(for: id).width
    }
    var displayHeight: Int {
        guard let id = virtualDisplayID else { return display?.height ?? 0 }
        return ScreenCapture.physicalSize(for: id).height
    }

    /// Codec for the current encode session. Switching restarts the stream.
    private(set) var codec: StreamCodec = .hevc

    /// Largest frame the connected client wants to receive (issue #41): the
    /// smaller of its panel size and what its decoder can sustain at the panel
    /// refresh rate. Nil for legacy clients that report nothing.
    private var clientDecodeLimit: (width: Int, height: Int)?
    private var clientDecodeLimit120: (width: Int, height: Int)?

    /// Encode dimensions for a codec: physical display pixels, clamped to the
    /// client's reported ceiling when known, else to the conservative AVC floor
    /// when streaming H.264. SCStream/CGDisplayStream scale the capture into
    /// this size, so no virtual-display change is needed.
    ///
    /// This is what makes HiDPI usable on a tablet: macOS renders at 2x, SCStream
    /// downsamples to the client's ceiling before encode, and the client decodes
    /// a frame it can sustain — sharper than a 1x capture of the same size.
    func encodeSize(for codec: StreamCodec) -> (width: Int, height: Int) {
        let phys = (displayWidth, displayHeight)
        // A reported limit is authoritative for both codecs: it is what the
        // client's own MediaCodec claims it can decode.
        if let budget = CodecLimits.negotiatedBudget(
            legacy: clientDecodeLimit, highRefresh: clientDecodeLimit120, forFps: refreshRate
        ) {
            return CodecLimits.clampToClientLimit(width: phys.0, height: phys.1, limit: budget)
        }
        switch codec {
        case .hevc: return phys
        case .h264: return CodecLimits.clampForAvc(width: phys.0, height: phys.1)
        }
    }

    /// Returns physical pixel dimensions for a display ID.
    /// CGDisplayPixelsWide/High return logical pixels on HiDPI displays — use
    /// CGDisplayModeGetPixelWidth/Height to always get the true physical size.
    static func physicalSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            if w > 0 && h > 0 { return (w, h) }
        }
        // Mode lookup failed — falling back to logical pixels (may be stale on HiDPI display)
        debugLog("physicalSize fallback for display \(displayID) — CGDisplayCopyDisplayMode returned nil")
        return (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
    }

    init() async throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("ScreenCapture init — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }

    /// Setup screen capture for a specific virtual display
    @MainActor
    func setupForVirtualDisplay(_ displayID: CGDirectDisplayID, refreshRate: Int = 60) async throws {
        self.virtualDisplayID = displayID
        self.refreshRate = refreshRate
        try await setupDisplay()
        try await setupStream()
    }

    // MARK: - Host display lifecycle (owned by AppDelegate)

    @MainActor
    func setHostDisplayAwake(_ awake: Bool) {
        let changed = stateLock.withLock { $0.lifecycle.setDisplayAwake(awake) }
        guard changed else { return }
        wakeRestartTask?.cancel()
        wakeRestartTask = nil
        if !awake {
            suspendCapture()
            return
        }
        let ticket = stateLock.withLock { $0.lifecycle.generation }
        guard permitsCapture(ticket) else { return }
        // Duplicate display/system wake notifications do not schedule a second
        // rebuild. Sleep and Stop invalidate this ticket before the delay ends.
        wakeRestartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch { return }
            guard let self, self.permitsCapture(ticket), !Task.isCancelled else { return }
            self.wakeRestartTask = nil
            self.restartStream()
            self.restartAttempted = false
        }
    }

    // MARK: - SCShareableContent with timeout

    private func getShareableContentWithTimeout(seconds: Int = 10) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw NSError(domain: "ScreenCapture", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "SCShareableContent timed out after \(seconds)s (possible Apple bug FB12114396)"])
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Display setup

    @MainActor
    private func setupDisplay(generation: UInt64? = nil) async throws {
        guard let virtualDisplayID = virtualDisplayID else {
            throw NSError(domain: "ScreenCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Virtual display ID not set"])
        }

        for attempt in 1...5 {
            let content: SCShareableContent
            do {
                content = try await getShareableContentWithTimeout(seconds: 10)
            } catch {
                if isScreenRecordingPermissionDenied(error) { throw error }
                debugLog("SCShareableContent attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                throw error
            }

            debugLog("SCShareableContent returned \(content.displays.count) displays: \(content.displays.map { $0.displayID })")

            if let virtualDisplay = content.displays.first(where: { $0.displayID == virtualDisplayID }) {
                if let generation, !permitsCapture(generation) { throw CancellationError() }
                try Task.checkCancellation()
                display = virtualDisplay
                debugLog("Capturing virtual display: \(virtualDisplay.width)x\(virtualDisplay.height) (ID: \(virtualDisplayID))")
                return
            }

            if attempt < 5 {
                debugLog("Virtual display \(virtualDisplayID) not found in attempt \(attempt), retrying...")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        throw NSError(domain: "ScreenCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Virtual display with ID \(virtualDisplayID) not found after 5 attempts"])
    }

    // MARK: - Stream setup

    @MainActor
    private func setupStream() async throws {
        guard let display = display, virtualDisplayID != nil else {
            throw NSError(domain: "ScreenCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not initialized"])
        }

        // Physical pixels for full Retina sharpness, clamped when H.264 (SCStream scales)
        let (width, height) = encodeSize(for: codec)
        let fps = refreshRate

        // Keep a local reference. `streamOutput` is cleared by the restart, fallback
        // and stop paths, so force-unwrapping the property further down races with
        // any of them and crashes setup with "Unexpectedly found nil".
        let output = StreamOutput()
        streamOutput = output

        let delegate = StreamDelegate()
        delegate.onStreamError = { [weak self, weak delegate] error in
            Task { @MainActor in
                guard let self, let delegate, self.streamDelegate === delegate else { return }
                let ticket = self.stateLock.withLock { $0.lifecycle.generation }
                guard self.permitsCapture(ticket) else { return }
                if self.handlePermissionFailure(error) { return }
                self.attemptFallbackCapture()
            }
        }
        streamDelegate = delegate

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Video-range (16-235) rather than full-range (0-255). VideoToolbox
        // derives the bitstream's VUI full_range_flag from the pixel format,
        // and several Android vendor display paths (Xiaomi/HyperOS among
        // them) apply a limited-range YUV->RGB matrix regardless of that
        // flag, which clips full-range highlights to white and crushes
        // shadows (#55). Limited range is what every decoder/GPU assumes by
        // default, so it renders identically everywhere.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        // Diagnostic: allow more capture buffers at high refresh rates while
        // VideoToolbox processes previous frames asynchronously.
        config.queueDepth = fps > 60 ? 6 : 4
        config.capturesAudio = false
        config.backgroundColor = .clear
        config.scalesToFit = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try scStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        stream = scStream
        debugLog("Stream configured: \(width)x\(height) @ \(fps)fps (with delegate)")
    }

    // MARK: - Shared frame handler (used by both startStreaming and restartStream)

    @MainActor
    private func makeFramePipeline(generation: UInt64) -> CaptureFramePipeline {
        let captureEncoder = encoder
        let pipeline = CaptureFramePipeline(
            queue: DispatchQueue(label: "com.sidescreen.encode", qos: .userInteractive),
            isCurrent: { [weak self] in self?.permitsCapture(generation) == true },
            encode: { buffer, timestamp, replay in
                if replay {
                    captureEncoder?.requestKeyframe()
                    captureEncoder?.stageCounters.record(.replay)
                }
                captureEncoder?.encode(pixelBuffer: buffer, presentationTimeStamp: timestamp)
            }
        )
        stateLock.withLock { state in
            state.captureEncoder = captureEncoder
            state.framePipeline = pipeline
        }
        return pipeline
    }

    @MainActor
    private func configureFrameHandler(generation: UInt64) {
        let pipeline = makeFramePipeline(generation: generation)
        let counters = FrameStageCounters(stage: .capture)

        // Installed before startCapture. Never mutated while this output can
        // receive samples; retiring outputs retain their generation-bound callback.
        streamOutput?.onFrameReceived = { [weak self] sampleBuffer in
            guard let self, self.permitsCapture(generation) else { return }
            let isFirst = self.stateLock.withLock { state -> Bool in
                guard state.lifecycle.permitsCapture(generation) else { return false }
                state.lastFrameTime = DispatchTime.now()
                if !state.hasReceivedFirstFrame {
                    state.hasReceivedFirstFrame = true
                    return true
                }
                return false
            }
            if isFirst { self.onCaptureMethodChanged?("SCStream") }
            let submission = pipeline.submitScreenFrame(
                CMSampleBufferGetImageBuffer(sampleBuffer),
                timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            switch submission {
            case .image: counters.record(.callbacks, also: .images)
            case .cached: counters.record(.callbacks, also: .cached)
            case .empty: counters.record(.callbacks, also: .empty)
            case .skipped: counters.record(.callbacks, also: .skipped)
            case .inactive: break
            }
        }
    }

    // MARK: - Start streaming

    @MainActor
    func startStreaming(to server: StreamingServer?, bitrateMbps: Int = 20, quality: String = "medium", gamingBoost: Bool = false, frameRate: Int = 60) {
        currentServer = server
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        currentFrameRate = frameRate
        let generation = stateLock.withLock { $0.lifecycle.start() }
        guard permitsCapture(generation) else {
            suspendCapture()
            return
        }
        queueCaptureRecovery(generation: generation, reuseConfiguredStream: true)
    }

    // MARK: - Continuous frame-flow monitor

    @MainActor
    private func startFrameMonitor() {
        stopFrameMonitor()
        let generation = stateLock.withLock { $0.lifecycle.generation }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.permitsCapture(generation) else { return }
            let isFallback = self.stateLock.withLock { $0.fallbackActive }
            guard !isFallback else {
                self.stopFrameMonitor()
                return
            }

            let stalled: Bool
            let lastTime = self.stateLock.withLock { $0.lastFrameTime }
            if let last = lastTime {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
                stalled = elapsed > 5.0
                if stalled {
                    debugLog("Frame flow stalled — no frames for \(String(format: "%.1f", elapsed))s, triggering fallback")
                }
            } else {
                stalled = true
                debugLog("Frame flow stalled — no frames ever received after 5s, triggering fallback")
            }

            if stalled {
                let hasHadFrames = self.stateLock.withLock { $0.hasReceivedFirstFrame }

                let pipeline = self.stateLock.withLock { $0.framePipeline }
                if hasHadFrames, pipeline?.hasCachedImage == true {
                    // A static display may stop delivering frames; replay only
                    // while this capture generation is awake and active.
                    self.requestKeyframeOrReplayCachedFrame()
                    self.stateLock.withLock { $0.lastFrameTime = DispatchTime.now() }
                    // Keep monitoring — real errors are handled by the SCStream error delegate
                } else {
                    self.stopFrameMonitor()
                    if !self.restartAttempted {
                        debugLog("Attempting SCStream restart...")
                        self.restartStream()
                    } else {
                        debugLog("Restart already attempted — falling back to CGDisplayStream")
                        self.attemptFallbackCapture()
                    }
                }
            }
        }
        timer.resume()
        frameMonitorTimer = timer
    }

    @MainActor
    private func stopFrameMonitor() {
        frameMonitorTimer?.cancel()
        frameMonitorTimer = nil
    }

    /// A denial requires user action, not another capture API or retry loop.
    @MainActor
    private func handlePermissionFailure(_ error: Error) -> Bool {
        guard isScreenRecordingPermissionDenied(error) else { return false }
        stopFrameMonitor()
        onPermissionDenied?()
        return true
    }

    // MARK: - Stream restart

    @MainActor
    private func restartStream() {
        guard let generation = stateLock.withLock({ $0.lifecycle.beginRecovery() }) else { return }
        restartAttempted = true
        queueCaptureRecovery(generation: generation)
    }

    @MainActor
    private func detachCapture() -> SCStream? {
        stopFrameMonitor()
        // The retiring stream still owns its output while platform stop is
        // pending. Leave its callback immutable; its generation rejects samples.
        let previousStream = stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        cgDisplayStream?.stop()
        cgDisplayStream = nil
        let retiredPipeline = stateLock.withLock { state -> CaptureFramePipeline? in
            let pipeline = state.framePipeline
            state.lastFrameTime = nil
            state.hasReceivedFirstFrame = false
            state.fallbackActive = false
            state.captureEncoder = nil
            state.framePipeline = nil
            return pipeline
        }
        retiredPipeline?.invalidate()
        encoder = nil
        return previousStream
    }

    @MainActor
    private func suspendCapture() {
        let previousTask = captureTask
        previousTask?.cancel()
        let previousStream = detachCapture()
        // Await pending platform calls before stopping their captured stream;
        // later wake recovery joins this same lane before creating a new one.
        captureTask = Task { @MainActor in
            await previousTask?.value
            try? await previousStream?.stopCapture()
        }
    }

    @MainActor
    private func queueCaptureRecovery(
        generation: UInt64, reuseConfiguredStream: Bool = false, fallbackOnly: Bool = false
    ) {
        let previousTask = captureTask
        previousTask?.cancel()
        let configuredStream = reuseConfiguredStream ? stream : nil
        let configuredOutput = reuseConfiguredStream ? streamOutput : nil
        let configuredDelegate = reuseConfiguredStream ? streamDelegate : nil
        let previousStream = detachCapture()
        captureTask = Task { @MainActor [weak self] in
            await previousTask?.value
            if !reuseConfiguredStream { try? await previousStream?.stopCapture() }
            guard let self, self.permitsCapture(generation), !Task.isCancelled else {
                if reuseConfiguredStream { try? await previousStream?.stopCapture() }
                return
            }
            if fallbackOnly {
                self.startFallbackCapture(generation: generation)
                return
            }
            var ownedStream: SCStream?
            do {
                if let configuredStream {
                    self.stream = configuredStream
                    self.streamOutput = configuredOutput
                    self.streamDelegate = configuredDelegate
                } else {
                    try await self.setupDisplay(generation: generation)
                    guard self.permitsCapture(generation), !Task.isCancelled else { return }
                    try await self.setupStream()
                }
                ownedStream = self.stream
                guard self.permitsCapture(generation), !Task.isCancelled else {
                    try? await ownedStream?.stopCapture()
                    return
                }
                self.createEncoder(generation: generation)
                self.configureFrameHandler(generation: generation)
                try await ownedStream?.startCapture()
                guard self.permitsCapture(generation), !Task.isCancelled else {
                    try? await ownedStream?.stopCapture()
                    return
                }
                self.requestKeyframeOrReplayCachedFrame(force: true)
                self.startFrameMonitor()
            } catch {
                try? await ownedStream?.stopCapture()
                guard self.permitsCapture(generation), !Task.isCancelled else { return }
                if self.handlePermissionFailure(error) { return }
                _ = self.detachCapture()
                self.startFallbackCapture(generation: generation)
            }
        }
    }

    @MainActor
    private func createEncoder(generation: UInt64) {
        let (width, height) = encodeSize(for: codec)
        let server = currentServer
        let newEncoder = VideoEncoder(width: width, height: height, codec: codec,
            bitrateMbps: currentBitrateMbps, quality: currentQuality,
            gamingBoost: currentGamingBoost, frameRate: currentFrameRate)
        newEncoder.onEncodedFrame = { [weak self, weak server] data, timestamp, isKeyframe in
            guard self?.permitsCapture(generation) == true else { return }
            server?.sendFrame(data, timestamp: timestamp, isKeyframe: isKeyframe)
        }
        newEncoder.requestKeyframe()
        encoder = newEncoder
    }

    // MARK: - CGDisplayStream fallback

    @MainActor
    private func attemptFallbackCapture() {
        guard !stateLock.withLock({ $0.fallbackActive }),
              let generation = stateLock.withLock({ $0.lifecycle.beginRecovery() }) else { return }
        queueCaptureRecovery(generation: generation, fallbackOnly: true)
    }

    @MainActor
    private func startFallbackCapture(generation: UInt64) {
        guard permitsCapture(generation), let displayID = virtualDisplayID else { return }
        createEncoder(generation: generation)
        let pipeline = makeFramePipeline(generation: generation)

        // CGDisplayStream scales natively via outputWidth/Height, so the
        // AVC clamp applies here exactly as in the SCStream path.
        let (width, height) = encodeSize(for: codec)

        debugLog("CGDisplayStream fallback — display \(displayID) (\(width)x\(height))")

        // Video-range to match the SCStream path (see #55 note above).
        let pixelFormat = Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let queue = DispatchQueue(label: "com.sidescreen.cgdisplaystream", qos: .userInteractive)

        // Without kCGDisplayStreamShowCursor the fallback stream never
        // composites the cursor at all (the key defaults to false), so any
        // session that degrades to CGDisplayStream loses the pointer on the
        // tablet even when WindowServer is healthy.
        let streamProps = [CGDisplayStream.showCursor as String: true] as CFDictionary

        let counters = FrameStageCounters(stage: .fallback)
        guard let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: pixelFormat,
            properties: streamProps,
            queue: queue,
            handler: { [weak self] _, _, frameSurface, _ in
                guard let self, self.permitsCapture(generation) else { return }
                counters.record(.callbacks)
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                guard let surface = frameSurface else {
                    _ = pipeline.submitFallbackFrame(nil, timestamp: pts)
                    counters.record(.empty)
                    return
                }

                var unmanagedPB: Unmanaged<CVPixelBuffer>?
                let attrs: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                ]
                let cvReturn = CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault,
                    surface,
                    attrs as CFDictionary,
                    &unmanagedPB
                )

                guard cvReturn == kCVReturnSuccess, let pb = unmanagedPB?.takeRetainedValue() else {
                    counters.record(.empty)
                    return
                }
                counters.record(.images)

                _ = pipeline.submitFallbackFrame(pb, timestamp: pts)
            }
        ) else {
            debugLog("Failed to create CGDisplayStream — fallback unavailable")
            _ = detachCapture()
            return
        }

        let startResult = displayStream.start()
        if startResult == .success {
            cgDisplayStream = displayStream
            stateLock.withLock { $0.fallbackActive = true }
            debugLog("CGDisplayStream fallback started successfully")
            onCaptureMethodChanged?("CGDisplayStream (fallback)")
        } else {
            debugLog("CGDisplayStream.start() failed: \(startResult)")
            _ = detachCapture()
        }
    }

    // MARK: - Settings update

    func updateEncoderSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        currentBitrateMbps = bitrateMbps
        currentQuality = quality
        currentGamingBoost = gamingBoost
        encoder?.updateSettings(bitrateMbps: bitrateMbps, quality: quality, gamingBoost: gamingBoost)
    }

    /// Switch the wire codec. No-op when unchanged. When changed mid-stream,
    /// rebuilds the encoder at the codec's encode size and restarts capture so
    /// SCStream delivers buffers at the (possibly clamped) dimensions. The
    /// client's keyframe-request loop (force, 200 ms interval) bridges the
    /// restart gap — the decoder drops frames until the first new keyframe.
    /// Apply the per-connection negotiation result: stream codec plus the
    /// client's reported decoder ceiling. Rebuilds the encoder mid-session
    /// when either changes the encode setup (a codec switch, or a ceiling
    /// that alters the encode dimensions — issue #41).
    @MainActor
    func negotiate(
        codec newCodec: StreamCodec,
        clientLimit: (width: Int, height: Int)?,
        clientLimit120: (width: Int, height: Int)? = nil
    ) {
        let sizeBefore = encodeSize(for: codec)
        let codecChanged = newCodec != codec
        if codecChanged {
            debugLog("Switching stream codec: \(codec) -> \(newCodec)")
        }
        codec = newCodec
        clientDecodeLimit = clientLimit
        clientDecodeLimit120 = clientLimit120

        guard stateLock.withLock({ $0.lifecycle.streaming }) else { return }

        let sizeAfter = encodeSize(for: newCodec)
        guard codecChanged || sizeBefore != sizeAfter else { return }
        if sizeBefore != sizeAfter {
            let limitDesc = clientLimit.map { "\($0.width)x\($0.height)" } ?? "none"
            debugLog("Encode size \(sizeBefore.width)x\(sizeBefore.height) -> \(sizeAfter.width)x\(sizeAfter.height) (client decoder limit: \(limitDesc))")
        }
        restartStream()
    }

    // MARK: - Stop streaming

    @MainActor
    func stopStreaming() {
        stateLock.withLock { $0.lifecycle.stop() }
        wakeRestartTask?.cancel()
        wakeRestartTask = nil
        suspendCapture()
        restartAttempted = false
        display = nil
    }

}

// MARK: - StreamOutput

class StreamOutput: NSObject, SCStreamOutput {
    var onFrameReceived: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        onFrameReceived?(sampleBuffer)
    }
}
