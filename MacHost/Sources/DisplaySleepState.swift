import Foundation

/// Capture generations invalidate queued frames and recovery work on sleep or Stop.
/// ScreenCapture stores this value under its frame-state lock.
struct CaptureSleepLifecycle {
    private(set) var streaming = false
    private(set) var displayAwake = true
    private(set) var generation: UInt64 = 0

    mutating func start() -> UInt64 {
        streaming = true
        generation &+= 1
        return generation
    }

    mutating func stop() {
        streaming = false
        generation &+= 1
    }

    @discardableResult
    mutating func setDisplayAwake(_ awake: Bool) -> Bool {
        guard displayAwake != awake else { return false }
        displayAwake = awake
        generation &+= 1
        return true
    }

    mutating func beginRecovery() -> UInt64? {
        guard streaming && displayAwake else { return nil }
        generation &+= 1
        return generation
    }

    func permitsCapture(_ ticket: UInt64) -> Bool {
        streaming && displayAwake && ticket == generation
    }
}

/// System wake does not imply that the display has also woken.
struct HostDisplaySleepState {
    var systemAwake = true
    var displaysAwake: Bool
    var isAwake: Bool { systemAwake && displaysAwake }
}

/// The existing protocol is not length framed: new host messages require opt-in.
/// StreamingServer owns this value on its network queue.
struct HostDisplayStateMessage {
    static let capability: UInt8 = 15
    static let message: UInt8 = 16
    private(set) var awake: Bool
    private var supported = false
    private var ready = false

    init(awake: Bool) {
        self.awake = awake
    }

    mutating func resetConnection() {
        supported = false
        ready = false
    }

    mutating func advertiseSupport() -> Data? {
        guard !supported else { return nil }
        supported = true
        return packet
    }

    mutating func protocolStarted() -> Data? {
        ready = true
        return packet
    }

    mutating func setAwake(_ awake: Bool) -> Data? {
        guard self.awake != awake else { return nil }
        self.awake = awake
        return packet
    }

    private var packet: Data? {
        guard supported && ready else { return nil }
        return Data([Self.message, awake ? 1 : 0])
    }
}
