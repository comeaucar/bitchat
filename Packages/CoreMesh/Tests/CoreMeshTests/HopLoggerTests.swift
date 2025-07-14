import XCTest
@testable import CoreMesh

final class HopLoggerTests: XCTestCase {

    func testHopCountsIncrementProperly() {
        let logger = HopLogger()
        let id = UUID()

        logger.recordHop(messageID: id)
        logger.recordHop(messageID: id)
        logger.recordHop(messageID: id)

        XCTAssertEqual(logger.hopCount(for: id), 3, "Should have counted exactly three hops")
    }

    func testUnknownMessageReturnsNil() {
        let logger = HopLogger()
        XCTAssertNil(logger.hopCount(for: UUID()))
    }
}
