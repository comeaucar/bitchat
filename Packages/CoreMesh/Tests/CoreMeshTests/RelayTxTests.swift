import XCTest
@testable import CoreMesh

final class RelayTxTests: XCTestCase {

    func testIdDeterministicAndUnique() {
        let keyPair = CryptoCurve25519.Signing.PrivateKey()
        let hA = CryptoSHA256.hash(data: Data([0x01]))
        let hB = CryptoSHA256.hash(data: Data([0x02]))

        let tx1 = RelayTx(parents: [hA, hB], feePerHop: 42, senderPub: keyPair.publicKey)
        let tx2 = RelayTx(parents: [hA, hB], feePerHop: 42, senderPub: keyPair.publicKey)
        XCTAssertEqual(tx1.id, tx2.id, "same fields ⇒ same id")

        let tx3 = RelayTx(parents: [hB, hA], feePerHop: 42, senderPub: keyPair.publicKey)
        XCTAssertNotEqual(tx1.id, tx3.id, "different parent order ⇒ different id")
    }
}
