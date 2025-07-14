import XCTest
@testable import CoreMesh

final class PacketHeaderV2Tests: XCTestCase {

    func testRoundTrip() throws {
        let hash = [UInt8](repeating: 0xAB, count: 32)
        let original = BitChatHeaderV2(ttl: 7, feePerHop: 123_456, txHash: hash)

        let bytes = original.encode()
        XCTAssertEqual(bytes.count, BitChatHeaderV2.byteCount)

        let decoded = try BitChatHeaderV2.decode(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testBadVersionFails() {
        let hash = [UInt8](repeating: 0, count: 32)
        var bytes = BitChatHeaderV2(ttl: 1, feePerHop: 1, txHash: hash).encode()
        bytes[0] = 0x99                                  // corrupt version byte

        XCTAssertThrowsError(try BitChatHeaderV2.decode(bytes)) { error in
            XCTAssertEqual(error as? BitChatHeaderV2.DecodingError, .badVersion)
        }
    }
}
