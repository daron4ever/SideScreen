import XCTest
@testable import SideScreen

final class USBChargingProcessBoundaryTests: XCTestCase {
    func testDrainsStdoutAndStderrBeforeEitherPipeFills() async {
        let runner = makeRunner(timeout: 3, outputLimit: 512 * 1024)
        let script = """
        i=0
        while [ "$i" -lt 4096 ]; do
            printf 'stdout-0123456789abcdef\\n'
            printf 'stderr-0123456789abcdef\\n' >&2
            i=$((i + 1))
        done
        printf 'stdout-finished\\n'
        printf 'stderr-finished\\n' >&2
        """

        let result = await runner.run(["-c", script])

        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.output.contains("stdout-finished"))
        XCTAssertTrue(result.output.contains("stderr-finished"))
        XCTAssertGreaterThan(result.output.utf8.count, 128 * 1024)
    }

    func testCombinedOutputCeilingStopsAProducingProcess() async {
        let limit = 4096
        let runner = makeRunner(timeout: 3, outputLimit: limit)
        let script = """
        i=0
        while [ "$i" -lt 16384 ]; do
            printf 'stdout-0123456789abcdef\\n'
            printf 'stderr-0123456789abcdef\\n' >&2
            i=$((i + 1))
        done
        """
        let started = DispatchTime.now().uptimeNanoseconds

        let result = await runner.run(["-c", script])

        XCTAssertEqual(result.failure, .outputLimit)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThanOrEqual(result.output.utf8.count, limit)
        XCTAssertLessThan(elapsed(since: started), 1.5)
    }

    func testMalformedStandardOutputFailsEvenWhenTheProcessExitsSuccessfully() async {
        let runner = makeRunner(timeout: 3)

        let result = await runner.run(["-c", "printf '\\377'"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.failure, .invalidOutput)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "")
    }

    func testMalformedStandardErrorFailsEvenWhenTheProcessExitsSuccessfully() async {
        let runner = makeRunner(timeout: 3)

        let result = await runner.run(["-c", "printf 'valid stdout'; printf '\\377' >&2"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.failure, .invalidOutput)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "")
    }

    func testMultibyteScalarsSplitAcrossReadsStayWithinTheirOwnPipe() async {
        let runner = makeRunner(timeout: 3)
        let script = """
        i=0
        while [ "$i" -lt 4095 ]; do
            printf 'o'
            i=$((i + 1))
        done
        printf '\\342'
        i=0
        while [ "$i" -lt 4095 ]; do
            printf 'e' >&2
            i=$((i + 1))
        done
        printf '\\360' >&2
        /bin/sleep 0.05
        printf '\\202\\254'
        printf '\\237\\230\\200' >&2
        """
        let expectedOutput = String(repeating: "o", count: 4095) + "€"
        let expectedError = String(repeating: "e", count: 4095) + "😀"

        let result = await runner.run(["-c", script])

        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.output, expectedOutput + expectedError)
    }

    func testOutputCeilingKeepsPriorityWhenItTruncatesAMultibyteScalar() async {
        let runner = makeRunner(timeout: 3, outputLimit: 2)

        let result = await runner.run(["-c", "printf '\\342\\202\\254'"])

        XCTAssertEqual(result.failure, .outputLimit)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "")
    }

    func testDeadlineKeepsPriorityWhenOutputEndsWithAnIncompleteScalar() async {
        let runner = makeRunner(timeout: 0.15)

        let result = await runner.run(["-c", "printf '\\342'; exec /bin/sleep 3"])

        XCTAssertEqual(result.failure, .timeout)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "")
    }

    func testCancellationKeepsPriorityWhenOutputEndsWithAnIncompleteScalar() async throws {
        let runner = makeRunner(timeout: 3)
        let operation = Task {
            await runner.run(["-c", "printf '\\342'; exec /bin/sleep 3"])
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        operation.cancel()
        let result = await operation.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.output, "")
    }

    func testDeadlineTerminatesAnOwnedProcess() async {
        let runner = makeRunner(timeout: 0.15)
        let started = DispatchTime.now().uptimeNanoseconds

        let result = await runner.run(["-c", "exec /bin/sleep 3"])

        XCTAssertEqual(result.failure, .timeout)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed(since: started), 1.5)
    }

    func testCancellationFinishesBeforeTheCommandDeadline() async throws {
        let runner = makeRunner(timeout: 3)
        let operation = Task { await runner.run(["-c", "exec /bin/sleep 3"]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let cancelledAt = DispatchTime.now().uptimeNanoseconds

        operation.cancel()
        let result = await operation.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed(since: cancelledAt), 1.5)
    }

    func testDeadlineEscalatesWhenTheOwnedProcessIgnoresTermination() async {
        let runner = makeRunner(timeout: 0.15)
        let started = DispatchTime.now().uptimeNanoseconds

        let result = await runner.run(["-c", ignoresTerminationScript])

        XCTAssertEqual(result.failure, .timeout)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.output.contains("termination-ignored"))
        XCTAssertLessThan(elapsed(since: started), 1.5)
    }

    func testCancellationEscalatesWithoutWaitingForTheCommandDeadline() async throws {
        let runner = makeRunner(timeout: 3)
        let script = ignoresTerminationScript
        let operation = Task { await runner.run(["-c", script]) }
        try await Task.sleep(nanoseconds: 250_000_000)
        let cancelledAt = DispatchTime.now().uptimeNanoseconds

        operation.cancel()
        let result = await operation.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.output.contains("termination-ignored"))
        XCTAssertLessThan(elapsed(since: cancelledAt), 1.5)
    }

    func testParentExitDoesNotWaitForADescendantToCloseInheritedPipes() async {
        let runner = makeRunner(timeout: 0.2)
        let script = """
        (/bin/sleep 2) &
        printf 'parent-exited\\n'
        exit 0
        """
        let started = DispatchTime.now().uptimeNanoseconds

        let result = await runner.run(["-c", script])

        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.output.contains("parent-exited"))
        XCTAssertLessThan(elapsed(since: started), 1.5)
    }

    private var ignoresTerminationScript: String {
        """
        trap '' TERM
        printf 'termination-ignored\\n'
        exec /bin/sleep 3
        """
    }

    private func makeRunner(
        timeout: TimeInterval,
        outputLimit: Int = 256 * 1024
    ) -> USBChargingProcessRunner {
        USBChargingProcessRunner(executable: { "/bin/sh" }, timeout: timeout,
                                 outputLimit: outputLimit)
    }

    private func elapsed(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}
