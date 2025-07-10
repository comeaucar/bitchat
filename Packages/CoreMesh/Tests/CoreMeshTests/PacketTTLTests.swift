import XCTest
@testable import CoreMesh

final class PacketTTLTests: XCTestCase {

    private func makePacket(ttl: UInt8) -> Data {
        let header = BitChatHeaderV2(
            ttl: ttl,
            feePerHop: 0,
            txHash: [UInt8](repeating: 0, count: 32)
        ).encode()
        // body not important for this test
        return header + Data([0xFF, 0xFF])
    }

    func testDecrementSuccess() throws {
        let p1 = makePacket(ttl: 3)
        let p2 = try PacketTTL.decrement(in: p1)

        XCTAssertEqual(p2[1], 2)
        // original untouched
        XCTAssertEqual(p1[1], 3)
    }

    func testDecrementThrowsWhenZero() {
        let p = makePacket(ttl: 0)
        XCTAssertThrowsError(try PacketTTL.decrement(in: p)) { error in
            XCTAssertEqual(error as? PacketTTL.Error, .ttlExpired)
        }
    }
}
