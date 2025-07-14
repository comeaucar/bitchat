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

/// Enhanced header with Proof of Work support for spam protection
/// Binary layout:
/// 0    : UInt8   version  (always 0x03)
/// 1    : UInt8   ttl
/// 2-5  : UInt32  feePerHop  (little-endian, µRLT)
/// 6-37 : [UInt8] txHash  (32-byte SHA-256 digest)
/// 38   : UInt8   powDifficulty (0 = no PoW required)
/// 39-46: UInt64  powNonce (little-endian)
/// 47-78: [UInt8] powHash (32-byte SHA-256 digest, only if powDifficulty > 0)
public struct BitChatHeaderV3: Equatable {
    
    public static let version: UInt8 = 0x03
    public static let baseByteCount = 1 + 1 + 4 + 32 + 1 + 8 + 32  // = 79
    
    public var ttl: UInt8
    public var feePerHop: UInt32
    public var txHash: [UInt8]          // must be exactly 32 bytes
    public var powDifficulty: UInt8     // 0 = no PoW, >0 = required leading zeros
    public var powNonce: UInt64         // nonce used for PoW
    public var powHash: [UInt8]         // 32-byte PoW hash result
    
    public init(ttl: UInt8, feePerHop: UInt32, txHash: [UInt8], powDifficulty: UInt8 = 0, powNonce: UInt64 = 0, powHash: [UInt8] = Array(repeating: 0, count: 32)) {
        precondition(txHash.count == 32, "txHash must be 32 bytes")
        precondition(powHash.count == 32, "powHash must be 32 bytes")
        self.ttl = ttl
        self.feePerHop = feePerHop
        self.txHash = txHash
        self.powDifficulty = powDifficulty
        self.powNonce = powNonce
        self.powHash = powHash
    }
    
    /// Initialize from V2 header with no PoW
    public init(from v2Header: BitChatHeaderV2) {
        self.ttl = v2Header.ttl
        self.feePerHop = v2Header.feePerHop
        self.txHash = v2Header.txHash
        self.powDifficulty = 0
        self.powNonce = 0
        self.powHash = Array(repeating: 0, count: 32)
    }
    
    /// Check if this packet requires Proof of Work
    public var requiresProofOfWork: Bool {
        return powDifficulty > 0
    }
    
    /// Serialize to a fixed-length Data blob
    public func encode() -> Data {
        var buffer = Data(capacity: Self.baseByteCount)
        buffer.append(Self.version)
        buffer.append(ttl)
        var feeLE = feePerHop.littleEndian
        withUnsafeBytes(of: &feeLE) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: txHash)
        buffer.append(powDifficulty)
        var nonceLE = powNonce.littleEndian
        withUnsafeBytes(of: &nonceLE) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: powHash)
        return buffer
    }
    
    /// Parse from Data starting at offset 0
    public static func decode(_ data: Data) throws -> BitChatHeaderV3 {
        guard data.count >= baseByteCount else { throw DecodingError.short }
        guard data[0] == version else { throw DecodingError.badVersion }
        
        let ttl = data[1]
        let fee = UInt32(littleEndian: data.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self) })
        let hash = Array(data[6..<38])
        let powDifficulty = data[38]
        let powNonce = UInt64(littleEndian: data.subdata(in: 39..<47).withUnsafeBytes { $0.load(as: UInt64.self) })
        let powHash = Array(data[47..<79])
        
        return BitChatHeaderV3(
            ttl: ttl,
            feePerHop: fee,
            txHash: hash,
            powDifficulty: powDifficulty,
            powNonce: powNonce,
            powHash: powHash
        )
    }
    
    /// Convert to legacy V2 header (loses PoW information)
    public func toV2Header() -> BitChatHeaderV2 {
        return BitChatHeaderV2(ttl: ttl, feePerHop: feePerHop, txHash: txHash)
    }
    
    public enum DecodingError: Error { case short, badVersion }
}
