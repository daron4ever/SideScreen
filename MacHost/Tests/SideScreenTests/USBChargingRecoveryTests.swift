import XCTest
@testable import SideScreen

private func usbDevices(_ transport: String = "7", serial: String = "tablet") -> String {
    "List of devices attached\n\(serial) device usb:1-2 product:synthetic transport_id:\(transport)\n"
}

private func usbPort(power: String = "source", flags: Bool = false,
                     simulation: Bool = false, extraPort: Bool = false) -> String {
    let entry = """
      ports={
        port={
          id=port0
          supported_modes=dual
        }
        status={
          connected=true
          current_mode=ufp
          power_role=\(power)
          data_role=device
          role_combinations=[
            { power_role=source data_role=host }
            { power_role=source data_role=device }
            { power_role=sink data_role=host }
            { power_role=sink data_role=device }
          ]
        }
        can_change_mode=true
        can_change_power_role=true
        can_change_data_role=true
      }
    """
    return """
    device_manager={
      source_power=\(!flags)
      sink_power=\(flags)
    }
    port_manager={
      is_simulation_active=\(simulation)
    \(entry)
    \(extraPort ? entry.replacingOccurrences(of: "port0", with: "port1") : "")
    }
    """
}

private let poweredFull = "AC powered: true\nUSB powered: false\nstatus: 5\nlevel: 100\n"

private actor ChargingRunner: USBChargingCommandRunning {
    var calls: [[String]] = []
    var devices = usbDevices()
    var power = "source"
    var incoming = false
    var battery = poweredFull
    var failWrite = false
    var mapping = ""
    var pauseNextDump = false
    var dumpEntered = false
    var dumpGate: CheckedContinuation<Void, Never>?
    var dumpWaiters: [CheckedContinuation<Void, Never>] = []
    var transportAfterDump: String?
    var settlingReads = 0
    var reverseFailures = 0
    var pauseNextReverse = false
    var reverseEntered = false
    var reverseGate: CheckedContinuation<Void, Never>?
    var reverseWaiters: [CheckedContinuation<Void, Never>] = []
    var active = 0
    var peakActive = 0

    func setDevices(_ value: String) { devices = value }
    func setFailWrite() { failWrite = true }
    func setMapping(_ value: String) { mapping = value }
    func holdDump() { pauseNextDump = true; dumpEntered = false }
    func waitForDump() async {
        if dumpEntered { return }
        await withCheckedContinuation { dumpWaiters.append($0) }
    }
    func releaseDump() { dumpGate?.resume(); dumpGate = nil }
    func replaceAfterDump(_ transport: String) { transportAfterDump = transport }
    func setPower(_ value: String, incoming: Bool) { power = value; self.incoming = incoming }
    func setSettlingReads(_ value: Int) { settlingReads = value }
    func setBattery(_ value: String) { battery = value }
    func setReverseFailures(_ value: Int) { reverseFailures = value }
    func holdReverse() { pauseNextReverse = true; reverseEntered = false }
    func waitForReverse() async {
        if reverseEntered { return }
        await withCheckedContinuation { reverseWaiters.append($0) }
    }
    func releaseReverse() { reverseGate?.resume(); reverseGate = nil }

    func run(_ arguments: [String]) async -> USBChargingCommandResult {
        calls.append(arguments)
        active += 1
        peakActive = max(active, peakActive)
        defer { active -= 1 }
        if arguments == ["devices", "-l"] { return ok(devices) }
        if arguments.suffix(3) == ["shell", "dumpsys", "usb"] {
            dumpEntered = true
            let waiters = dumpWaiters
            dumpWaiters = []
            for waiter in waiters { waiter.resume() }
            if pauseNextDump {
                pauseNextDump = false
                await withCheckedContinuation { dumpGate = $0 }
            }
            if Task.isCancelled { return .init(status: -1, output: "", failure: .cancelled) }
            let value = usbPort(power: power, flags: incoming && settlingReads == 0)
            if settlingReads > 0 { settlingReads -= 1 }
            if let transportAfterDump {
                devices = usbDevices(transportAfterDump)
                self.transportAfterDump = nil
            }
            return ok(value)
        }
        if arguments.contains("set-port-roles") {
            if failWrite { return .init(status: 1, output: "", failure: nil) }
            power = "sink"
            incoming = true
            return ok("")
        }
        if arguments.suffix(3) == ["shell", "dumpsys", "battery"] { return ok(battery) }
        if arguments.suffix(2) == ["reverse", "--list"] { return ok(mapping) }
        if arguments.contains("reverse") {
            reverseEntered = true
            let waiters = reverseWaiters
            reverseWaiters = []
            for waiter in waiters { waiter.resume() }
            if pauseNextReverse {
                pauseNextReverse = false
                await withCheckedContinuation { reverseGate = $0 }
            }
            if Task.isCancelled { return .init(status: -1, output: "", failure: .cancelled) }
            if reverseFailures > 0 {
                reverseFailures -= 1
                return .init(status: 1, output: "", failure: nil)
            }
            mapping = "target tcp:54321 tcp:54321\n"
            return ok("")
        }
        return .init(status: 1, output: "unexpected command", failure: nil)
    }
    private func ok(_ value: String) -> USBChargingCommandResult {
        .init(status: 0, output: value, failure: nil)
    }
    func writes() -> [[String]] { calls.filter { $0.contains("set-port-roles") } }
    func reverseWrites() -> [[String]] {
        calls.filter { $0.contains("reverse") && !$0.contains("--list") }
    }
}

@MainActor
final class USBChargingRecoveryTests: XCTestCase {
    private func settled(_ engine: USBChargingRecovery) async {
        await engine.waitUntilIdle()
    }

    private func engine(_ runner: ChargingRunner, enabled: Bool = true,
                        status: @escaping (String) -> Void = { _ in }) -> USBChargingRecovery {
        let engine = USBChargingRecovery(runner: runner, settleDelay: 1_000_000, bridgeRetryDelay: 1_000_000, onStatus: status)
        engine.configure(enabled: enabled, selectedSerial: "tablet", eligible: true)
        return engine
    }

    func testParserUsesActualStatusNotLastCapability() {
        let port = USBChargingParser.port(usbPort())
        XCTAssertEqual(port?.power, "source")
        XCTAssertEqual(port?.data, "device")
        XCTAssertTrue(port?.canRecover == true)
        XCTAssertFalse(port?.receivesPower == true)
    }

    func testParserRejectsSimulationAmbiguousAndUnknownPorts() {
        XCTAssertNil(USBChargingParser.port(usbPort(simulation: true)))
        XCTAssertNil(USBChargingParser.port(usbPort(extraPort: true)))
        XCTAssertNil(USBChargingParser.port(usbPort().replacingOccurrences(
            of: "current_mode=ufp", with: "current_mode=dfp")))
        XCTAssertNil(USBChargingParser.port(usbPort().replacingOccurrences(
            of: "current_mode=ufp", with: "current_mode=unknown")))
        XCTAssertNil(USBChargingParser.port(usbPort().replacingOccurrences(
            of: "can_change_power_role=true", with: "can_change_power_role=unknown")))
        XCTAssertNil(USBChargingParser.port(usbPort().replacingOccurrences(
            of: "power_role=source\n", with: "power_role=unknown\n")))
        XCTAssertNil(USBChargingParser.port(usbPort().replacingOccurrences(
            of: "is_simulation_active=false", with: "is_simulation_active=true\nis_simulation_active=false")))
    }

    func testParserHandlesRepeatedRoleCombinationObjects() {
        let input = usbPort().replacingOccurrences(of: "role_combinations=[", with: "role_combinations={")
            .replacingOccurrences(of: "{ power_role=source data_role=host }", with: "power_role=sink data_role=device")
            .replacingOccurrences(of: "{ power_role=source data_role=device }", with: "")
            .replacingOccurrences(of: "{ power_role=sink data_role=host }", with: "")
            .replacingOccurrences(of: "{ power_role=sink data_role=device }", with: "")
            .replacingOccurrences(of: "]", with: "}")
        XCTAssertTrue(USBChargingParser.port(input)?.canRecover == true)
    }

    func testDeviceSelectionRequiresPhysicalTransportAndUniqueMetadata() {
        let wireless = "wireless:5555 device product:synthetic transport_id:9\n"
        XCTAssertEqual(USBChargingParser.devices(wireless), [])
        XCTAssertEqual(USBChargingParser.devices(wireless + usbDevices()),
                       [USBChargingDevice(serial: "tablet", transport: "7")])
        XCTAssertNil(USBChargingParser.devices(usbDevices() + usbDevices()))
        XCTAssertNil(USBChargingParser.devices(usbDevices().replacingOccurrences(of: "transport_id:7", with: "")))
        XCTAssertNil(USBChargingParser.devices(usbDevices().replacingOccurrences(of: " device ", with: " unauthorized ")))
    }

    func testFullBatteryAndACIncomingAreValid() {
        XCTAssertTrue(USBChargingParser.incomingBattery(poweredFull))
        XCTAssertFalse(USBChargingParser.incomingBattery("AC powered: false\nUSB powered: false\nstatus: 5"))
        XCTAssertFalse(USBChargingParser.incomingBattery("AC powered: true\nstatus: 3"))
    }

    func testDefaultOffNeverPollsOrChangesPower() async {
        let runner = ChargingRunner()
        let engine = engine(runner, enabled: false)
        engine.poll(bridgePort: 54321)
        await settled(engine)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
        let observed1 = await engine.ensureBridge(port: 54321)
        XCTAssertTrue(observed1)
        let writes = await runner.writes()
        XCTAssertTrue(writes.isEmpty)
        let reverse = await runner.reverseWrites()
        XCTAssertEqual(reverse, [["reverse", "tcp:54321", "tcp:54321"]])
    }

    func testSourceRecoversOnceAndFullBatteryVerifies() async {
        let runner = ChargingRunner()
        var status = ""
        let engine = engine(runner) { status = $0 }
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertEqual(status, "Tablet is receiving power from Mac.")
        engine.poll(bridgePort: nil)
        await settled(engine)
        let writes = await runner.writes()
        XCTAssertEqual(writes, [["-t", "7", "shell", "dumpsys", "usb", "set-port-roles", "port0", "sink", "device"]])
    }

    func testAlreadySinkIsNoOpAndBridgePreservesOtherMappings() async {
        let runner = ChargingRunner()
        await runner.setPower("sink", incoming: true)
        await runner.setMapping("target tcp:31416 tcp:31416\n")
        let engine = engine(runner)
        let observed2 = await engine.ensureBridge(port: 54321)
        XCTAssertTrue(observed2)
        let writes = await runner.writes()
        XCTAssertTrue(writes.isEmpty)
        let reverses = await runner.reverseWrites()
        XCTAssertEqual(reverses, [["-t", "7", "reverse", "tcp:54321", "tcp:54321"]])
        let observed3 = await engine.ensureBridge(port: 54321)
        XCTAssertTrue(observed3)
        let finalReverses = await runner.reverseWrites()
        XCTAssertEqual(finalReverses.count, 1)
    }

    func testFailedAttemptLatchesAcrossTicksAndSleepButReenableRetries() async {
        let runner = ChargingRunner()
        await runner.setFailWrite()
        let engine = engine(runner)
        engine.poll(bridgePort: nil)
        await settled(engine)
        engine.invalidate()
        engine.poll(bridgePort: nil)
        await settled(engine)
        engine.configure(enabled: true, selectedSerial: "tablet", eligible: false)
        engine.configure(enabled: true, selectedSerial: "tablet", eligible: true)
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed4 = await runner.writes().count
        XCTAssertEqual(observed4, 1)
        engine.configure(enabled: false, selectedSerial: nil, eligible: true)
        engine.configure(enabled: true, selectedSerial: "tablet", eligible: true)
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed5 = await runner.writes().count
        XCTAssertEqual(observed5, 2)
    }

    func testDetachAndNewTransportPermitNewAttempt() async {
        let runner = ChargingRunner()
        await runner.setFailWrite()
        let engine = engine(runner)
        engine.poll(bridgePort: nil)
        await settled(engine)
        await runner.setDevices("List of devices attached\n")
        engine.poll(bridgePort: nil)
        await settled(engine)
        await runner.setDevices(usbDevices("8"))
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed6 = await runner.writes().map { $0[1] }
        XCTAssertEqual(observed6, ["7", "8"])
    }

    func testReplacedTransportBeforeMutationIsRejected() async {
        let runner = ChargingRunner()
        await runner.replaceAfterDump("8")
        let engine = engine(runner)
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed7 = await runner.writes().isEmpty
        XCTAssertTrue(observed7)
    }

    func testOptOutCancelsBeforeMutationAndSingleFlightNeverOverlaps() async {
        let runner = ChargingRunner()
        await runner.holdDump()
        let engine = engine(runner)
        engine.poll(bridgePort: nil)
        engine.poll(bridgePort: nil)
        await runner.waitForDump()
        engine.configure(enabled: false, selectedSerial: nil, eligible: true)
        await runner.releaseDump()
        let observed8 = await engine.ensureBridge(port: 54321)
        XCTAssertTrue(observed8)
        let observed9 = await runner.writes().isEmpty
        XCTAssertTrue(observed9)
        let observed10 = await runner.peakActive
        XCTAssertEqual(observed10, 1)
    }

    func testStopKeepsChargingIndependentOfStreamingButQuitStopsIt() async {
        let runner = ChargingRunner()
        let engine = engine(runner)
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed11 = await runner.writes().count
        XCTAssertEqual(observed11, 1)
        engine.stop()
        await runner.setDevices(usbDevices("8"))
        await runner.setPower("source", incoming: false)
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed12 = await runner.writes().count
        XCTAssertEqual(observed12, 1)
    }

    func testDelayedPowerFlagsSettleAndUnpoweredFullDoesNotVerify() async {
        let runner = ChargingRunner()
        await runner.setSettlingReads(3)
        var status = ""
        let engine = engine(runner) { status = $0 }
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertEqual(status, "Tablet is receiving power from Mac.")
        engine.configure(enabled: false, selectedSerial: nil, eligible: true)
        engine.configure(enabled: true, selectedSerial: "tablet", eligible: true)
        await runner.setPower("source", incoming: false)
        await runner.setBattery("AC powered: false\nUSB powered: false\nstatus: 5")
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertTrue(status.contains("not verified"))
        engine.poll(bridgePort: nil)
        await settled(engine)
        let observed13 = await runner.writes().count
        XCTAssertEqual(observed13, 2)
    }

    func testBindingOnlyOccursAtExplicitEnableAndCallbackIsReentrantSafe() async {
        let runner = ChargingRunner()
        await runner.setDevices(usbDevices() + usbDevices("8", serial: "other"))
        var selections: [String] = []
        var engine: USBChargingRecovery!
        engine = USBChargingRecovery(runner: runner, settleDelay: 1_000_000, bridgeRetryDelay: 1_000_000,
            onSelection: { serial in
                selections.append(serial)
                engine.configure(enabled: true, selectedSerial: serial, eligible: true)
            })
        engine.configure(enabled: true, selectedSerial: nil, eligible: true)
        engine.poll(bridgePort: nil)
        await settled(engine)
        await runner.setDevices(usbDevices())
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertTrue(selections.isEmpty)
        let observed14 = await runner.writes().isEmpty
        XCTAssertTrue(observed14)
        engine.configure(enabled: false, selectedSerial: nil, eligible: true)
        engine.configure(enabled: true, selectedSerial: nil, eligible: true)
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertEqual(selections, ["tablet"])
        let observed15 = await runner.writes().count
        XCTAssertEqual(observed15, 1)
    }

    func testLaterSourceOnSameAttachmentReportsChangedDirectionWithoutRepeatingWrite() async {
        let runner = ChargingRunner()
        var status = ""
        let engine = engine(runner) { status = $0 }
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertEqual(status, "Tablet is receiving power from Mac.")
        await runner.setPower("source", incoming: false)
        engine.poll(bridgePort: nil)
        await settled(engine)
        XCTAssertTrue(status.contains("set to supply power"))
        let writes = await runner.writes()
        XCTAssertEqual(writes.count, 1)
    }

    func testChargingFailureDoesNotBlockTargetedStreamingBridge() async {
        let runner = ChargingRunner()
        await runner.setFailWrite()
        var status = ""
        let engine = engine(runner) { status = $0 }
        let ready = await engine.ensureBridge(port: 54321)
        XCTAssertTrue(ready)
        XCTAssertTrue(status.contains("failed"))
        let writes = await runner.writes()
        XCTAssertEqual(writes.count, 1)
        let reverse = await runner.reverseWrites()
        XCTAssertEqual(reverse, [["-t", "7", "reverse", "tcp:54321", "tcp:54321"]])
    }

    func testBoundTargetNeverSubstitutesAnotherUSBOrWirelessDevice() async {
        let runner = ChargingRunner()
        await runner.setDevices(usbDevices("9", serial: "other") +
            "tablet:5555 device product:synthetic transport_id:7\n")
        let engine = engine(runner)
        let ready = await engine.ensureBridge(port: 54321)
        XCTAssertFalse(ready)
        let writes = await runner.writes()
        let reverse = await runner.reverseWrites()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(reverse.isEmpty)
    }

    func testStreamStopRevokesBridgeWorkWithoutCancellingCharging() async {
        let runner = ChargingRunner()
        await runner.holdDump()
        var allowBridge = true
        var bridgeReports: [Bool] = []
        let engine = USBChargingRecovery(runner: runner, settleDelay: 1_000_000, bridgeRetryDelay: 1_000_000,
            onBridgeStatus: { bridgeReports.append($0) }, bridgeAllowed: { _ in allowBridge })
        engine.configure(enabled: true, selectedSerial: "tablet", eligible: true)
        let request = Task { await engine.ensureBridge(port: 54321) }
        await runner.waitForDump()
        allowBridge = false
        await runner.releaseDump()
        let ready = await request.value
        XCTAssertFalse(ready)
        let writes = await runner.writes()
        let reverse = await runner.reverseWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(reverse.isEmpty)
        XCTAssertTrue(bridgeReports.isEmpty)
    }

    func testConcurrentIdenticalBridgeRequestsShareOneBoundedAttemptSequence() async {
        let runner = ChargingRunner()
        await runner.setReverseFailures(100)
        await runner.holdReverse()
        let engine = engine(runner, enabled: false)
        var started = 0
        let requests = (0..<12).map { _ in
            Task {
                started += 1
                return await engine.ensureBridge(port: 54321)
            }
        }
        await runner.waitForReverse()
        while started < requests.count { await Task.yield() }
        await runner.releaseReverse()
        for request in requests {
            let ready = await request.value
            XCTAssertFalse(ready)
        }
        let reverse = await runner.reverseWrites()
        XCTAssertEqual(reverse.count, 3)
        let peak = await runner.peakActive
        XCTAssertEqual(peak, 1)
    }

    func testDefaultOffLegacyBridgeRetriesThreeTimes() async {
        let runner = ChargingRunner()
        await runner.setReverseFailures(3)
        let engine = engine(runner, enabled: false)
        let observed16 = await engine.ensureBridge(port: 54321)
        XCTAssertFalse(observed16)
        let observed17 = await runner.reverseWrites().count
        XCTAssertEqual(observed17, 3)
    }
}
