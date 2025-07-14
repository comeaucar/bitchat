import Foundation
import Crypto

/// Minimal representation of a relay transaction (no signature yet).
public struct RelayTx: Equatable, Hashable {

    public let parents: [SHA256Digest]                    // 2 tips
    public let feePerHop: UInt32                          // µRLT
    public let senderPub: CryptoCurve25519.Signing.PublicKey

    public init(parents: [SHA256Digest],
                feePerHop: UInt32,
                senderPub: CryptoCurve25519.Signing.PublicKey)
    {
        precondition(parents.count == 2, "exactly two parents required")
        self.parents   = parents
        self.feePerHop = feePerHop
        self.senderPub = senderPub
    }

    /// Deterministic hash over immutable fields.
    public var id: SHA256Digest {
        var blob = Data()
        parents.forEach { blob.append(contentsOf: $0) }
        var leFee = feePerHop.littleEndian
        withUnsafeBytes(of: &leFee) { blob.append(contentsOf: $0) }
        blob.append(senderPub.rawRepresentation)
        return CryptoSHA256.hash(data: blob)
    }
    
    /// Sign this transaction with the given private key
    public func sign(with privateKey: CryptoCurve25519.Signing.PrivateKey) throws -> SignedRelayTx {
        let signature = try privateKey.signature(for: Data(id))
        return SignedRelayTx(transaction: self, signature: signature)
    }
    
    /// Encode transaction for serialization
    public func encode() -> Data {
        var data = Data()
        
        // Add parents
        parents.forEach { data.append(contentsOf: $0) }
        
        // Add fee (4 bytes, little endian)
        var leFee = feePerHop.littleEndian
        withUnsafeBytes(of: &leFee) { data.append(contentsOf: $0) }
        
        // Add sender public key (32 bytes)
        data.append(senderPub.rawRepresentation)
        
        return data
    }
    
    /// Decode transaction from data
    public static func decode(_ data: Data) throws -> RelayTx {
        guard data.count >= 100 else { // 2*32 + 4 + 32 = 100 bytes minimum
            throw RelayTxError.invalidData
        }
        
        var offset = 0
        
        // Decode parents (2 * 32 bytes)
        let parent1Data = data.subdata(in: offset..<offset + 32)
        offset += 32
        let parent2Data = data.subdata(in: offset..<offset + 32)
        offset += 32
        
        // Create SHA256Digest from Data
        let parent1 = SHA256Digest(data: parent1Data)
        let parent2 = SHA256Digest(data: parent2Data)
        
        // Decode fee (4 bytes, little endian)
        let feeData = data.subdata(in: offset..<offset + 4)
        let feePerHop = feeData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        offset += 4
        
        // Decode sender public key (32 bytes)
        let senderPubData = data.subdata(in: offset..<offset + 32)
        let senderPub = try CryptoCurve25519.Signing.PublicKey(rawRepresentation: senderPubData)
        
        return RelayTx(parents: [parent1, parent2], feePerHop: feePerHop, senderPub: senderPub)
    }

    // MARK: - Equatable / Hashable conformance
    public static func == (lhs: RelayTx, rhs: RelayTx) -> Bool { lhs.id == rhs.id }
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A signed relay transaction
public struct SignedRelayTx: Equatable, Hashable {
    public let transaction: RelayTx
    public let signature: Data
    
    public init(transaction: RelayTx, signature: Data) {
        self.transaction = transaction
        self.signature = signature
    }
    
    /// Verify the signature of this transaction
    public func verify() -> Bool {
        do {
            let signatureData = signature
            return transaction.senderPub.isValidSignature(signatureData, for: Data(transaction.id))
        } catch {
            return false
        }
    }
    
    /// Verify parent transactions exist in the given DAG
    public func verifyParents(in dag: DAGStorage) -> Bool {
        // Special case for genesis transaction - its parents are zero digests
        let zeroDigest = SHA256Digest(data: Data(repeating: 0, count: 32))
        if transaction.parents.allSatisfy({ $0 == zeroDigest }) {
            return true // Genesis transaction is valid
        }
        
        return transaction.parents.allSatisfy { parent in
            dag.contains(transactionID: parent)
        }
    }
    
    /// Check if this transaction is valid (signature + parents)
    public func isValid(in dag: DAGStorage) -> Bool {
        return verify() && verifyParents(in: dag)
    }
    
    /// Encode signed transaction for serialization
    public func encode() -> Data {
        var data = transaction.encode()
        data.append(signature)
        return data
    }
    
    /// Decode signed transaction from data
    public static func decode(_ data: Data) throws -> SignedRelayTx {
        guard data.count >= 164 else { // 100 + 64 = 164 bytes minimum
            throw RelayTxError.invalidData
        }
        
        let txData = data.prefix(100)
        let signature = data.suffix(64)
        
        let transaction = try RelayTx.decode(txData)
        return SignedRelayTx(transaction: transaction, signature: signature)
    }
    
    // MARK: - Equatable / Hashable conformance
    public static func == (lhs: SignedRelayTx, rhs: SignedRelayTx) -> Bool {
        lhs.transaction.id == rhs.transaction.id
    }
    public func hash(into hasher: inout Hasher) { 
        hasher.combine(transaction.id) 
    }
}

/// Protocol for DAG storage operations
public protocol DAGStorage {
    func contains(transactionID: SHA256Digest) -> Bool
    func getTips() -> [SHA256Digest]
    func addTransaction(_ transaction: SignedRelayTx) throws
    func getTransaction(_ id: SHA256Digest) -> SignedRelayTx?
    func getStatistics() -> DAGStatistics
}

/// DAG storage statistics
public struct DAGStatistics {
    public let totalTransactions: Int
    public let tipCount: Int
    public let totalWeight: UInt64
    
    public init(totalTransactions: Int, tipCount: Int, totalWeight: UInt64) {
        self.totalTransactions = totalTransactions
        self.tipCount = tipCount
        self.totalWeight = totalWeight
    }
}

/// Errors for RelayTx operations
public enum RelayTxError: Error {
    case invalidData
    case invalidSignature
    case parentNotFound
    case invalidParentCount
}

// SHA256Digest extension is now in CoreMesh.swift
