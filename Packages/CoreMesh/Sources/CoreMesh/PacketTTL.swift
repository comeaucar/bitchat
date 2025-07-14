import Foundation

public enum PacketTTL {

    /// Decrements TTL in-place and returns new Data.
    /// Throws when TTL is already zero or header version unsupported.
    public static func decrement(in packet: Data) throws -> Data {
        // Must at least contain full header
        guard packet.count >= BitChatHeaderV2.byteCount else { throw Error.tooShort }

        // Fast path: copy mutable buffer
        var mutable = packet

        guard mutable[0] == BitChatHeaderV2.version else { throw Error.badVersion }
        var ttl = mutable[1]
        guard ttl > 0 else { throw Error.ttlExpired }

        ttl &-= 1
        mutable[1] = ttl
        return mutable
    }

    public enum Error: Swift.Error {
        case tooShort
        case badVersion
        case ttlExpired
    }
}
