import Foundation

#if canImport(CryptoKit)
import CryptoKit
public typealias CryptoSHA256 = CryptoKit.SHA256
public typealias CryptoCurve25519 = CryptoKit.Curve25519
#else
import Crypto
public typealias CryptoSHA256 = Crypto.SHA256
public typealias CryptoCurve25519 = Crypto.Curve25519
#endif

/// Convenience so callers don't worry which backend we're using
public typealias SHA256Digest = CryptoSHA256.Digest

// MARK: - Common Extensions

/// Helper extension for SHA256Digest
extension SHA256Digest {
    public init(data: Data) {
        self = CryptoSHA256.hash(data: data)
    }
    
    public init?(hexString: String) {
        guard let data = Data(hexString: hexString) else { return nil }
        self = CryptoSHA256.hash(data: data)
    }
    
    public var hexString: String {
        return Data(self).hexEncodedString()
    }
}

/// Helper extension for Data
extension Data {
    public init?(hexString: String) {
        let hexString = hexString.replacingOccurrences(of: " ", with: "")
        guard hexString.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = hexString.startIndex
        
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = String(hexString[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
    
    public func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

/// Helper extension for Data from SHA256Digest
extension Data {
    public init(_ digest: SHA256Digest) {
        self = Data(digest.makeIterator())
    }
}

// MARK: - Existing components

/// For storing mesh hop information (extended hop info with RSSI)
public struct HopInfo {
    public let hopCount: UInt8
    public let nodePubKey: Data
    public let timestamp: Date
    public let rssi: Int32
    
    public init(hopCount: UInt8, nodePubKey: Data, timestamp: Date, rssi: Int32) {
        self.hopCount = hopCount
        self.nodePubKey = nodePubKey
        self.timestamp = timestamp
        self.rssi = rssi
    }
}

// MARK: - Message Priority

/// Priority levels for messages
public enum MessagePriority: String, CaseIterable {
    case low = "low"
    case normal = "normal"
    case high = "high"
    case urgent = "urgent"
    
    public var description: String {
        return rawValue.capitalized
    }
    
    public var multiplier: Double {
        switch self {
        case .low: return 0.5
        case .normal: return 1.0
        case .high: return 2.0
        case .urgent: return 4.0
        }
    }
}

// MARK: - Network Conditions

/// Network conditions for fee calculation
public struct NetworkConditions {
    public let congestion: Double  // 0.0 to 1.0
    public let averageLatency: TimeInterval  // seconds
    
    public init(congestion: Double, averageLatency: TimeInterval) {
        self.congestion = congestion
        self.averageLatency = averageLatency
    }
}

/// Network congestion levels
public enum NetworkCongestionLevel: String, CaseIterable {
    case light = "light"
    case normal = "normal"
    case heavy = "heavy"
    case congested = "congested"
    
    public var description: String {
        return rawValue.capitalized
    }
    
    public var multiplier: Double {
        switch self {
        case .light: return 0.8
        case .normal: return 1.0
        case .heavy: return 1.5
        case .congested: return 2.5
        }
    }
}
