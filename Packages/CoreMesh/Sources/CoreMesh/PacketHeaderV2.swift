import Foundation

/// Binary layout:
/// 0  : UInt8   version  (always 0x02)
/// 1  : UInt8   ttl
/// 2-5: UInt32  feePerHop  (little-endian, µRLT)
/// 6-37: [UInt8]  txHash  (32-byte SHA-256 digest)
public struct BitChatHeaderV2: Equatable {

    public static let version: UInt8 = 0x02
    public static let byteCount = 1 + 1 + 4 + 32        // = 38

    public var ttl: UInt8
    public var feePerHop: UInt32
    public var txHash: [UInt8]          // must be exactly 32 bytes

    public init(ttl: UInt8, feePerHop: UInt32, txHash: [UInt8]) {
        precondition(txHash.count == 32, "txHash must be 32 bytes")
        self.ttl = ttl
        self.feePerHop = feePerHop
        self.txHash = txHash
    }

    /// Serialise to a fixed-length Data blob.
    public func encode() -> Data {
        var buffer = Data(capacity: Self.byteCount)
        buffer.append(Self.version)
        buffer.append(ttl)
        var feeLE = feePerHop.littleEndian
        withUnsafeBytes(of: &feeLE) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: txHash)
        return buffer
    }

    /// Parse from Data starting at offset 0.
    public static func decode(_ data: Data) throws -> BitChatHeaderV2 {
        guard data.count >= byteCount else { throw DecodingError.short }
        guard data[0] == version else { throw DecodingError.badVersion }

        let ttl = data[1]
        let fee = UInt32(littleEndian: data.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self) })
        let hash = Array(data[6..<38])
        return .init(ttl: ttl, feePerHop: fee, txHash: hash)
    }

    public enum DecodingError: Error { case short, badVersion }
}
