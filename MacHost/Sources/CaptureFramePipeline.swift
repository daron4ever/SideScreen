import Foundation
import CoreMedia
import CoreVideo
import os

/// One capture generation owns its cached image and serial encoding lane.
/// Retiring the pipeline rejects both late capture callbacks and queued replays.
final class CaptureFramePipeline {
    enum Submission: Equatable {
        case image, cached, empty, skipped, inactive
    }

    private struct State {
        var active = true
        var cachedImage: CVPixelBuffer?
        var pendingFrames = 0
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let queue: DispatchQueue
    private let isCurrent: () -> Bool
    private let encode: (CVPixelBuffer, CMTime, Bool) -> Void

    init(queue: DispatchQueue, isCurrent: @escaping () -> Bool,
         encode: @escaping (CVPixelBuffer, CMTime, Bool) -> Void) {
        self.queue = queue
        self.isCurrent = isCurrent
        self.encode = encode
    }

    var hasCachedImage: Bool {
        guard isCurrent() else { return false }
        return stateLock.withLock { $0.active && $0.cachedImage != nil }
    }

    func invalidate() {
        stateLock.withLock { state in
            state.active = false
            state.cachedImage = nil
        }
    }

    func submitScreenFrame(_ image: CVPixelBuffer?, timestamp: CMTime) -> Submission {
        submit(image, timestamp: timestamp, reuseCache: true, maximumPending: 2)
    }

    func submitFallbackFrame(_ image: CVPixelBuffer?, timestamp: CMTime) -> Submission {
        // CGDisplayStream's idle callbacks carry no image. They must leave the
        // current image cached without submitting another normal frame.
        submit(image, timestamp: timestamp, reuseCache: false, maximumPending: nil)
    }

    private func submit(_ image: CVPixelBuffer?, timestamp: CMTime,
                        reuseCache: Bool, maximumPending: Int?) -> Submission {
        // Never invoke the lifecycle guard while holding the pipeline lock:
        // capture teardown has a separate state owner.
        guard isCurrent() else { return .inactive }
        let admission = stateLock.withLock { state -> (Submission, CVPixelBuffer?) in
            guard state.active else { return (.inactive, nil) }
            if let maximumPending, state.pendingFrames >= maximumPending {
                return (.skipped, nil)
            }
            guard let buffer = image ?? (reuseCache ? state.cachedImage : nil) else {
                return (.empty, nil)
            }
            if let image { state.cachedImage = image }
            state.pendingFrames += 1
            return (image == nil ? .cached : .image, buffer)
        }
        guard let buffer = admission.1 else { return admission.0 }
        queue.async { [self] in
            defer { stateLock.withLock { $0.pendingFrames -= 1 } }
            guard canEncode else { return }
            encode(buffer, timestamp, false)
        }
        return admission.0
    }

    @discardableResult
    func replayCachedFrame(timestamp: CMTime) -> Bool {
        guard isCurrent() else { return false }
        let image = stateLock.withLock { $0.active ? $0.cachedImage : nil }
        guard let image else { return false }
        queue.async { [self] in
            guard canEncode else { return }
            // The sink forces the keyframe immediately before this submission,
            // on the same lane as normal frames, so another frame cannot steal it.
            encode(image, timestamp, true)
        }
        return true
    }

    private var canEncode: Bool {
        let active = stateLock.withLock { $0.active }
        return active && isCurrent()
    }
}
