import Foundation
import Crypto

/// Service for anchoring DAG merkle roots to external networks
/// Implements the anchoring protocol for global consensus
public final class AnchoringService {
    
    // MARK: - Properties
    
    /// DAG storage for accessing transaction data
    private let dagStorage: DAGStorage
    
    /// Anchoring configuration
    private let config: AnchoringConfig
    
    /// Timer for periodic anchoring
    private var anchoringTimer: Timer?
    
    /// Queue for processing anchoring operations
    private let anchoringQueue = DispatchQueue(label: "bitchat.anchoring", qos: .background)
    
    /// Delegate for anchoring events
    public weak var delegate: AnchoringServiceDelegate?
    
    /// Cache of recent anchors
    private var recentAnchors: [AnchoredRoot] = []
    private let recentAnchorsLock = NSLock()
    
    /// Maximum number of recent anchors to keep
    private let maxRecentAnchors = 100
    
    // MARK: - Initialization
    
    public init(dagStorage: DAGStorage, config: AnchoringConfig = AnchoringConfig()) {
        self.dagStorage = dagStorage
        self.config = config
        
        print("🔗 AnchoringService initialized")
        
        // Start anchoring if enabled
        if config.isEnabled {
            startPeriodicAnchoring()
        }
    }
    
    deinit {
        stopPeriodicAnchoring()
    }
    
    // MARK: - Public Methods
    
    /// Start periodic anchoring
    public func startPeriodicAnchoring() {
        guard config.isEnabled else { return }
        
        stopPeriodicAnchoring()
        
        anchoringTimer = Timer.scheduledTimer(withTimeInterval: config.anchoringInterval, repeats: true) { [weak self] _ in
            self?.performAnchoring()
        }
        
        print("🔗 Periodic anchoring started (interval: \(config.anchoringInterval)s)")
    }
    
    /// Stop periodic anchoring
    public func stopPeriodicAnchoring() {
        anchoringTimer?.invalidate()
        anchoringTimer = nil
        
        print("🔗 Periodic anchoring stopped")
    }
    
    /// Manually trigger anchoring
    public func performAnchoring() {
        anchoringQueue.async { [weak self] in
            self?.performAnchoringInternal()
        }
    }
    
    /// Get recent anchored roots
    public func getRecentAnchors() -> [AnchoredRoot] {
        recentAnchorsLock.lock()
        defer { recentAnchorsLock.unlock() }
        
        return recentAnchors
    }
    
    /// Verify DAG integrity against anchored roots
    public func verifyDAGIntegrity() -> DAGIntegrityResult {
        let currentRoot = computeCurrentDAGRoot()
        
        recentAnchorsLock.lock()
        let anchors = recentAnchors
        recentAnchorsLock.unlock()
        
        // Find the most recent successful anchor
        guard let latestAnchor = anchors.first(where: { $0.status == .confirmed }) else {
            return DAGIntegrityResult(isValid: false, error: "No confirmed anchors found")
        }
        
        // Check if current root matches or is a descendant of the anchored root
        let isValid = verifyRootCompatibility(currentRoot: currentRoot, anchoredRoot: latestAnchor)
        
        return DAGIntegrityResult(
            isValid: isValid,
            currentRoot: currentRoot,
            lastAnchoredRoot: latestAnchor,
            error: isValid ? nil : "Current DAG root is incompatible with anchored root"
        )
    }
    
    // MARK: - Private Methods
    
    /// Perform anchoring operation
    private func performAnchoringInternal() {
        print("🔗 Performing anchoring operation...")
        
        // Compute current DAG root
        let currentRoot = computeCurrentDAGRoot()
        
        // Check if we need to anchor (enough new transactions)
        guard shouldPerformAnchoring(currentRoot: currentRoot) else {
            print("🔗 Skipping anchoring - not enough new transactions")
            return
        }
        
        // Create anchored root
        let anchoredRoot = AnchoredRoot(
            merkleRoot: currentRoot,
            blockHeight: getCurrentBlockHeight(),
            timestamp: Date(),
            transactionCount: getTransactionCount(),
            status: .pending
        )
        
        // Add to recent anchors
        addToRecentAnchors(anchoredRoot)
        
        // Attempt to post to external networks
        postToExternalNetworks(anchoredRoot)
        
        print("🔗 Anchoring operation completed - root: \(currentRoot.prefix(16))...")
    }
    
    /// Compute current DAG merkle root
    private func computeCurrentDAGRoot() -> String {
        do {
            // Use DAG statistics for root calculation since getAllTransactions isn't available
            let stats = dagStorage.getStatistics()
            let tips = dagStorage.getTips()
            
            // Create a deterministic root from available data
            var rootData = Data()
            rootData.append(Data(withUnsafeBytes(of: stats.totalTransactions.littleEndian) { Data($0) }))
            rootData.append(Data(withUnsafeBytes(of: stats.tipCount.littleEndian) { Data($0) }))
            rootData.append(Data(withUnsafeBytes(of: stats.totalWeight.littleEndian) { Data($0) }))
            
            // Add tip hashes for deterministic ordering
            for tip in tips.sorted(by: { $0.description < $1.description }) {
                rootData.append(Data(tip))
            }
            
            return CryptoSHA256.hash(data: rootData).hexString
        } catch {
            print("❌ Failed to compute DAG root: \(error)")
            return "error_computing_root"
        }
    }
    
    /// Compute merkle root from transactions
    private func computeMerkleRoot(transactions: [SignedRelayTx]) -> String {
        guard !transactions.isEmpty else {
            return "empty_dag_root"
        }
        
        // Get transaction hashes
        var hashes = transactions.map { transaction in
            transaction.transaction.id
        }
        
        // Build merkle tree
        while hashes.count > 1 {
            var nextLevel: [SHA256Digest] = []
            
            for i in stride(from: 0, to: hashes.count, by: 2) {
                let left = hashes[i]
                let right = i + 1 < hashes.count ? hashes[i + 1] : left
                
                let combined = SHA256.hash(data: Data(left) + Data(right))
                nextLevel.append(combined)
            }
            
            hashes = nextLevel
        }
        
        // Return root hash as hex string
        return hashes[0].compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Check if anchoring should be performed
    private func shouldPerformAnchoring(currentRoot: String) -> Bool {
        recentAnchorsLock.lock()
        defer { recentAnchorsLock.unlock() }
        
        // Always anchor if no recent anchors
        guard let lastAnchor = recentAnchors.first else {
            return true
        }
        
        // Check if enough time has passed
        let timeSinceLastAnchor = Date().timeIntervalSince(lastAnchor.timestamp)
        if timeSinceLastAnchor < config.minAnchoringInterval {
            return false
        }
        
        // Check if root has changed
        if currentRoot == lastAnchor.merkleRoot {
            return false
        }
        
        // Check if enough new transactions
        let transactionDifference = getTransactionCount() - lastAnchor.transactionCount
        if transactionDifference < config.minTransactionsForAnchoring {
            return false
        }
        
        return true
    }
    
    /// Post anchored root to external networks
    private func postToExternalNetworks(_ anchoredRoot: AnchoredRoot) {
        // For now, simulate posting to external networks
        // In a real implementation, this would post to:
        // - Bitcoin blockchain (via OP_RETURN)
        // - Ethereum blockchain (via smart contract)
        // - Other timestamping services
        
        print("🔗 Posting anchor to external networks...")
        
        // Simulate network delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.handleAnchoringResult(anchoredRoot, success: true)
        }
    }
    
    /// Handle anchoring result
    private func handleAnchoringResult(_ anchoredRoot: AnchoredRoot, success: Bool) {
        recentAnchorsLock.lock()
        defer { recentAnchorsLock.unlock() }
        
        // Update status
        if let index = recentAnchors.firstIndex(where: { $0.merkleRoot == anchoredRoot.merkleRoot }) {
            var updatedAnchor = recentAnchors[index]
            updatedAnchor.status = success ? .confirmed : .failed
            if success {
                updatedAnchor.confirmationTime = Date()
            }
            recentAnchors[index] = updatedAnchor
            
            // Notify delegate
            delegate?.anchoringService(self, didUpdateAnchorStatus: updatedAnchor)
            
            if success {
                print("✅ Anchor confirmed: \(anchoredRoot.merkleRoot.prefix(16))...")
            } else {
                print("❌ Anchor failed: \(anchoredRoot.merkleRoot.prefix(16))...")
            }
        }
    }
    
    /// Add anchored root to recent anchors
    private func addToRecentAnchors(_ anchoredRoot: AnchoredRoot) {
        recentAnchorsLock.lock()
        defer { recentAnchorsLock.unlock() }
        
        recentAnchors.insert(anchoredRoot, at: 0)
        
        // Keep only recent anchors
        if recentAnchors.count > maxRecentAnchors {
            recentAnchors.removeLast()
        }
        
        // Notify delegate
        delegate?.anchoringService(self, didCreateAnchor: anchoredRoot)
    }
    
    /// Verify root compatibility
    private func verifyRootCompatibility(currentRoot: String, anchoredRoot: AnchoredRoot) -> Bool {
        // In a real implementation, this would verify that the current root
        // is a valid descendant of the anchored root by checking the DAG structure
        
        // For now, just check if they're the same or if current has more transactions
        return currentRoot == anchoredRoot.merkleRoot || 
               getTransactionCount() >= anchoredRoot.transactionCount
    }
    
    /// Get current block height (for blockchain anchoring)
    private func getCurrentBlockHeight() -> UInt64 {
        // This would query the external blockchain for current block height
        // For now, return a simulated value
        return UInt64(Date().timeIntervalSince1970 / 600)  // ~10 minute blocks
    }
    
    /// Get current transaction count
    private func getTransactionCount() -> Int {
        return dagStorage.getStatistics().totalTransactions
    }
}

// MARK: - Configuration

/// Configuration for anchoring service
public struct AnchoringConfig {
    /// Whether anchoring is enabled
    public let isEnabled: Bool
    
    /// Interval between anchoring attempts (seconds)
    public let anchoringInterval: TimeInterval
    
    /// Minimum interval between anchoring operations (seconds)
    public let minAnchoringInterval: TimeInterval
    
    /// Minimum number of new transactions required for anchoring
    public let minTransactionsForAnchoring: Int
    
    /// External networks to use for anchoring
    public let externalNetworks: [ExternalNetwork]
    
    public init(
        isEnabled: Bool = true,
        anchoringInterval: TimeInterval = 3600,  // 1 hour
        minAnchoringInterval: TimeInterval = 1800,  // 30 minutes
        minTransactionsForAnchoring: Int = 10,
        externalNetworks: [ExternalNetwork] = [.bitcoin, .ethereum]
    ) {
        self.isEnabled = isEnabled
        self.anchoringInterval = anchoringInterval
        self.minAnchoringInterval = minAnchoringInterval
        self.minTransactionsForAnchoring = minTransactionsForAnchoring
        self.externalNetworks = externalNetworks
    }
}

/// External networks for anchoring
public enum ExternalNetwork {
    case bitcoin
    case ethereum
    case litecoin
    case custom(String)
}

// MARK: - Data Structures

/// Anchored root information
public struct AnchoredRoot {
    public let merkleRoot: String
    public let blockHeight: UInt64
    public let timestamp: Date
    public let transactionCount: Int
    public var status: AnchorStatus
    public var confirmationTime: Date?
    
    public init(
        merkleRoot: String,
        blockHeight: UInt64,
        timestamp: Date,
        transactionCount: Int,
        status: AnchorStatus
    ) {
        self.merkleRoot = merkleRoot
        self.blockHeight = blockHeight
        self.timestamp = timestamp
        self.transactionCount = transactionCount
        self.status = status
        self.confirmationTime = nil
    }
}

/// Anchor status
public enum AnchorStatus {
    case pending
    case confirmed
    case failed
}

/// DAG integrity verification result
public struct DAGIntegrityResult {
    public let isValid: Bool
    public let currentRoot: String?
    public let lastAnchoredRoot: AnchoredRoot?
    public let error: String?
    
    public init(
        isValid: Bool,
        currentRoot: String? = nil,
        lastAnchoredRoot: AnchoredRoot? = nil,
        error: String? = nil
    ) {
        self.isValid = isValid
        self.currentRoot = currentRoot
        self.lastAnchoredRoot = lastAnchoredRoot
        self.error = error
    }
}

// MARK: - Delegate

/// Delegate for anchoring service events
public protocol AnchoringServiceDelegate: AnyObject {
    func anchoringService(_ service: AnchoringService, didCreateAnchor anchor: AnchoredRoot)
    func anchoringService(_ service: AnchoringService, didUpdateAnchorStatus anchor: AnchoredRoot)
} 