import Foundation
import os

/// Numeric-only cumulative diagnostics. Each capture handler/encoder owns its own
/// instance so late callbacks cannot be attributed to a replacement instance.
/// Reports are event-driven (no reports while idle), at most once per second.
final class FrameStageCounters {
    enum Stage: Int { case capture = 1, encoder = 2, fallback = 3 }
    enum Event: Int, CaseIterable {
        case callbacks, images, cached, skipped, empty, replay
        case submissions, submitErrors, missingSession
        case outputCallbacks, outputErrors, outputDropped, encoded
    }

    private struct State {
        var counts = Array(repeating: UInt64(0), count: Event.allCases.count)
        var lastReport: UInt64
    }

    private let state: OSAllocatedUnfairLock<State>
    private let stage: Stage
    private let started: UInt64
    private let emit: (String) -> Void

    init(stage: Stage, started: UInt64 = DispatchTime.now().uptimeNanoseconds,
         emit: @escaping (String) -> Void = debugLog) {
        self.stage = stage
        self.started = started
        self.emit = emit
        state = OSAllocatedUnfairLock(initialState: State(lastReport: started))
    }

    func record(_ event: Event, also second: Event? = nil,
                at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let counts = state.withLock { value -> [UInt64]? in
            value.counts[event.rawValue] += 1
            if let second { value.counts[second.rawValue] += 1 }
            // Concurrent callers can acquire the lock out of timestamp order.
            guard now >= value.lastReport, now - value.lastReport >= 1_000_000_000 else {
                return nil
            }
            value.lastReport = now
            return value.counts
        }
        guard let counts else { return }
        let fields = Event.allCases.map { "\($0)=\(counts[$0.rawValue])" }.joined(separator: " ")
        // Formatting and log I/O occur outside the counter lock. Consumers sort
        // by monotonic timestamp if concurrent report writes arrive out of order.
        emit("FrameStages: stage=\(stage.rawValue) id=\(started) t=\(now) \(fields)")
    }
}
