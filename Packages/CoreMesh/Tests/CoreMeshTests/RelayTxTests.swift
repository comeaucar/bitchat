import XCTest
#if canImport(CryptoKit)
import CryptoKit
typealias CryptoSHA256 = CryptoKit.SHA256
typealias CryptoCurve25519 = CryptoKit.Curve25519
#else
import Crypto
typealias CryptoSHA256 = Crypto.SHA256
typealias CryptoCurve25519 = Crypto.Curve25519
#endif

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
