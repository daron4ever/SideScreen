import XCTest
import os
@testable import SideScreen

final class FrameStageCountersTests: XCTestCase {
    func testCumulativeCountsAndReportThrottle() {
        var lines: [String] = []
        let counters = FrameStageCounters(stage: .capture, started: 0) { lines.append($0) }
        counters.record(.callbacks, also: .images, at: 100)
        counters.record(.callbacks, also: .skipped, at: 999_999_999)
        XCTAssertTrue(lines.isEmpty)
        counters.record(.callbacks, also: .cached, at: 1_000_000_000)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("callbacks=3 images=1 cached=1 skipped=1 empty=0"))
        counters.record(.callbacks, also: .empty, at: 1_000_000_001)
        counters.record(.callbacks, also: .images, at: 2_000_000_000)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("callbacks=5 images=2 cached=1 skipped=1 empty=1"))
    }

    func testOutOfOrderClockDoesNotUnderflowOrEmitEarly() {
        var lines: [String] = []
        let counters = FrameStageCounters(stage: .encoder, started: 100) { lines.append($0) }
        counters.record(.submissions, at: 1_000_000_100)
        counters.record(.submitErrors, at: 99)
        XCTAssertEqual(lines.count, 1)
        counters.record(.submissions, at: 2_000_000_100)
        XCTAssertTrue(lines[1].contains("submissions=2 submitErrors=1"))
    }

    func testReplacementAndLateEventsKeepSeparateIdentities() {
        var lines: [String] = []
        let old = FrameStageCounters(stage: .encoder, started: 10) { lines.append($0) }
        let new = FrameStageCounters(stage: .encoder, started: 20) { lines.append($0) }
        old.record(.submissions, at: 100)
        new.record(.submissions, at: 1_000_000_020)
        old.record(.outputCallbacks, also: .encoded, at: 1_000_000_030)
        XCTAssertTrue(lines[0].contains("stage=2 id=20"))
        XCTAssertTrue(lines[0].contains("encoded=0"))
        XCTAssertTrue(lines[1].contains("stage=2 id=10"))
        XCTAssertTrue(lines[1].contains("encoded=1"))
    }

    func testConcurrentEventsAreNotLost() {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let counters = FrameStageCounters(stage: .encoder, started: 0) { line in
            lines.withLock { $0.append(line) }
        }
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            counters.record(.outputCallbacks, also: .encoded, at: 100)
        }
        counters.record(.submissions, at: 1_000_000_000)
        let report = lines.withLock { $0 }
        XCTAssertEqual(report.count, 1)
        XCTAssertTrue(report[0].contains("outputCallbacks=10000"))
        XCTAssertTrue(report[0].contains("encoded=10000"))
    }
}
