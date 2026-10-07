import Foundation
import CoreMedia
import CoreVideo
import os
import XCTest
@testable import SideScreen

final class CaptureFramePipelineTests: XCTestCase {
    private struct EncodedFrame {
        let image: CVPixelBuffer
        let timestamp: CMTime
        let replay: Bool
    }

    private final class Fixture {
        let lifecycle = OSAllocatedUnfairLock(initialState: CaptureSleepLifecycle())
        let encoded = OSAllocatedUnfairLock(initialState: [EncodedFrame]())
        let queue = DispatchQueue(label: "CaptureFramePipelineTests.encode")

        func pipeline(generation: UInt64, queue: DispatchQueue? = nil) -> CaptureFramePipeline {
            let lifecycle = lifecycle
            let encoded = encoded
            return CaptureFramePipeline(
                queue: queue ?? self.queue,
                isCurrent: { lifecycle.withLock { $0.permitsCapture(generation) } },
                encode: { image, timestamp, replay in
                    encoded.withLock { $0.append(.init(image: image, timestamp: timestamp, replay: replay)) }
                }
            )
        }

        var frames: [EncodedFrame] { encoded.withLock { $0 } }
    }

    private enum TestError: Error { case cannotCreatePixelBuffer }

    private func image() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        XCTAssertEqual(result, kCVReturnSuccess)
        guard let buffer else { throw TestError.cannotCreatePixelBuffer }
        return buffer
    }

    private func timestamp(_ value: Int64) -> CMTime {
        CMTime(value: value, timescale: 1_000)
    }

    private func drain(_ queue: DispatchQueue) {
        let complete = DispatchSemaphore(value: 0)
        queue.async { complete.signal() }
        XCTAssertEqual(complete.wait(timeout: .now() + 2), .success)
    }

    private func block(_ queue: DispatchQueue) -> DispatchSemaphore {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        return release
    }

    func testFallbackImageThenIdleCanReplayAKeyframeWithoutNewImage() throws {
        let fixture = Fixture()
        let generation = fixture.lifecycle.withLock { $0.start() }
        let pipeline = fixture.pipeline(generation: generation)
        let first = try image()

        XCTAssertEqual(pipeline.submitFallbackFrame(first, timestamp: timestamp(1)), .image)
        drain(fixture.queue)
        XCTAssertEqual(pipeline.submitFallbackFrame(nil, timestamp: timestamp(2)), .empty)
        XCTAssertEqual(pipeline.submitFallbackFrame(nil, timestamp: timestamp(3)), .empty)
        XCTAssertTrue(pipeline.hasCachedImage)
        XCTAssertTrue(pipeline.replayCachedFrame(timestamp: timestamp(4)))
        drain(fixture.queue)

        XCTAssertEqual(fixture.frames.count, 2)
        guard fixture.frames.count == 2 else { return }
        XCTAssertTrue(fixture.frames[0].image === first)
        XCTAssertFalse(fixture.frames[0].replay)
        XCTAssertTrue(fixture.frames[1].image === first)
        XCTAssertTrue(fixture.frames[1].replay)
        XCTAssertEqual(fixture.frames[1].timestamp.value, 4)
    }

    func testFallbackNormalFramesAndForcedReplayUseTheSameOrderedLane() throws {
        let fixture = Fixture()
        let generation = fixture.lifecycle.withLock { $0.start() }
        let pipeline = fixture.pipeline(generation: generation)
        let first = try image()
        let second = try image()
        let third = try image()
        let release = block(fixture.queue)
        defer { release.signal() }

        XCTAssertEqual(pipeline.submitFallbackFrame(first, timestamp: timestamp(1)), .image)
        XCTAssertEqual(pipeline.submitFallbackFrame(second, timestamp: timestamp(2)), .image)
        XCTAssertTrue(pipeline.replayCachedFrame(timestamp: timestamp(3)))
        XCTAssertEqual(pipeline.submitFallbackFrame(third, timestamp: timestamp(4)), .image)
        release.signal()
        drain(fixture.queue)

        XCTAssertEqual(fixture.frames.count, 4)
        guard fixture.frames.count == 4 else { return }
        XCTAssertEqual(fixture.frames.map { $0.timestamp.value }, [1, 2, 3, 4])
        XCTAssertEqual(fixture.frames.map { $0.replay }, [false, false, true, false])
        XCTAssertTrue(fixture.frames[2].image === second)
    }

    func testSleepRejectsQueuedFallbackFramesReplayAndLateImages() throws {
        let fixture = Fixture()
        let generation = fixture.lifecycle.withLock { $0.start() }
        let pipeline = fixture.pipeline(generation: generation)
        let first = try image()
        let release = block(fixture.queue)
        defer { release.signal() }
        XCTAssertEqual(pipeline.submitFallbackFrame(first, timestamp: timestamp(1)), .image)
        XCTAssertTrue(pipeline.replayCachedFrame(timestamp: timestamp(2)))

        fixture.lifecycle.withLock { $0.setDisplayAwake(false) }
        pipeline.invalidate()
        XCTAssertFalse(pipeline.hasCachedImage)
        XCTAssertEqual(pipeline.submitFallbackFrame(first, timestamp: timestamp(3)), .inactive)
        XCTAssertFalse(pipeline.replayCachedFrame(timestamp: timestamp(4)))
        release.signal()
        drain(fixture.queue)
        XCTAssertEqual(fixture.frames.count, 0)
    }

    func testStopRejectsReplayOfAnAlreadyEncodedFallbackImage() throws {
        let fixture = Fixture()
        let generation = fixture.lifecycle.withLock { $0.start() }
        let pipeline = fixture.pipeline(generation: generation)
        let first = try image()
        XCTAssertEqual(pipeline.submitFallbackFrame(first, timestamp: timestamp(1)), .image)
        drain(fixture.queue)
        let release = block(fixture.queue)
        defer { release.signal() }
        XCTAssertTrue(pipeline.replayCachedFrame(timestamp: timestamp(2)))

        fixture.lifecycle.withLock { $0.stop() }
        pipeline.invalidate()
        XCTAssertFalse(pipeline.hasCachedImage)
        XCTAssertFalse(pipeline.replayCachedFrame(timestamp: timestamp(3)))
        release.signal()
        drain(fixture.queue)
        XCTAssertEqual(fixture.frames.count, 1)
        guard fixture.frames.count == 1 else { return }
        XCTAssertFalse(fixture.frames[0].replay)
    }

    func testOldGenerationCannotPopulateOrReplayTheNewGenerationsCache() throws {
        let fixture = Fixture()
        let oldGeneration = fixture.lifecycle.withLock { $0.start() }
        let retiring = fixture.pipeline(generation: oldGeneration)
        let oldImage = try image()
        let release = block(fixture.queue)
        defer { release.signal() }
        XCTAssertEqual(retiring.submitFallbackFrame(oldImage, timestamp: timestamp(1)), .image)
        XCTAssertTrue(retiring.replayCachedFrame(timestamp: timestamp(2)))

        let generation = fixture.lifecycle.withLock { $0.beginRecovery()! }
        let newQueue = DispatchQueue(label: "CaptureFramePipelineTests.newGeneration")
        let current = fixture.pipeline(generation: generation, queue: newQueue)
        XCTAssertEqual(retiring.submitFallbackFrame(oldImage, timestamp: timestamp(3)), .inactive)
        XCTAssertEqual(retiring.submitScreenFrame(oldImage, timestamp: timestamp(4)), .inactive)
        XCTAssertFalse(retiring.replayCachedFrame(timestamp: timestamp(5)))
        XCTAssertFalse(current.hasCachedImage)
        XCTAssertFalse(current.replayCachedFrame(timestamp: timestamp(6)))
        let newImage = try image()
        XCTAssertEqual(current.submitFallbackFrame(newImage, timestamp: timestamp(7)), .image)
        drain(newQueue)
        release.signal()
        drain(fixture.queue)

        XCTAssertEqual(fixture.frames.count, 1)
        guard fixture.frames.count == 1 else { return }
        XCTAssertTrue(fixture.frames[0].image === newImage)
        XCTAssertEqual(fixture.frames[0].timestamp.value, 7)
    }

    func testExplicitRetirementRejectsCallbacksEvenBeforeLifecycleChanges() throws {
        let fixture = Fixture()
        let generation = fixture.lifecycle.withLock { $0.start() }
        let pipeline = fixture.pipeline(generation: generation)
        let first = try image()
        let release = block(fixture.queue)
        defer { release.signal() }
        XCTAssertEqual(pipeline.submitScreenFrame(first, timestamp: timestamp(1)), .image)
        XCTAssertTrue(pipeline.replayCachedFrame(timestamp: timestamp(2)))
        pipeline.invalidate()
        XCTAssertEqual(pipeline.submitScreenFrame(first, timestamp: timestamp(3)), .inactive)
        XCTAssertFalse(pipeline.hasCachedImage)
        XCTAssertFalse(pipeline.replayCachedFrame(timestamp: timestamp(4)))
        release.signal()
        drain(fixture.queue)
        XCTAssertEqual(fixture.frames.count, 0)
    }

    func testScreenCaptureKeepsItsTwoPendingFrameLimitAndCachedSampleBehavior() throws {
        let fixture = Fixture()
        let generation = fixture.lifecycle.withLock { $0.start() }
        let pipeline = fixture.pipeline(generation: generation)
        let first = try image()
        let second = try image()
        let skipped = try image()
        let release = block(fixture.queue)
        defer { release.signal() }

        XCTAssertEqual(pipeline.submitScreenFrame(first, timestamp: timestamp(1)), .image)
        XCTAssertEqual(pipeline.submitScreenFrame(second, timestamp: timestamp(2)), .image)
        XCTAssertEqual(pipeline.submitScreenFrame(skipped, timestamp: timestamp(3)), .skipped)
        XCTAssertTrue(pipeline.replayCachedFrame(timestamp: timestamp(4)))
        release.signal()
        drain(fixture.queue)
        XCTAssertEqual(pipeline.submitScreenFrame(nil, timestamp: timestamp(5)), .cached)
        drain(fixture.queue)

        XCTAssertEqual(fixture.frames.count, 4)
        guard fixture.frames.count == 4 else { return }
        XCTAssertTrue(fixture.frames[2].image === second)
        XCTAssertTrue(fixture.frames[2].replay)
        XCTAssertTrue(fixture.frames[3].image === second)
        XCTAssertFalse(fixture.frames[3].replay)
    }
}
