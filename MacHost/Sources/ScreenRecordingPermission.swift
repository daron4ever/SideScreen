import Foundation
import ScreenCaptureKit

/// Permission checks never request access. Consent is a separate user action.
@MainActor
final class ScreenRecordingPermission {
    private(set) var isGranted = false
    private var requestInProgress = false
    private var didRequestThisLaunch = false
    private let preflight: () -> Bool
    private let requestAccess: () -> Bool

    init(preflight: @escaping () -> Bool, requestAccess: @escaping () -> Bool) {
        self.preflight = preflight
        self.requestAccess = requestAccess
    }

    @discardableResult
    func refresh() -> Bool {
        isGranted = preflight()
        return isGranted
    }

    @discardableResult
    func request() -> Bool {
        guard !requestInProgress else { return isGranted }
        guard !refresh() else { return true }
        guard !didRequestThisLaunch else { return false }
        requestInProgress = true
        didRequestThisLaunch = true
        defer { requestInProgress = false }
        _ = requestAccess()
        return refresh()
    }
}

func isScreenRecordingPermissionDenied(_ error: Error) -> Bool {
    let failure = error as NSError
    return failure.domain == SCStreamErrorDomain
        && failure.code == SCStreamError.Code.userDeclined.rawValue
}
