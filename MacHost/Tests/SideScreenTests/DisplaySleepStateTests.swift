import Foundation
import XCTest
@testable import SideScreen

final class DisplaySleepStateTests: XCTestCase {
    func testSleepInvalidatesQueuedFramesAndPreventsFallbackRecovery() {
        var state = CaptureSleepLifecycle()
        let frames = state.start()
        let recovery = state.beginRecovery()!
        XCTAssertFalse(state.permitsCapture(frames))
        XCTAssertTrue(state.permitsCapture(recovery))

        state.setDisplayAwake(false)
        XCTAssertFalse(state.permitsCapture(recovery))
        XCTAssertNil(state.beginRecovery())
    }

    func testStartWhileAsleepWaitsForWake() {
        var state = CaptureSleepLifecycle()
        state.setDisplayAwake(false)
        let initial = state.start()
        XCTAssertFalse(state.permitsCapture(initial))
        XCTAssertNil(state.beginRecovery())

        state.setDisplayAwake(true)
        let resumed = state.beginRecovery()!
        XCTAssertFalse(state.permitsCapture(initial))
        XCTAssertTrue(state.permitsCapture(resumed))
    }

    func testDuplicateWakeDoesNotSupersedePendingRecovery() {
        var state = CaptureSleepLifecycle()
        _ = state.start()
        state.setDisplayAwake(false)
        XCTAssertTrue(state.setDisplayAwake(true))
        let pendingWake = state.generation
        XCTAssertFalse(state.setDisplayAwake(true))
        XCTAssertTrue(state.permitsCapture(pendingWake))
    }

    func testSecondSleepInvalidatesDelayedWake() {
        var state = CaptureSleepLifecycle()
        _ = state.start()
        state.setDisplayAwake(false)
        state.setDisplayAwake(true)
        let pendingWake = state.generation
        state.setDisplayAwake(false)
        state.setDisplayAwake(true)
        XCTAssertFalse(state.permitsCapture(pendingWake))
        XCTAssertTrue(state.permitsCapture(state.generation))
    }

    func testStopThenWakeCannotRestartCapture() {
        var state = CaptureSleepLifecycle()
        _ = state.start()
        state.setDisplayAwake(false)
        state.setDisplayAwake(true)
        let pendingWake = state.generation
        state.stop()
        XCTAssertFalse(state.permitsCapture(pendingWake))
        XCTAssertNil(state.beginRecovery())
        state.setDisplayAwake(false)
        state.setDisplayAwake(true)
        XCTAssertNil(state.beginRecovery())
    }

    func testNewSessionDoesNotAcceptOldCaptureCompletion() {
        var state = CaptureSleepLifecycle()
        let oldCapture = state.start()
        state.stop()
        let newCapture = state.start()
        XCTAssertFalse(state.permitsCapture(oldCapture))
        XCTAssertTrue(state.permitsCapture(newCapture))
    }

    func testSystemSleepOverridesDisplayWakeAndSystemWakeKeepsDisplaySleep() {
        var state = HostDisplaySleepState(displaysAwake: true)
        state.systemAwake = false
        state.displaysAwake = true
        XCTAssertFalse(state.isAwake)
        state.displaysAwake = false
        state.systemAwake = true
        XCTAssertFalse(state.isAwake)
        state.displaysAwake = true
        XCTAssertTrue(state.isAwake)
    }

    func testLegacyClientReceivesNoNewPackets() {
        var state = HostDisplayStateMessage(awake: true)
        XCTAssertNil(state.protocolStarted())
        XCTAssertNil(state.setAwake(false))
        XCTAssertNil(state.setAwake(true))
    }

    func testStartupOptInReportsCurrentAsleepState() {
        var state = HostDisplayStateMessage(awake: true)
        XCTAssertNil(state.advertiseSupport())
        XCTAssertNil(state.setAwake(false))
        XCTAssertEqual(state.protocolStarted(), Data([16, 0]))
        XCTAssertEqual(state.setAwake(true), Data([16, 1]))
    }

    func testLateOptInReportsCurrentStateOnce() {
        var state = HostDisplayStateMessage(awake: true)
        XCTAssertNil(state.protocolStarted())
        XCTAssertNil(state.setAwake(false))
        XCTAssertEqual(state.advertiseSupport(), Data([16, 0]))
        XCTAssertNil(state.advertiseSupport())
        XCTAssertNil(state.setAwake(false))
    }

    func testReconnectionDoesNotInheritPreviousClientsCapability() {
        var state = HostDisplayStateMessage(awake: false)
        _ = state.advertiseSupport()
        XCTAssertEqual(state.protocolStarted(), Data([16, 0]))
        state.resetConnection()
        XCTAssertNil(state.setAwake(true))
        XCTAssertNil(state.protocolStarted())
        XCTAssertEqual(state.advertiseSupport(), Data([16, 1]))
    }

    func testConnectionResetPreventsMessagesBeforeNextProtocolStartup() {
        var state = HostDisplayStateMessage(awake: true)
        _ = state.advertiseSupport()
        _ = state.protocolStarted()
        state.resetConnection()
        XCTAssertNil(state.advertiseSupport())
        XCTAssertNil(state.setAwake(false))
        XCTAssertEqual(state.protocolStarted(), Data([16, 0]))
    }
}
