import Foundation
import Crypto

/// Protocol for packet types that can be used for relay path extraction
public protocol RelayablePacket {
    // Protocol can be extended when BitchatPacket is available
}

/// Manages distribution of relay rewards to intermediate nodes
public final class RewardDistributor {
    
    // MARK: - Properties
    
    /// Wallet manager for reward distribution
    private let walletManager: WalletManager
    
    /// DAG storage for transaction lookups
    private let dagStorage: DAGStorage
    
    /// Thread-safe queue for reward processing
    private let rewardQueue = DispatchQueue(label: "reward.distributor", qos: .userInitiated)
    
    /// Tracking of pending rewards
    private var pendingRewards: [String: PendingReward] = [:]
    private let pendingRewardsLock = NSLock()
    
    /// Statistics
    private var totalRewardsDistributed: UInt64 = 0
    private var totalRelayNodesRewarded: Int = 0
    
    // MARK: - Initialization
    
    public init(walletManager: WalletManager, dagStorage: DAGStorage) {
        self.walletManager = walletManager
        self.dagStorage = dagStorage
    }
    
    // MARK: - Reward Distribution
    
    /// Distribute rewards to relay nodes for processing a transaction
    /// - Parameters:
    ///   - transaction: The signed relay transaction
    ///   - relayPath: Array of public keys representing the relay path
    ///   - finalRecipient: The final recipient's public key (doesn't get relay rewards)
    public func distributeRelayRewards(
        for transaction: SignedRelayTx,
        relayPath: [CryptoCurve25519.Signing.PublicKey],
        finalRecipient: CryptoCurve25519.Signing.PublicKey?
    ) throws {
        let txHash = transaction.transaction.id.hexString.prefix(8)
        let feePerHop = transaction.transaction.feePerHop
        let senderPubKey = transaction.transaction.senderPub
        
        print("🏆 Distributing relay rewards for transaction \(txHash)")
        print("   Fee per hop: \(feePerHop)µRLT")
        print("   Relay path: \(relayPath.count) nodes")
        print("   Sender: \(senderPubKey.rawRepresentation.prefix(4).hexEncodedString())")
        
        // Filter out sender and final recipient from relay path
        let eligibleRelayNodes = relayPath.filter { relayNode in
            // Don't reward the sender
            if relayNode.rawRepresentation == senderPubKey.rawRepresentation {
                return false
            }
            
            // Don't reward the final recipient
            if let finalRecipient = finalRecipient, relayNode.rawRepresentation == finalRecipient.rawRepresentation {
                return false
            }
            
            return true
        }
        
        guard !eligibleRelayNodes.isEmpty else {
            print("   No eligible relay nodes for rewards")
            return
        }
        
        // Calculate reward per relay node
        let totalRewardAmount = UInt64(feePerHop) * UInt64(eligibleRelayNodes.count)
        let rewardPerNode = UInt64(feePerHop) // Each relay node gets the full fee per hop
        
        print("   Eligible relay nodes: \(eligibleRelayNodes.count)")
        print("   Reward per node: \(rewardPerNode)µRLT")
        print("   Total rewards: \(totalRewardAmount)µRLT")
        
        // Distribute rewards to each eligible relay node
        for (index, relayNode) in eligibleRelayNodes.enumerated() {
            let nodeHash = relayNode.rawRepresentation.prefix(4).hexEncodedString()
            
            do {
                try walletManager.awardReward(
                    to: relayNode,
                    amount: rewardPerNode,
                    transactionId: transaction.transaction.id
                )
                
                print("   ✅ Awarded \(rewardPerNode)µRLT to relay node \(index + 1)/\(eligibleRelayNodes.count) (\(nodeHash))")
                
                // Update statistics
                totalRewardsDistributed += rewardPerNode
                totalRelayNodesRewarded += 1
                
            } catch {
                print("   ❌ Failed to award reward to relay node \(nodeHash): \(error)")
                
                // Store as pending reward for retry
                storePendingReward(
                    relayNode: relayNode,
                    amount: rewardPerNode,
                    transactionId: transaction.transaction.id,
                    retryCount: 0
                )
            }
        }
        
        print("🏆 Completed reward distribution for transaction \(txHash)")
    }
    
    /// Process a message packet to extract relay path information
    /// - Parameters:
    ///   - packet: The BitchatPacket being processed
    ///   - previousRelayNode: The node that forwarded this packet to us
    ///   - isLocalMessage: Whether this message originated from this node
    /// - Returns: Array of relay nodes that should receive rewards
    internal func extractRelayPath(
        from packet: RelayablePacket,
        previousRelayNode: CryptoCurve25519.Signing.PublicKey?,
        isLocalMessage: Bool
    ) -> [CryptoCurve25519.Signing.PublicKey] {
        var relayPath: [CryptoCurve25519.Signing.PublicKey] = []
        
        // If this is a local message, no relay path yet
        if isLocalMessage {
            return relayPath
        }
        
        // Add the previous relay node if available
        if let previousNode = previousRelayNode {
            relayPath.append(previousNode)
        }
        
        // In a full implementation, we would parse relay path from packet metadata
        // For now, we build the path based on the immediate relay node
        
        return relayPath
    }
    
    /// Award immediate relay reward to a node that just forwarded a message
    /// - Parameters:
    ///   - relayNode: The public key of the relay node
    ///   - feePerHop: The fee amount for this hop
    ///   - transactionId: The transaction ID for tracking
    public func awardImmediateRelayReward(
        to relayNode: CryptoCurve25519.Signing.PublicKey,
        feePerHop: UInt32,
        transactionId: SHA256Digest
    ) {
        let nodeHash = relayNode.rawRepresentation.prefix(4).hexEncodedString()
        let rewardAmount = UInt64(feePerHop)
        
        rewardQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                try self.walletManager.awardReward(
                    to: relayNode,
                    amount: rewardAmount,
                    transactionId: transactionId
                )
                
                print("🏆 Awarded immediate relay reward: \(rewardAmount)µRLT to \(nodeHash)")
                
                // Update statistics
                self.totalRewardsDistributed += rewardAmount
                self.totalRelayNodesRewarded += 1
                
            } catch {
                print("❌ Failed to award immediate relay reward to \(nodeHash): \(error)")
                
                // Store as pending reward for retry
                self.storePendingReward(
                    relayNode: relayNode,
                    amount: rewardAmount,
                    transactionId: transactionId,
                    retryCount: 0
                )
            }
        }
    }
    
    /// Retry pending rewards
    public func retryPendingRewards() {
        pendingRewardsLock.lock()
        let rewards = Array(pendingRewards.values)
        pendingRewardsLock.unlock()
        
        guard !rewards.isEmpty else { return }
        
        print("🔄 Retrying \(rewards.count) pending rewards...")
        
        for reward in rewards {
            rewardQueue.async { [weak self] in
                self?.processPendingReward(reward)
            }
        }
    }
    
    /// Get reward distribution statistics
    public func getStatistics() -> RewardDistributionStats {
        pendingRewardsLock.lock()
        let pendingCount = pendingRewards.count
        let totalPendingAmount = pendingRewards.values.reduce(0) { $0 + $1.amount }
        pendingRewardsLock.unlock()
        
        return RewardDistributionStats(
            totalRewardsDistributed: totalRewardsDistributed,
            totalRelayNodesRewarded: totalRelayNodesRewarded,
            pendingRewardsCount: pendingCount,
            totalPendingAmount: totalPendingAmount
        )
    }
    
    // MARK: - Private Methods
    
    private func storePendingReward(
        relayNode: CryptoCurve25519.Signing.PublicKey,
        amount: UInt64,
        transactionId: SHA256Digest,
        retryCount: Int
    ) {
        let pendingReward = PendingReward(
            id: UUID().uuidString,
            relayNode: relayNode,
            amount: amount,
            transactionId: transactionId,
            retryCount: retryCount,
            createdAt: Date()
        )
        
        pendingRewardsLock.lock()
        pendingRewards[pendingReward.id] = pendingReward
        pendingRewardsLock.unlock()
        
        print("📦 Stored pending reward: \(amount)µRLT for \(relayNode.rawRepresentation.prefix(4).hexEncodedString())")
    }
    
    private func processPendingReward(_ reward: PendingReward) {
        let nodeHash = reward.relayNode.rawRepresentation.prefix(4).hexEncodedString()
        
        do {
            try walletManager.awardReward(
                to: reward.relayNode,
                amount: reward.amount,
                transactionId: reward.transactionId
            )
            
            print("✅ Processed pending reward: \(reward.amount)µRLT to \(nodeHash)")
            
            // Remove from pending rewards
            pendingRewardsLock.lock()
            pendingRewards.removeValue(forKey: reward.id)
            pendingRewardsLock.unlock()
            
            // Update statistics
            totalRewardsDistributed += reward.amount
            totalRelayNodesRewarded += 1
            
        } catch {
            print("❌ Failed to process pending reward for \(nodeHash): \(error)")
            
            // Increment retry count
            let updatedReward = PendingReward(
                id: reward.id,
                relayNode: reward.relayNode,
                amount: reward.amount,
                transactionId: reward.transactionId,
                retryCount: reward.retryCount + 1,
                createdAt: reward.createdAt
            )
            
            // Only keep retrying up to a limit
            if updatedReward.retryCount < 5 {
                pendingRewardsLock.lock()
                pendingRewards[reward.id] = updatedReward
                pendingRewardsLock.unlock()
            } else {
                // Remove after too many retries
                pendingRewardsLock.lock()
                pendingRewards.removeValue(forKey: reward.id)
                pendingRewardsLock.unlock()
                
                print("❌ Giving up on pending reward after \(updatedReward.retryCount) retries")
            }
        }
    }
}

// MARK: - Data Structures

/// Represents a pending reward that failed to be distributed
public struct PendingReward {
    public let id: String
    public let relayNode: CryptoCurve25519.Signing.PublicKey
    public let amount: UInt64
    public let transactionId: SHA256Digest
    public let retryCount: Int
    public let createdAt: Date
    
    public init(
        id: String,
        relayNode: CryptoCurve25519.Signing.PublicKey,
        amount: UInt64,
        transactionId: SHA256Digest,
        retryCount: Int,
        createdAt: Date
    ) {
        self.id = id
        self.relayNode = relayNode
        self.amount = amount
        self.transactionId = transactionId
        self.retryCount = retryCount
        self.createdAt = createdAt
    }
}

/// Statistics for reward distribution
public struct RewardDistributionStats {
    public let totalRewardsDistributed: UInt64
    public let totalRelayNodesRewarded: Int
    public let pendingRewardsCount: Int
    public let totalPendingAmount: UInt64
    
    public init(
        totalRewardsDistributed: UInt64,
        totalRelayNodesRewarded: Int,
        pendingRewardsCount: Int,
        totalPendingAmount: UInt64
    ) {
        self.totalRewardsDistributed = totalRewardsDistributed
        self.totalRelayNodesRewarded = totalRelayNodesRewarded
        self.pendingRewardsCount = pendingRewardsCount
        self.totalPendingAmount = totalPendingAmount
    }
    
    /// Human-readable description
    public var description: String {
        return "Rewards: \(totalRewardsDistributed)µRLT to \(totalRelayNodesRewarded) nodes, \(pendingRewardsCount) pending"
    }
} 