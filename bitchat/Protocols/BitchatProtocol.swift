//
// BitchatProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
#if canImport(Crypto)
import Crypto
#endif

// Enhanced packet structure for crypto functionality
struct CryptoPacket {
    let headerV2: BitChatHeaderV2
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    let signature: Data?
    let relayTx: RelayTx?  // Associated relay transaction
    
    init(headerV2: BitChatHeaderV2, type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, relayTx: RelayTx? = nil) {
        self.headerV2 = headerV2
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.relayTx = relayTx
    }
    
    // Convert to legacy packet for compatibility
    func toLegacyPacket() -> BitchatPacket {
        return BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: signature,
            ttl: headerV2.ttl
        )
    }
    
    // Create from legacy packet with default crypto values
    static func from(legacyPacket: BitchatPacket, feePerHop: UInt32 = 0, txHash: [UInt8] = [UInt8](repeating: 0, count: 32)) -> CryptoPacket {
        let headerV2 = BitChatHeaderV2(
            ttl: legacyPacket.ttl,
            feePerHop: feePerHop,
            txHash: txHash
        )
        
        return CryptoPacket(
            headerV2: headerV2,
            type: legacyPacket.type,
            senderID: legacyPacket.senderID,
            recipientID: legacyPacket.recipientID,
            timestamp: legacyPacket.timestamp,
            payload: legacyPacket.payload,
            signature: legacyPacket.signature
        )
    }
    
    // Encode to binary format
    func encode() -> Data? {
        var data = Data()
        
        // Add V2 header first
        data.append(headerV2.encode())
        
        // Add remaining packet data (type, senderID, etc.)
        data.append(type)
        
        // Add senderID length + data
        let senderIDData = senderID.count > 8 ? senderID.prefix(8) : senderID
        data.append(contentsOf: senderIDData)
        if senderIDData.count < 8 {
            data.append(Data(repeating: 0, count: 8 - senderIDData.count))
        }
        
        // Add recipientID flag and data
        if let recipientID = recipientID {
            data.append(1) // has recipient
            let recipientIDData = recipientID.count > 8 ? recipientID.prefix(8) : recipientID
            data.append(contentsOf: recipientIDData)
            if recipientIDData.count < 8 {
                data.append(Data(repeating: 0, count: 8 - recipientIDData.count))
            }
        } else {
            data.append(0) // no recipient
        }
        
        // Add timestamp (8 bytes, big-endian)
        for i in (0..<8).reversed() {
            data.append(UInt8((timestamp >> (i * 8)) & 0xFF))
        }
        
        // Add payload length (2 bytes) + payload
        let payloadLength = UInt16(payload.count)
        data.append(UInt8((payloadLength >> 8) & 0xFF))
        data.append(UInt8(payloadLength & 0xFF))
        data.append(payload)
        
        // Add signature flag and data
        if let signature = signature {
            data.append(1) // has signature
            let sigData = signature.count > 64 ? signature.prefix(64) : signature
            data.append(contentsOf: sigData)
            if sigData.count < 64 {
                data.append(Data(repeating: 0, count: 64 - sigData.count))
            }
        } else {
            data.append(0) // no signature
        }
        
        return data
    }
    
    // Decode from binary format
    static func decode(_ data: Data) -> CryptoPacket? {
        guard data.count >= BitChatHeaderV2.byteCount else { return nil }
        
        var offset = 0
        
        // Decode V2 header
        guard let headerV2 = try? BitChatHeaderV2.decode(data.subdata(in: offset..<offset + BitChatHeaderV2.byteCount)) else {
            return nil
        }
        offset += BitChatHeaderV2.byteCount
        
        // Decode type
        guard offset < data.count else { return nil }
        let type = data[offset]
        offset += 1
        
        // Decode senderID
        guard offset + 8 <= data.count else { return nil }
        let senderID = data.subdata(in: offset..<offset + 8)
        offset += 8
        
        // Decode recipientID
        guard offset < data.count else { return nil }
        let hasRecipient = data[offset] == 1
        offset += 1
        
        var recipientID: Data?
        if hasRecipient {
            guard offset + 8 <= data.count else { return nil }
            recipientID = data.subdata(in: offset..<offset + 8)
            offset += 8
        }
        
        // Decode timestamp
        guard offset + 8 <= data.count else { return nil }
        let timestampData = data.subdata(in: offset..<offset + 8)
        let timestamp = timestampData.reduce(0) { result, byte in
            (result << 8) | UInt64(byte)
        }
        offset += 8
        
        // Decode payload
        guard offset + 2 <= data.count else { return nil }
        let payloadLength = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2
        
        guard offset + payloadLength <= data.count else { return nil }
        let payload = data.subdata(in: offset..<offset + payloadLength)
        offset += payloadLength
        
        // Decode signature
        guard offset < data.count else { return nil }
        let hasSignature = data[offset] == 1
        offset += 1
        
        var signature: Data?
        if hasSignature {
            guard offset + 64 <= data.count else { return nil }
            signature = data.subdata(in: offset..<offset + 64)
        }
        
        return CryptoPacket(
            headerV2: headerV2,
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: signature
        )
    }
}

// Privacy-preserving padding utilities
struct MessagePadding {
    // Standard block sizes for padding
    static let blockSizes = [256, 512, 1024, 2048]
    
    // Add PKCS#7-style padding to reach target size
    static func pad(_ data: Data, toSize targetSize: Int) -> Data {
        guard data.count < targetSize else { return data }
        
        let paddingNeeded = targetSize - data.count
        
        // PKCS#7 only supports padding up to 255 bytes
        // If we need more padding than that, don't pad - return original data
        guard paddingNeeded <= 255 else { return data }
        
        var padded = data
        
        // Standard PKCS#7 padding
        var randomBytes = [UInt8](repeating: 0, count: paddingNeeded - 1)
        _ = SecRandomCopyBytes(kSecRandomDefault, paddingNeeded - 1, &randomBytes)
        padded.append(contentsOf: randomBytes)
        padded.append(UInt8(paddingNeeded))
        
        return padded
    }
    
    // Remove padding from data
    static func unpad(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        
        // Last byte tells us how much padding to remove
        let paddingLength = Int(data[data.count - 1])
        guard paddingLength > 0 && paddingLength <= data.count else { return data }
        
        return data.prefix(data.count - paddingLength)
    }
    
    // Find optimal block size for data
    static func optimalBlockSize(for dataSize: Int) -> Int {
        // Account for encryption overhead (~16 bytes for AES-GCM tag)
        let totalSize = dataSize + 16
        
        // Find smallest block that fits
        for blockSize in blockSizes {
            if totalSize <= blockSize {
                return blockSize
            }
        }
        
        // For very large messages, just use the original size
        // (will be fragmented anyway)
        return dataSize
    }
}

enum MessageType: UInt8 {
    case announce = 0x01
    case keyExchange = 0x02
    case leave = 0x03
    case message = 0x04  // All user messages (private and broadcast)
    case fragmentStart = 0x05
    case fragmentContinue = 0x06
    case fragmentEnd = 0x07
    case channelAnnounce = 0x08  // Announce password-protected channel status
    case channelRetention = 0x09  // Announce channel retention status
    case deliveryAck = 0x0A  // Acknowledge message received
    case deliveryStatusRequest = 0x0B  // Request delivery status update
    case readReceipt = 0x0C  // Message has been read/viewed
    case fileTransferRequest = 0x0D  // Request to send a file
    case fileTransferResponse = 0x0E  // Accept/reject file transfer
    case fileChunk = 0x0F  // File chunk with data
    case fileChunkAck = 0x10  // Acknowledge receipt of file chunk
    case fileTransferComplete = 0x11  // All chunks received successfully
    case fileTransferCancel = 0x12  // Cancel file transfer
}

// Special recipient ID for broadcast messages
struct SpecialRecipients {
    static let broadcast = Data(repeating: 0xFF, count: 8)  // All 0xFF = broadcast
}

struct BitchatPacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    let signature: Data?
    var ttl: UInt8
    
    init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8) {
        self.version = 1
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.ttl = ttl
    }
    
    // Convenience initializer for new binary format
    init(type: UInt8, ttl: UInt8, senderID: String, payload: Data) {
        self.version = 1
        self.type = type
        self.senderID = senderID.data(using: .utf8)!
        self.recipientID = nil
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
        self.payload = payload
        self.signature = nil
        self.ttl = ttl
    }
    
    var data: Data? {
        BinaryProtocol.encode(self)
    }
    
    func toBinaryData() -> Data? {
        BinaryProtocol.encode(self)
    }
    
    static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}

// Delivery acknowledgment structure
struct DeliveryAck: Codable {
    let originalMessageID: String
    let ackID: String
    let recipientID: String  // Who received it
    let recipientNickname: String
    let timestamp: Date
    let hopCount: UInt8  // How many hops to reach recipient
    
    init(originalMessageID: String, recipientID: String, recipientNickname: String, hopCount: UInt8) {
        self.originalMessageID = originalMessageID
        self.ackID = UUID().uuidString
        self.recipientID = recipientID
        self.recipientNickname = recipientNickname
        self.timestamp = Date()
        self.hopCount = hopCount
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> DeliveryAck? {
        try? JSONDecoder().decode(DeliveryAck.self, from: data)
    }
}

// Read receipt structure
struct ReadReceipt: Codable {
    let originalMessageID: String
    let receiptID: String
    let readerID: String  // Who read it
    let readerNickname: String
    let timestamp: Date
    
    init(originalMessageID: String, readerID: String, readerNickname: String) {
        self.originalMessageID = originalMessageID
        self.receiptID = UUID().uuidString
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ReadReceipt? {
        try? JSONDecoder().decode(ReadReceipt.self, from: data)
    }
}

// Delivery status for messages
enum DeliveryStatus: Codable, Equatable {
    case sending
    case sent  // Left our device
    case delivered(to: String, at: Date)  // Confirmed by recipient
    case read(by: String, at: Date)  // Seen by recipient
    case failed(reason: String)
    case partiallyDelivered(reached: Int, total: Int)  // For rooms
    
    var displayText: String {
        switch self {
        case .sending:
            return "Sending..."
        case .sent:
            return "Sent"
        case .delivered(let nickname, _):
            return "Delivered to \(nickname)"
        case .read(let nickname, _):
            return "Read by \(nickname)"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .partiallyDelivered(let reached, let total):
            return "Delivered to \(reached)/\(total)"
        }
    }
}

struct BitchatMessage: Codable, Equatable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    let isRelay: Bool
    let originalSender: String?
    let isPrivate: Bool
    let recipientNickname: String?
    let senderPeerID: String?
    let mentions: [String]?  // Array of mentioned nicknames
    let channel: String?  // Channel hashtag (e.g., "#general")
    let encryptedContent: Data?  // For password-protected rooms
    let isEncrypted: Bool  // Flag to indicate if content is encrypted
    var deliveryStatus: DeliveryStatus? // Delivery tracking
    
    init(id: String? = nil, sender: String, content: String, timestamp: Date, isRelay: Bool, originalSender: String? = nil, isPrivate: Bool = false, recipientNickname: String? = nil, senderPeerID: String? = nil, mentions: [String]? = nil, channel: String? = nil, encryptedContent: Data? = nil, isEncrypted: Bool = false, deliveryStatus: DeliveryStatus? = nil) {
        self.id = id ?? UUID().uuidString
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.isRelay = isRelay
        self.originalSender = originalSender
        self.isPrivate = isPrivate
        self.recipientNickname = recipientNickname
        self.senderPeerID = senderPeerID
        self.mentions = mentions
        self.channel = channel
        self.encryptedContent = encryptedContent
        self.isEncrypted = isEncrypted
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : nil)
    }
}

// MARK: - File Transfer Protocol Structures

struct FileTransferRequest: Codable {
    let transferID: String
    let fileName: String
    let fileSize: UInt64  // Size in bytes
    let mimeType: String?
    let fileHash: String  // SHA-256 hash for verification
    let chunkSize: UInt32  // Size of each chunk in bytes
    let totalChunks: UInt32  // Total number of chunks
    let costPerMB: UInt64  // Cost in µRLT per megabyte
    let totalCost: UInt64  // Total cost for entire file transfer
    let senderID: String
    let timestamp: Date
    
    init(fileName: String, fileSize: UInt64, fileData: Data, costPerMB: UInt64, senderID: String, chunkSize: UInt32 = 32768) {  // 32KB chunks
        self.transferID = UUID().uuidString
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = FileTransferManager.mimeType(for: fileName)
        self.fileHash = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
        self.chunkSize = chunkSize
        self.totalChunks = UInt32((fileSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))  // Ceiling division
        self.costPerMB = costPerMB
        
        // Calculate total cost: (file size in MB) * cost per MB
        let fileSizeInMB = max(1, (fileSize + 1024 * 1024 - 1) / (1024 * 1024))  // Ceiling division, minimum 1 MB
        self.totalCost = fileSizeInMB * costPerMB
        
        self.senderID = senderID
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FileTransferRequest? {
        try? JSONDecoder().decode(FileTransferRequest.self, from: data)
    }
}

struct FileTransferResponse: Codable {
    let transferID: String
    let accepted: Bool
    let reason: String?  // Reason for rejection if not accepted
    let recipientID: String
    let timestamp: Date
    
    init(transferID: String, accepted: Bool, reason: String? = nil, recipientID: String) {
        self.transferID = transferID
        self.accepted = accepted
        self.reason = reason
        self.recipientID = recipientID
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FileTransferResponse? {
        try? JSONDecoder().decode(FileTransferResponse.self, from: data)
    }
}

struct FileChunk: Codable {
    let transferID: String
    let chunkIndex: UInt32  // 0-based chunk index
    let chunkData: Data
    let chunkHash: String  // SHA-256 hash of this chunk for verification
    let isLastChunk: Bool
    let timestamp: Date
    
    init(transferID: String, chunkIndex: UInt32, chunkData: Data, isLastChunk: Bool) {
        self.transferID = transferID
        self.chunkIndex = chunkIndex
        self.chunkData = chunkData
        self.chunkHash = SHA256.hash(data: chunkData).compactMap { String(format: "%02x", $0) }.joined()
        self.isLastChunk = isLastChunk
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FileChunk? {
        try? JSONDecoder().decode(FileChunk.self, from: data)
    }
}

struct FileChunkAck: Codable {
    let transferID: String
    let chunkIndex: UInt32
    let received: Bool  // true if chunk received and verified successfully
    let errorMessage: String?  // Error details if received = false
    let recipientID: String
    let timestamp: Date
    
    init(transferID: String, chunkIndex: UInt32, received: Bool, errorMessage: String? = nil, recipientID: String) {
        self.transferID = transferID
        self.chunkIndex = chunkIndex
        self.received = received
        self.errorMessage = errorMessage
        self.recipientID = recipientID
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FileChunkAck? {
        try? JSONDecoder().decode(FileChunkAck.self, from: data)
    }
}

struct FileTransferComplete: Codable {
    let transferID: String
    let success: Bool
    let totalChunksReceived: UInt32
    let fileHash: String?  // Hash of reassembled file for verification
    let recipientID: String
    let timestamp: Date
    
    init(transferID: String, success: Bool, totalChunksReceived: UInt32, fileData: Data? = nil, recipientID: String) {
        self.transferID = transferID
        self.success = success
        self.totalChunksReceived = totalChunksReceived
        if let fileData = fileData {
            self.fileHash = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
        } else {
            self.fileHash = nil
        }
        self.recipientID = recipientID
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FileTransferComplete? {
        try? JSONDecoder().decode(FileTransferComplete.self, from: data)
    }
}

struct FileTransferCancel: Codable {
    let transferID: String
    let reason: String
    let canceledBy: String  // ID of the peer who canceled
    let timestamp: Date
    
    init(transferID: String, reason: String, canceledBy: String) {
        self.transferID = transferID
        self.reason = reason
        self.canceledBy = canceledBy
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FileTransferCancel? {
        try? JSONDecoder().decode(FileTransferCancel.self, from: data)
    }
}

// File transfer status tracking
enum FileTransferStatus {
    case requesting  // Waiting for recipient response
    case accepted   // Recipient accepted, ready to send
    case rejected(reason: String)  // Recipient rejected
    case transferring(chunksComplete: UInt32, totalChunks: UInt32)  // In progress
    case completed  // Successfully completed
    case failed(error: String)  // Failed with error
    case cancelled(reason: String)  // Cancelled by either party
    
    var displayText: String {
        switch self {
        case .requesting:
            return "Requesting..."
        case .accepted:
            return "Accepted"
        case .rejected(let reason):
            return "Rejected: \(reason)"
        case .transferring(let complete, let total):
            let percentage = total > 0 ? Int((Double(complete) / Double(total)) * 100) : 0
            return "Transferring \(percentage)% (\(complete)/\(total) chunks)"
        case .completed:
            return "Completed"
        case .failed(let error):
            return "Failed: \(error)"
        case .cancelled(let reason):
            return "Cancelled: \(reason)"
        }
    }
}

protocol BitchatDelegate: AnyObject {
    func didReceiveMessage(_ message: BitchatMessage)
    func didConnectToPeer(_ peerID: String)
    func didDisconnectFromPeer(_ peerID: String)
    func didUpdatePeerList(_ peers: [String])
    func didReceiveChannelLeave(_ channel: String, from peerID: String)
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?)
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?)
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String?
    
    // Optional method to check if a fingerprint belongs to a favorite peer
    func isFavorite(fingerprint: String) -> Bool
    
    // Delivery confirmation methods
    func didReceiveDeliveryAck(_ ack: DeliveryAck)
    func didReceiveReadReceipt(_ receipt: ReadReceipt)
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
    
    // Fee beacon updates
    func didUpdateNetworkFees()
    
    // File transfer methods
    func didReceiveFileTransferRequest(_ request: FileTransferRequest)
    func didReceiveFileTransferResponse(_ response: FileTransferResponse)
    func didReceiveFileChunk(_ chunk: FileChunk)
    func didReceiveFileChunkAck(_ ack: FileChunkAck)
    func didReceiveFileTransferComplete(_ completion: FileTransferComplete)
    func didReceiveFileTransferCancel(_ cancellation: FileTransferCancel)
    func didUpdateFileTransferStatus(_ transferID: String, status: FileTransferStatus)
}

// Provide default implementation to make it effectively optional
extension BitchatDelegate {
    func isFavorite(fingerprint: String) -> Bool {
        return false
    }
    
    func didReceiveChannelLeave(_ channel: String, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        // Default empty implementation
    }
    
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?) {
        // Default empty implementation
    }
    
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String? {
        // Default returns nil (unable to decrypt)
        return nil
    }
    
    func didReceiveDeliveryAck(_ ack: DeliveryAck) {
        // Default empty implementation
    }
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        // Default empty implementation
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        // Default empty implementation
    }
    
    func didUpdateNetworkFees() {
        // Default empty implementation
    }
    
    func didReceiveFileTransferRequest(_ request: FileTransferRequest) {
        // Default empty implementation
    }
    
    func didReceiveFileTransferResponse(_ response: FileTransferResponse) {
        // Default empty implementation
    }
    
    func didReceiveFileChunk(_ chunk: FileChunk) {
        // Default empty implementation
    }
    
    func didReceiveFileChunkAck(_ ack: FileChunkAck) {
        // Default empty implementation
    }
    
    func didReceiveFileTransferComplete(_ completion: FileTransferComplete) {
        // Default empty implementation
    }
    
    func didReceiveFileTransferCancel(_ cancellation: FileTransferCancel) {
        // Default empty implementation
    }
    
    func didUpdateFileTransferStatus(_ transferID: String, status: FileTransferStatus) {
        // Default empty implementation
    }
}
