import Foundation

#if canImport(CryptoKit)
import CryptoKit               // iOS / macOS
typealias CryptoSHA256 = CryptoKit.SHA256
typealias CryptoCurve25519 = CryptoKit.Curve25519
#else
import Crypto                  // Windows / Linux
typealias CryptoSHA256 = Crypto.SHA256
typealias CryptoCurve25519 = Crypto.Curve25519
#endif

/// Convenience so callers don’t worry which backend we’re using
typealias SHA256Digest = CryptoSHA256.Digest

/// Minimal representation of a relay transaction (no signature yet).
struct RelayTx: Equatable, Hashable {

    let parents: [SHA256Digest]                    // 2 tips
    let feePerHop: UInt32                          // µRLT
    let senderPub: CryptoCurve25519.Signing.PublicKey

    init(parents: [SHA256Digest],
                feePerHop: UInt32,
                senderPub: CryptoCurve25519.Signing.PublicKey)
    {
        precondition(parents.count == 2, "exactly two parents required")
        self.parents   = parents
        self.feePerHop = feePerHop
        self.senderPub = senderPub
    }

    /// Deterministic hash over immutable fields.
    var id: SHA256Digest {
        var blob = Data()
        parents.forEach { blob.append(contentsOf: $0) }
        var leFee = feePerHop.littleEndian
        withUnsafeBytes(of: &leFee) { blob.append(contentsOf: $0) }
        blob.append(senderPub.rawRepresentation)
        return CryptoSHA256.hash(data: blob)
    }

    // MARK: - Equatable / Hashable conformance
    static func == (lhs: RelayTx, rhs: RelayTx) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
