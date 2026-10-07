import XCTest
@testable import SideScreen

final class HighRefreshCodecLimitsTests: XCTestCase {
    private let native = (width: 2800, height: 1752)

    func testNative120SizeAndPortraitRemainExact() {
        let budget = CodecLimits.negotiatedBudget(legacy: native, highRefresh: native, forFps: 120)!
        XCTAssertEqual(budget.width, 2800)
        XCTAssertEqual(budget.height, 1752)
        let portrait = CodecLimits.clampToClientLimit(width: 1752, height: 2800, limit: budget)
        XCTAssertEqual(portrait.width, 1752)
        XCTAssertEqual(portrait.height, 2800)
    }

    func testLegacy120StillShrinksToExistingStreamSize() {
        let budget = CodecLimits.negotiatedBudget(legacy: native, highRefresh: nil, forFps: 120)!
        let result = CodecLimits.clampToClientLimit(width: 2800, height: 1752, limit: budget)
        XCTAssertEqual(result.width, 1968)
        XCTAssertEqual(result.height, 1216)
    }

    func testOtherRatesRetainLegacyBehavior() {
        for fps in [30, 60, 90, 144] {
            let old = CodecLimits.scaleLimit(native, forFps: fps)
            let result = CodecLimits.negotiatedBudget(legacy: native, highRefresh: native, forFps: fps)!
            XCTAssertEqual(result.width, old.width)
            XCTAssertEqual(result.height, old.height)
        }
    }

    func testSmallerVerified120LimitIsRespected() {
        let limit = (width: 1920, height: 1200)
        let result = CodecLimits.negotiatedBudget(legacy: native, highRefresh: limit, forFps: 120)!
        XCTAssertEqual(result.width, limit.width)
        XCTAssertEqual(result.height, limit.height)
    }

    func testAbsentCapabilitiesPreserveLegacyFallback() {
        XCTAssertNil(CodecLimits.negotiatedBudget(legacy: nil, highRefresh: nil, forFps: 120))
        XCTAssertNil(CodecLimits.negotiatedBudget(legacy: nil, highRefresh: native, forFps: 60))
    }

    func testCrossPlatformPayloadAndDuplicateDecode() {
        for _ in 0..<2 {
            let result = CodecLimits.decodeAdvertisedLimit([0x95, 0xF0, 0x8D, 0xD8])!
            XCTAssertEqual(result.width, 2800)
            XCTAssertEqual(result.height, 1752)
        }
    }

    func testMalformedPartialAndOutOfRangePayloads() {
        let payload: [UInt8] = [0x95, 0xF0, 0x8D, 0xD8]
        for count in 0..<4 {
            XCTAssertNil(CodecLimits.decodeAdvertisedLimit(Array(payload.prefix(count))))
        }
        XCTAssertNil(CodecLimits.decodeAdvertisedLimit(payload + [0x80]))
        XCTAssertNil(CodecLimits.decodeAdvertisedLimit([0x15, 0xF0, 0x8D, 0xD8]))
        XCTAssertNil(CodecLimits.decodeAdvertisedLimit([0x80, 0xFF, 0x8D, 0xD8]))
        let maximum = CodecLimits.decodeAdvertisedLimit([0xFF, 0xFF, 0xFF, 0xFF])!
        XCTAssertEqual(maximum.width, 16383)
        XCTAssertEqual(maximum.height, 16383)
    }
}
