import Foundation
import Darwin

struct USBChargingCommandResult: Sendable {
    enum Failure: Sendable { case launch, timeout, cancelled, outputLimit }
    var status: Int32
    var output: String
    var failure: Failure?
    var succeeded: Bool { failure == nil && status == 0 }
}

protocol USBChargingCommandRunning: Sendable {
    func run(_ arguments: [String]) async -> USBChargingCommandResult
}

/// Runs only its owned child. Pipe reads never block, including when a child
/// leaves a descendant holding a pipe open after the child has exited.
struct USBChargingProcessRunner: USBChargingCommandRunning {
    let executable: @Sendable () -> String?
    var timeout: TimeInterval = 8
    var outputLimit = 256 * 1024

    func run(_ arguments: [String]) async -> USBChargingCommandResult {
        guard let path = executable() else {
            return .init(status: -1, output: "", failure: .launch)
        }
        let operation = Operation(path: path, arguments: arguments,
                                  timeout: timeout, limit: outputLimit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: operation.execute())
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let timeout: TimeInterval
        private let limit: Int
        private var failure: USBChargingCommandResult.Failure?
        private var output = Data()
        private var finished = false
        private var launched = false

        init(path: String, arguments: [String], timeout: TimeInterval, limit: Int) {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            self.timeout = timeout
            self.limit = limit
        }

        func cancel() {
            lock.lock()
            if failure == nil { failure = .cancelled }
            if launched && process.isRunning { process.terminate() }
            lock.unlock()
        }

        func execute() -> USBChargingCommandResult {
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            lock.lock()
            if failure != nil {
                lock.unlock()
                closePipes()
                return .init(status: -1, output: "", failure: .cancelled)
            }
            do {
                try process.run()
                launched = true
            } catch {
                lock.unlock()
                closePipes()
                return .init(status: -1, output: "", failure: .launch)
            }
            lock.unlock()
            // Foundation retains the parent's write handles; close those so EOF
            // is observable once the child closes its corresponding descriptors.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            let readers = DispatchGroup()
            for pipe in [stdout, stderr] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    self.drain(pipe.fileHandleForReading.fileDescriptor)
                    readers.leave()
                }
            }
            let deadline = DispatchTime.now() + max(0, timeout)
            var didExit = false
            while DispatchTime.now() < deadline {
                if exited.wait(timeout: min(deadline, .now() + 0.05)) == .success {
                    didExit = true
                    break
                }
                lock.lock()
                let shouldStop = failure != nil
                lock.unlock()
                if shouldStop { break }
            }
            if !didExit {
                lock.lock()
                if failure == nil { failure = .timeout }
                if process.isRunning { process.terminate() }
                lock.unlock()
                if exited.wait(timeout: .now() + 0.25) == .timedOut {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 0.25)
                }
            }
            lock.lock()
            finished = true
            lock.unlock()
            readers.wait()
            closePipes()
            lock.lock()
            let result = USBChargingCommandResult(
                status: process.isRunning ? -1 : process.terminationStatus,
                output: String(decoding: output, as: UTF8.self), failure: failure)
            lock.unlock()
            return result
        }

        private func drain(_ descriptor: Int32) {
            let flags = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    lock.lock()
                    let remaining = max(0, limit - output.count)
                    output.append(contentsOf: bytes.prefix(min(count, remaining)))
                    if count > remaining && failure == nil {
                        failure = .outputLimit
                        if process.isRunning { process.terminate() }
                    }
                    let stopReading = finished && output.count >= limit
                    lock.unlock()
                    if stopReading { return }
                    continue
                }
                if count == 0 { return }
                if errno != EAGAIN && errno != EINTR { return }
                lock.lock()
                let done = finished
                lock.unlock()
                if done { return }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        private func closePipes() {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
    }
}

struct USBChargingDevice: Equatable, Sendable {
    let serial: String
    let transport: String
}

struct USBChargingPort: Equatable, Sendable {
    let id: String
    let power: String
    let data: String
    let canChangePower: Bool
    let supportsSinkDevice: Bool
    let sourcePower: Bool?
    let sinkPower: Bool?

    var canRecover: Bool {
        power == "source" && data == "device" && canChangePower && supportsSinkDevice
    }
    var receivesPower: Bool {
        power == "sink" && data == "device" && sourcePower == false && sinkPower == true
    }
}

/// Only parses explicit physical USB transports and the real port's status.
/// Role combinations are capabilities, never the current power direction.
enum USBChargingParser {
    static func devices(_ output: String) -> [USBChargingDevice]? {
        var result: [USBChargingDevice] = []
        var physicalSerials = Set<String>()
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.contains(where: { $0.hasPrefix("usb:") }) else { continue }
            guard fields.count >= 3, fields[1] == "device",
                  physicalSerials.insert(fields[0]).inserted else { return nil }
            let transports = fields.filter { $0.hasPrefix("transport_id:") }
            guard transports.count == 1 else { return nil }
            let transport = String(transports[0].dropFirst("transport_id:".count))
            guard !transport.isEmpty, transport.utf8.allSatisfy({ (48...57).contains($0) }),
                  UInt64(transport) != nil else { return nil }
            result.append(.init(serial: fields[0], transport: transport))
        }
        return result
    }

    static func port(_ output: String) -> USBChargingPort? {
        guard let region = section("port_manager", in: output),
              let tree = Dump.parse(region), tree.scalar("is_simulation_active") == "false"
        else { return nil }
        let entries = tree.objectsWithFields("port", "status")
        guard !entries.isEmpty else { return nil }
        var connected: [USBChargingPort] = []
        for entry in entries {
            guard let identity = entry.object("port"), let status = entry.object("status"),
                  let isConnected = status.scalar("connected"),
                  isConnected == "true" || isConnected == "false" else { return nil }
            if isConnected == "false" { continue }
            guard let id = identity.scalar("id"), !id.isEmpty,
                  id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || [95, 45, 46, 58].contains($0) }),
                  let power = status.scalar("power_role"), ["source", "sink"].contains(power),
                  let data = status.scalar("data_role"), ["host", "device"].contains(data),
                  status.scalar("current_mode") == (data == "device" ? "ufp" : "dfp"),
                  let changeable = entry.scalar("can_change_power_role"),
                  changeable == "true" || changeable == "false" else { return nil }
            let combinations = status.values("role_combinations").flatMap { $0.allObjects }
            let supported = combinations.contains {
                $0.scalar("power_role") == "sink" && $0.scalar("data_role") == "device"
            }
            connected.append(.init(id: id, power: power, data: data,
                                   canChangePower: changeable == "true",
                                   supportsSinkDevice: supported,
                                   sourcePower: flag("source_power", in: output),
                                   sinkPower: flag("sink_power", in: output)))
        }
        return connected.count == 1 ? connected[0] : nil
    }

    static func incomingBattery(_ output: String) -> Bool {
        let ac = scalarLine("AC powered", separator: ":", in: output)
        let usb = scalarLine("USB powered", separator: ":", in: output)
        let status = scalarLine("status", separator: ":", in: output)
        return (ac == "true" || usb == "true") && (status == "2" || status == "5")
    }

    private static func flag(_ key: String, in output: String) -> Bool? {
        switch scalarLine(key, separator: "=", in: output) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func scalarLine(_ key: String, separator: String, in output: String) -> String? {
        let values = output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: Character(separator), maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return parts.count == 2 && parts[0] == key ? parts[1] : nil
        }
        return values.count == 1 ? values[0] : nil
    }

    private static func section(_ key: String, in output: String) -> String? {
        let expression = try! NSRegularExpression(pattern: "(?m)^\\s*" + key + "\\s*=\\s*\\{")
        let range = NSRange(output.startIndex..., in: output)
        let matches = expression.matches(in: output, range: range)
        guard matches.count == 1, let matched = Range(matches[0].range, in: output),
              let start = output[matched].lastIndex(of: "{") else { return nil }
        var depth = 0
        for index in output[start...].indices {
            if output[index] == "{" { depth += 1 }
            if output[index] == "}" {
                depth -= 1
                if depth == 0 { return String(output[start...index]) }
            }
        }
        return nil
    }

    private indirect enum Dump {
        case scalar(String), object([(String, Dump)]), list([Dump])

        func values(_ name: String) -> [Dump] {
            guard case let .object(fields) = self else { return [] }
            return fields.filter { $0.0 == name }.map(\.1)
        }
        func scalar(_ name: String) -> String? {
            let values = values(name)
            guard values.count == 1, case let .scalar(value) = values[0] else { return nil }
            return value
        }
        func object(_ name: String) -> Dump? {
            let values = values(name)
            guard values.count == 1, case .object = values[0] else { return nil }
            return values[0]
        }
        var allObjects: [Dump] {
            switch self {
            case .scalar: return []
            case let .list(items): return items.flatMap(\.allObjects)
            case let .object(fields): return [self] + fields.flatMap { $0.1.allObjects }
            }
        }
        func objectsWithFields(_ first: String, _ second: String) -> [Dump] {
            allObjects.filter { $0.object(first) != nil && $0.object(second) != nil }
        }
        static func parse(_ text: String) -> Dump? {
            let regex = try! NSRegularExpression(pattern: "[A-Za-z0-9_.:/+-]+|[={}\\[\\]]")
            let tokens = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
            var position = 0
            func value() -> Dump? {
                guard position < tokens.count else { return nil }
                let token = tokens[position]
                position += 1
                if token == "{" {
                    var fields: [(String, Dump)] = []
                    while position < tokens.count && tokens[position] != "}" {
                        let key = tokens[position]
                        position += 1
                        guard position < tokens.count, tokens[position] == "=" else { return nil }
                        position += 1
                        guard let child = value() else { return nil }
                        fields.append((key, child))
                    }
                    guard position < tokens.count else { return nil }
                    position += 1
                    return .object(fields)
                }
                if token == "[" {
                    var items: [Dump] = []
                    while position < tokens.count && tokens[position] != "]" {
                        guard let child = value() else { return nil }
                        items.append(child)
                    }
                    guard position < tokens.count else { return nil }
                    position += 1
                    return .list(items)
                }
                guard !["=", "}", "]"].contains(token) else { return nil }
                return .scalar(token)
            }
            guard let result = value(), position == tokens.count else { return nil }
            return result
        }
    }
}

@MainActor
final class USBChargingRecovery {
    private let runner: any USBChargingCommandRunning
    private let onStatus: (String) -> Void
    private let onSelection: (String) -> Void
    private let settleDelay: UInt64
    private let bridgeRetryDelay: UInt64
    private let onBridgeStatus: (Bool) -> Void
    private let bridgeAllowed: (UInt16) -> Bool
    private var enabled = false
    private var eligible = false
    private var selectedSerial: String?
    private var stopped = false
    private var generation = 0
    private var job: Task<Bool, Never>?
    private var jobBridgePort: UInt16?
    private var attachment: USBChargingDevice?
    private var attempted = false
    private var mayBind = false

    convenience init(adbPath: @escaping @Sendable () -> String?,
                     onStatus: @escaping (String) -> Void,
                     onSelection: @escaping (String) -> Void,
                     onBridgeStatus: @escaping (Bool) -> Void = { _ in },
                     bridgeAllowed: @escaping (UInt16) -> Bool = { _ in true }) {
        self.init(runner: USBChargingProcessRunner(executable: adbPath),
                  onStatus: onStatus, onSelection: onSelection,
                  onBridgeStatus: onBridgeStatus, bridgeAllowed: bridgeAllowed)
    }

    init(runner: any USBChargingCommandRunning, settleDelay: UInt64 = 250_000_000,
         bridgeRetryDelay: UInt64 = 1_000_000_000,
         onStatus: @escaping (String) -> Void = { _ in },
         onSelection: @escaping (String) -> Void = { _ in },
         onBridgeStatus: @escaping (Bool) -> Void = { _ in },
         bridgeAllowed: @escaping (UInt16) -> Bool = { _ in true }) {
        self.onBridgeStatus = onBridgeStatus
        self.bridgeAllowed = bridgeAllowed
        self.runner = runner
        self.settleDelay = settleDelay
        self.bridgeRetryDelay = bridgeRetryDelay
        self.onStatus = onStatus
        self.onSelection = onSelection
    }

    func configure(enabled: Bool, selectedSerial: String?, eligible: Bool) {
        guard self.enabled != enabled || self.selectedSerial != selectedSerial ||
                self.eligible != eligible else { return }
        let reenabled = !self.enabled && enabled
        invalidate()
        if reenabled || (self.selectedSerial != selectedSerial && selectedSerial != nil) {
            attachment = nil
            attempted = false
        }
        mayBind = reenabled && selectedSerial == nil
        self.enabled = enabled
        self.selectedSerial = selectedSerial
        self.eligible = eligible
        stopped = false
        if !enabled { onStatus("Automatic charging recovery is off.") }
    }

    func poll(bridgePort: UInt16?) {
        guard enabled, eligible, !stopped, job == nil else { return }
        launch(bridgePort: bridgePort, ordinaryBridge: false)
    }

    /// Shares the owned command lane with charging work. If settings change while
    /// waiting, an old caller cannot restart cancelled bridge work.
    func ensureBridge(port: UInt16) async -> Bool {
        let ticket = generation
        while let current = job {
            let coversRequest = jobBridgePort == port
            let result = await current.value
            guard active(ticket), bridgeAllowed(port) else { return false }
            if coversRequest { return result }
        }
        guard eligible, !stopped, !Task.isCancelled else { return false }
        launch(bridgePort: port, ordinaryBridge: !enabled)
        guard let current = job else { return false }
        return await current.value
    }

    /// Await the owned lane, including cancellation cleanup, without starting work.
    func waitUntilIdle() async {
        while let current = job { _ = await current.value }
    }

    func invalidate() {
        generation += 1
        job?.cancel()
        jobBridgePort = nil
        // Keep the job reference until its child has terminated. A new generation
        // cannot overlap an old subprocess merely because cancellation was sent.
    }

    func stop() {
        invalidate()
        stopped = true
    }

    private func launch(bridgePort: UInt16?, ordinaryBridge: Bool) {
        guard job == nil else { return }
        let ticket = generation
        jobBridgePort = bridgePort
        job = Task { [weak self] in
            guard let self else { return false }
            let result: Bool
            if ordinaryBridge, let port = bridgePort {
                result = await self.bridge([], port: port, ticket: ticket)
            } else {
                result = await self.recover(bridgePort: bridgePort, ticket: ticket)
            }
            self.job = nil
            self.jobBridgePort = nil
            return result
        }
    }

    private func active(_ ticket: Int) -> Bool {
        ticket == generation && !stopped && eligible && !Task.isCancelled
    }

    private func command(_ arguments: [String], ticket: Int) async -> USBChargingCommandResult? {
        guard active(ticket) else { return nil }
        let result = await runner.run(arguments)
        return active(ticket) ? result : nil
    }

    private func target(ticket: Int) async -> USBChargingDevice? {
        guard let result = await command(["devices", "-l"], ticket: ticket), result.succeeded,
              let devices = USBChargingParser.devices(result.output) else {
            if selectedSerial == nil { mayBind = false }
            if active(ticket) { onStatus("Unable to identify the selected USB tablet.") }
            return nil
        }
        if selectedSerial == nil {
            guard mayBind else {
                onStatus("Connect only your tablet, then turn this option off and on.")
                return nil
            }
            mayBind = false
            guard devices.count == 1 else {
                onStatus("Connect only your tablet, then turn this option off and on.")
                return nil
            }
            selectedSerial = devices[0].serial
            onSelection(devices[0].serial)
            guard active(ticket) else { return nil }
        }
        guard let device = devices.first(where: { $0.serial == selectedSerial }) else {
            attachment = nil
            attempted = false
            onStatus("Waiting for the selected USB tablet.")
            return nil
        }
        if attachment != device {
            attachment = device
            attempted = false
        }
        return device
    }

    private func stillAttached(_ device: USBChargingDevice, ticket: Int) async -> Bool {
        guard let result = await command(["devices", "-l"], ticket: ticket), result.succeeded,
              let devices = USBChargingParser.devices(result.output), devices.contains(device)
        else { return false }
        return true
    }

    private func readPort(_ device: USBChargingDevice, ticket: Int) async -> USBChargingPort? {
        guard let result = await command(["-t", device.transport, "shell", "dumpsys", "usb"],
                                         ticket: ticket), result.succeeded else { return nil }
        return USBChargingParser.port(result.output)
    }

    private func recover(bridgePort: UInt16?, ticket: Int) async -> Bool {
        guard enabled, let device = await target(ticket: ticket) else {
            if let bridgePort, active(ticket), bridgeAllowed(bridgePort) { onBridgeStatus(false) }
            return false
        }
        let chargingReady = await correctPower(device, ticket: ticket)
        guard let bridgePort else { return chargingReady }
        guard bridgeAllowed(bridgePort) else { return false }
        var ready = false
        if await stillAttached(device, ticket: ticket) {
            ready = await bridge(["-t", device.transport], port: bridgePort,
                                 ticket: ticket, device: device)
        }
        if active(ticket), bridgeAllowed(bridgePort) { onBridgeStatus(ready) }
        return ready
    }

    private func correctPower(_ device: USBChargingDevice, ticket: Int) async -> Bool {
        let prefix = ["-t", device.transport]
        guard let port = await readPort(device, ticket: ticket) else {
            if active(ticket) { onStatus("USB power state is unavailable; no change made.") }
            return false
        }
        if port.power == "sink" && port.data == "device" {
            let verified = await verifyIncoming(port, device: device, ticket: ticket)
            if active(ticket) {
                onStatus(verified ? "Tablet is receiving power from Mac." :
                         "Tablet is set to receive power; incoming power is not verified.")
            }
            return verified
        }
        if attempted {
            // A later source role is observable, but a tick must not become an
            // unbounded retry loop on the same physical attachment.
            onStatus("Tablet is set to supply power; reconnect or re-enable to retry.")
            return false
        }
        if port.canRecover {
            guard await stillAttached(device, ticket: ticket), active(ticket) else { return false }
            attempted = true
            onStatus("Switching tablet to receive power from Mac…")
            guard let result = await command(prefix + ["shell", "dumpsys", "usb",
                        "set-port-roles", port.id, "sink", "device"], ticket: ticket),
                  result.succeeded else {
                if active(ticket) { onStatus("Charging recovery failed; reconnect or re-enable to retry.") }
                return false
            }
            var verified = false
            for index in 0..<5 {
                if index > 0 {
                    do { try await Task.sleep(nanoseconds: settleDelay) }
                    catch { return false }
                }
                guard await stillAttached(device, ticket: ticket) else { return false }
                guard let updated = await readPort(device, ticket: ticket), updated.id == port.id
                else { continue }
                if await verifyIncoming(updated, device: device, ticket: ticket) {
                    verified = true
                    break
                }
            }
            guard active(ticket) else { return false }
            onStatus(verified ? "Tablet is receiving power from Mac." :
                     "Incoming power was not verified; reconnect or re-enable to retry.")
            guard verified else { return false }
        } else {
            onStatus("USB role is unsupported or unsafe; no change made.")
            return false
        }
        return true
    }

    private func verifyIncoming(_ port: USBChargingPort, device: USBChargingDevice,
                                ticket: Int) async -> Bool {
        guard port.receivesPower,
              let battery = await command(["-t", device.transport, "shell", "dumpsys", "battery"],
                                          ticket: ticket), battery.succeeded,
              USBChargingParser.incomingBattery(battery.output) else { return false }
        return await stillAttached(device, ticket: ticket)
    }

    private func bridge(_ prefix: [String], port: UInt16, ticket: Int,
                        device: USBChargingDevice? = nil) async -> Bool {
        guard bridgeAllowed(port) else { return false }
        let mapping = "tcp:\(port)"
        if let device {
            guard await stillAttached(device, ticket: ticket) else { return false }
            guard let existing = await command(prefix + ["reverse", "--list"], ticket: ticket),
                  existing.succeeded, bridgeAllowed(port) else { return false }
            let present = existing.output.split(separator: "\n").contains { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count == 3 && fields[1] == mapping && fields[2] == mapping
            }
            if present { return true }
        }
        for index in 0..<3 {
            if index > 0 {
                do { try await Task.sleep(nanoseconds: bridgeRetryDelay) }
                catch { return false }
            }
            guard bridgeAllowed(port) else { return false }
            if let device {
                guard await stillAttached(device, ticket: ticket), bridgeAllowed(port) else { return false }
            }
            guard let result = await command(prefix + ["reverse", mapping, mapping], ticket: ticket)
            else { return false }
            guard bridgeAllowed(port) else { return false }
            if result.succeeded { return true }
        }
        return false
    }
}
