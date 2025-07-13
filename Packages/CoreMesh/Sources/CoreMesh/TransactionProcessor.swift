import Foundation
import Crypto

/// Transaction processing engine for the BitChat crypto system
public final class TransactionProcessor {
    private let dagStorage: DAGStorage
    private let walletManager: WalletManager
    private let processingQueue = DispatchQueue(label: "transaction.processor", qos: .userInitiated)
    
    // Genesis transaction - first transaction in the DAG
    private let genesisTransaction: SignedRelayTx
    
    // Reward distributor for proper relay node rewards
    private let rewardDistributor: RewardDistributor
    
    // Processing statistics
    private var processedTransactionCount = 0
    private var totalFeesProcessed: UInt64 = 0
    private var totalRewardsAwarded: UInt64 = 0
    
    public init(dagStorage: DAGStorage, walletManager: WalletManager) throws {
        self.dagStorage = dagStorage
        self.walletManager = walletManager
        
        // Initialize reward distributor
        self.rewardDistributor = RewardDistributor(walletManager: walletManager, dagStorage: dagStorage)
        
        // Create genesis transaction if DAG is empty
        self.genesisTransaction = try Self.createGenesisTransaction()
        
        // Add genesis transaction if it doesn't exist
        if !dagStorage.contains(transactionID: genesisTransaction.transaction.id) {
            print("🏗️  Adding genesis transaction to DAG")
            try dagStorage.addTransaction(genesisTransaction)
        } else {
            print("✅ Genesis transaction already exists in DAG")
        }
    }
    
    // MARK: - Transaction Processing
    
    /// Process a new transaction (validate, add to DAG, award rewards)
    public func processTransaction(_ transaction: SignedRelayTx, isLocallyOriginated: Bool = false) throws {
        let txHash = transaction.transaction.id.hexString.prefix(8)
        print("🔄 Processing transaction \(txHash)...")
        
        try processingQueue.sync {
            // 1. Validate transaction
            try validateTransaction(transaction)
            
            // 2. Check if transaction already exists
            if dagStorage.contains(transactionID: transaction.transaction.id) {
                print("⚠️  Transaction \(txHash) already exists in DAG, skipping processing")
                return // Don't throw an error, just skip processing
            }
            
            // 3. Validate parent transactions exist
            for parent in transaction.transaction.parents {
                guard dagStorage.contains(transactionID: parent) else {
                    throw TransactionProcessingError.parentNotFound(parent)
                }
            }
            
            // 4. Add to DAG
            do {
                try dagStorage.addTransaction(transaction)
                print("✅ Added transaction \(txHash) to DAG")
            } catch {
                print("❌ Failed to add transaction \(txHash) to DAG: \(error)")
                throw error
            }
            
            // 5. Award relay rewards
            do {
                try awardRelayRewards(for: transaction, isLocallyOriginated: isLocallyOriginated)
                print("✅ Awarded relay rewards for transaction \(txHash)")
            } catch {
                print("❌ Failed to award relay rewards for transaction \(txHash): \(error)")
                // Don't throw here - the transaction is still valid even if reward fails
                // This prevents the entire transaction from failing due to wallet issues
            }
            
            // 6. Update statistics
            updateStatistics(transaction)
            
            print("✅ Processed transaction \(txHash) with fee \(transaction.transaction.feePerHop)µRLT")
        }
    }
    
    /// Create a new transaction for sending a message
    public func createMessageTransaction(
        feePerHop: UInt32,
        senderPrivateKey: CryptoCurve25519.Signing.PrivateKey,
        messagePayload: Data
    ) throws -> SignedRelayTx {
        let tips = dagStorage.getTips()
        
        // Debug logging
        print("🔍 Creating transaction with \(tips.count) tips available")
        for (i, tip) in tips.enumerated() {
            print("   Tip \(i): \(tip.hexString)")
            print("   Tip exists: \(dagStorage.contains(transactionID: tip))")
        }
        print("   Genesis ID: \(genesisTransaction.transaction.id.hexString)")
        print("   Genesis exists: \(dagStorage.contains(transactionID: genesisTransaction.transaction.id))")
        
        // Select two tips as parents (or use genesis if no valid tips available)
        let parents: [SHA256Digest]
        if tips.count >= 2 {
            // Use first two tips
            parents = Array(tips.prefix(2))
        } else if tips.count == 1 && dagStorage.contains(transactionID: tips[0]) {
            // Use the one tip plus genesis (if genesis exists)
            if dagStorage.contains(transactionID: genesisTransaction.transaction.id) {
                parents = [tips[0], genesisTransaction.transaction.id]
            } else {
                // Only use the tip twice
                parents = [tips[0], tips[0]]
            }
        } else {
            // No valid tips, use genesis twice (ensure genesis exists)
            if !dagStorage.contains(transactionID: genesisTransaction.transaction.id) {
                print("⚠️  Genesis not found in DAG, adding it now")
                try dagStorage.addTransaction(genesisTransaction)
            }
            parents = [genesisTransaction.transaction.id, genesisTransaction.transaction.id]
        }
        
        print("📝 Selected parents: \(parents.map(\.hexString))")
        
        let senderPub = senderPrivateKey.publicKey
        let transaction = RelayTx(
            parents: parents,
            feePerHop: feePerHop,
            senderPub: senderPub
        )
        
        return try transaction.sign(with: senderPrivateKey)
    }
    
    /// Award relay rewards for processing a transaction
    /// - Parameters:
    ///   - transaction: The transaction to process rewards for
    ///   - relayPath: Optional relay path for proper reward distribution
    ///   - isLocallyOriginated: Whether this transaction was created locally (don't reward sender)
    private func awardRelayRewards(for transaction: SignedRelayTx, relayPath: [CryptoCurve25519.Signing.PublicKey]? = nil, isLocallyOriginated: Bool = false) throws {
        let feePerHop = transaction.transaction.feePerHop
        let senderPubKey = transaction.transaction.senderPub
        let keyHash = senderPubKey.rawRepresentation.prefix(8).hexEncodedString()
        let txHash = transaction.transaction.id.hexString.prefix(8)
        
        print("🏆 Processing rewards for transaction \(txHash) (locally originated: \(isLocallyOriginated))")
        
        // Don't award relay rewards to yourself for your own messages
        if isLocallyOriginated {
            print("💡 Skipping relay reward for locally originated transaction \(txHash)")
            return
        }
        
        // If we have a relay path, distribute rewards properly
        if let relayPath = relayPath, !relayPath.isEmpty {
            do {
                try rewardDistributor.distributeRelayRewards(
                    for: transaction,
                    relayPath: relayPath,
                    finalRecipient: nil as CryptoCurve25519.Signing.PublicKey?
                )
                
                let rewardStats = rewardDistributor.getStatistics()
                totalRewardsAwarded = rewardStats.totalRewardsDistributed
                
                print("🏆 Distributed relay rewards via RewardDistributor")
                
            } catch {
                print("❌ Failed to distribute relay rewards: \(error)")
                
                // Fall back to old behavior for sender
                try awardFallbackReward(to: senderPubKey, transaction: transaction)
            }
        } else {
            // This is a relayed transaction from another node - award relay reward
            try awardFallbackReward(to: senderPubKey, transaction: transaction)
        }
    }
    
    /// Award fallback reward to sender when no relay path is available
    private func awardFallbackReward(to recipientPubKey: CryptoCurve25519.Signing.PublicKey, transaction: SignedRelayTx) throws {
        let feePerHop = transaction.transaction.feePerHop
        let keyHash = recipientPubKey.rawRepresentation.prefix(8).hexEncodedString()
        let txHash = transaction.transaction.id.hexString.prefix(8)
        
        // Award 1 RLT minted per hop (as per whitepaper)
        let rewardAmount = UInt64(feePerHop)
        
        print("🏆 Awarding fallback reward: \(rewardAmount)µRLT to \(keyHash) for transaction \(txHash)")
        
        do {
            try walletManager.awardReward(
                to: recipientPubKey,
                amount: rewardAmount,
                transactionId: transaction.transaction.id
            )
            
            totalRewardsAwarded += rewardAmount
            print("🏆 Awarded fallback reward: \(rewardAmount)µRLT to \(keyHash)")
            
        } catch {
            print("❌ Failed to award fallback reward to \(keyHash): \(error)")
            
            // If it's a wallet error, we can continue without failing the transaction
            // The transaction is still valid even if the reward fails
            if let walletError = error as? WalletError {
                switch walletError {
                case .databaseError(let msg):
                    print("   Database error: \(msg)")
                case .insufficientBalance:
                    print("   Insufficient balance (shouldn't happen for rewards)")
                case .walletNotFound:
                    print("   Wallet not found (will be created)")
                case .invalidTransaction:
                    print("   Invalid transaction")
                }
            }
            
            // Re-throw the error so the caller can decide how to handle it
            throw error
        }
    }
    
    /// Validate a transaction's signature and structure
    private func validateTransaction(_ transaction: SignedRelayTx) throws {
        // 1. Verify signature
        guard transaction.verify() else {
            throw TransactionProcessingError.invalidSignature
        }
        
        // 2. Verify parents exist in DAG
        guard transaction.verifyParents(in: dagStorage) else {
            throw TransactionProcessingError.parentNotFound(transaction.transaction.parents[0])
        }
        
        // 3. Verify fee is reasonable (basic sanity check)
        guard transaction.transaction.feePerHop <= 1_000_000 else { // 1 RLT max per hop
            throw TransactionProcessingError.feeExceedsLimit
        }
        
        // 4. Verify transaction structure
        guard transaction.transaction.parents.count == 2 else {
            throw TransactionProcessingError.invalidParentCount
        }
        
        // 5. Verify not double-spending (simplified check)
        // In a full implementation, we'd check if the sender has sufficient balance
        // For now, we assume all transactions are valid
        
        print("✅ Transaction \(transaction.transaction.id) passed validation")
    }
    
    /// Update processing statistics
    private func updateStatistics(_ transaction: SignedRelayTx) {
        processedTransactionCount += 1
        totalFeesProcessed += UInt64(transaction.transaction.feePerHop)
        
        if processedTransactionCount % 10 == 0 {
            print("📊 Processed \(processedTransactionCount) transactions, \(totalFeesProcessed)µRLT in fees, \(totalRewardsAwarded)µRLT in rewards")
        }
    }
    
    // MARK: - Genesis Transaction
    
    /// Create the genesis transaction (first transaction in the DAG)
    private static func createGenesisTransaction() throws -> SignedRelayTx {
        // Create a deterministic genesis key pair
        let genesisKey = try CryptoCurve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
        
        // Genesis transaction has well-known deterministic parents (special zero digests)
        let zeroDigest = SHA256Digest(data: Data(repeating: 0, count: 32))
        
        let genesisTransaction = RelayTx(
            parents: [zeroDigest, zeroDigest], // Special zero parents for genesis
            feePerHop: 0,
            senderPub: genesisKey.publicKey
        )
        
        return try genesisTransaction.sign(with: genesisKey)
    }
    
    // MARK: - Query Methods
    
    /// Get current DAG tips
    public func getCurrentTips() -> [SHA256Digest] {
        return dagStorage.getTips()
    }
    
    /// Get transaction by ID
    public func getTransaction(_ id: SHA256Digest) -> SignedRelayTx? {
        return dagStorage.getTransaction(id)
    }
    
    /// Check if transaction exists
    public func transactionExists(_ id: SHA256Digest) -> Bool {
        return dagStorage.contains(transactionID: id)
    }
    
    /// Get processing statistics
    public func getStatistics() -> TransactionProcessingStats {
        return TransactionProcessingStats(
            processedTransactionCount: processedTransactionCount,
            totalFeesProcessed: totalFeesProcessed,
            totalRewardsAwarded: totalRewardsAwarded,
            currentTipCount: dagStorage.getTips().count
        )
    }
    
    /// Get reward distributor for immediate relay rewards
    public func getRewardDistributor() -> RewardDistributor {
        return rewardDistributor
    }
    
    /// Get wallet manager for fee deduction
    public func getWalletManager() -> WalletManager {
        return walletManager
    }
    
    /// Award immediate relay reward to a node
    /// - Parameters:
    ///   - relayNode: The public key of the relay node
    ///   - feePerHop: The fee amount for this hop
    ///   - transactionId: The transaction ID for tracking
    public func awardImmediateRelayReward(
        to relayNode: CryptoCurve25519.Signing.PublicKey,
        feePerHop: UInt32,
        transactionId: SHA256Digest
    ) {
        rewardDistributor.awardImmediateRelayReward(
            to: relayNode,
            feePerHop: feePerHop,
            transactionId: transactionId
        )
    }
}

// MARK: - Error Types

public enum TransactionProcessingError: Error {
    case invalidSignature
    case parentNotFound(SHA256Digest)
    case transactionAlreadyExists
    case feeExceedsLimit
    case invalidParentCount
    case insufficientBalance
    case dagError(String)
    case walletError(String)
}

// MARK: - Statistics

public struct TransactionProcessingStats {
    public let processedTransactionCount: Int
    public let totalFeesProcessed: UInt64
    public let totalRewardsAwarded: UInt64
    public let currentTipCount: Int
}

// Helper extensions are now in CoreMesh.swift
