import XCTest
import ScreenCaptureKit
@testable import SideScreen

@MainActor
final class ScreenRecordingPermissionTests: XCTestCase {
    func testPassiveChecksNeverRequestAndObserveGrantAndRevocation() {
        var granted = false
        var requests = 0
        let state = ScreenRecordingPermission(preflight: { granted }, requestAccess: {
            requests += 1
            return false
        })
        XCTAssertFalse(state.refresh())
        granted = true
        XCTAssertTrue(state.refresh())
        granted = false
        XCTAssertFalse(state.refresh())
        XCTAssertEqual(requests, 0)
    }

    func testExistingGrantDoesNotPrompt() {
        var requests = 0
        let state = ScreenRecordingPermission(preflight: { true }, requestAccess: {
            requests += 1
            return true
        })
        XCTAssertTrue(state.request())
        XCTAssertEqual(requests, 0)
    }

    func testDeniedRequestIsNotRepeatedDuringLaunch() {
        var requests = 0
        let state = ScreenRecordingPermission(preflight: { false }, requestAccess: {
            requests += 1
            return false
        })
        XCTAssertFalse(state.request())
        XCTAssertFalse(state.request())
        XCTAssertEqual(requests, 1)
    }

    func testGrantInSettingsAfterDenialIsObservedWithoutAnotherRequest() {
        var granted = false
        var requests = 0
        let state = ScreenRecordingPermission(preflight: { granted }, requestAccess: {
            requests += 1
            return false
        })
        XCTAssertFalse(state.request())
        granted = true
        XCTAssertTrue(state.refresh())
        XCTAssertTrue(state.request())
        XCTAssertEqual(requests, 1)
    }

    func testRequestUsesCurrentPreflightNotRequestReturnValue() {
        let state = ScreenRecordingPermission(preflight: { false }, requestAccess: { true })
        XCTAssertFalse(state.request())
    }

    func testReentrantRequestDoesNotPromptTwice() {
        var requests = 0
        var nestedRequest: (() -> Void)?
        let state = ScreenRecordingPermission(preflight: { false }, requestAccess: {
            requests += 1
            nestedRequest?()
            return false
        })
        nestedRequest = { XCTAssertFalse(state.request()) }
        XCTAssertFalse(state.request())
        XCTAssertEqual(requests, 1)
        nestedRequest = nil
    }

    func testOnlyScreenCaptureAuthorizationDenialStopsRecovery() {
        XCTAssertTrue(isScreenRecordingPermissionDenied(NSError(
            domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)))
        XCTAssertFalse(isScreenRecordingPermissionDenied(NSError(
            domain: "Network", code: SCStreamError.Code.userDeclined.rawValue)))
        XCTAssertFalse(isScreenRecordingPermissionDenied(NSError(
            domain: SCStreamErrorDomain, code: -3802)))
    }
}
