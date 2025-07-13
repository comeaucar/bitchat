import Foundation
import Crypto

/// Proof of Work service for spam protection on low-fee messages
/// Implements leading-zero hash requirements with auto-scaling difficulty
public final class ProofOfWork {
    
    // MARK: - Properties
    
    /// Current network difficulty (number of leading zeros required)
    private var currentDifficulty: UInt8 = 1
    
    /// Difficulty adjustment parameters
    private let minDifficulty: UInt8 = 1
    private let maxDifficulty: UInt8 = 6
    private let targetComputeTime: TimeInterval = 2.0 // Target 2 seconds
    private let difficultyAdjustmentWindow = 100 // Adjust every 100 PoW computations
    
    /// Statistics for difficulty adjustment
    private var powComputations: [TimeInterval] = []
    private let statisticsLock = NSLock()
    
    public init() {}
    
    // MARK: - Public Methods
    
    /// Check if message requires Proof of Work
    /// - Parameters:
    ///   - messageFee: Fee paid for the message (µRLT)
    ///   - relayMinFee: Minimum fee required by relays (µRLT)
    /// - Returns: True if PoW is required (fee < relayMinFee)
    public func requiresProofOfWork(messageFee: UInt32, relayMinFee: UInt32) -> Bool {
        return messageFee < relayMinFee
    }
    
    /// Compute Proof of Work for a message
    /// - Parameters:
    ///   - messageData: The message data to include in PoW
    ///   - senderPubKey: Sender's public key
    ///   - timestamp: Message timestamp
    /// - Returns: ProofOfWorkResult containing nonce and hash
    public func computeProofOfWork(
        messageData: Data,
        senderPubKey: CryptoCurve25519.Signing.PublicKey,
        timestamp: UInt64
    ) -> ProofOfWorkResult {
        let startTime = Date()
        let difficulty = getCurrentDifficulty()
        
        print("🔨 Computing PoW with difficulty \(difficulty) (requiring \(difficulty) leading zeros)")
        
        var nonce: UInt64 = 0
        var hash: SHA256Digest
        var hashData: Data
        
        repeat {
            // Create input data for hashing
            var inputData = Data()
            inputData.append(messageData)
            inputData.append(senderPubKey.rawRepresentation)
            inputData.append(Data(withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }))
            inputData.append(Data(withUnsafeBytes(of: nonce.littleEndian) { Data($0) }))
            
            // Compute hash
            hash = SHA256.hash(data: inputData)
            hashData = Data(hash)
            
            nonce += 1
            
            // Check for cancellation every 10000 iterations
            if nonce % 10000 == 0 {
                print("🔨 PoW progress: nonce \(nonce), current hash: \(hashData.prefix(4).hexEncodedString())...")
            }
            
        } while !hasRequiredLeadingZeros(hashData, difficulty: difficulty)
        
        let computeTime = Date().timeIntervalSince(startTime)
        
        print("✅ PoW completed! Nonce: \(nonce - 1), Time: \(String(format: "%.2f", computeTime))s")
        print("🎯 Final hash: \(hashData.hexEncodedString())")
        
        // Record computation time for difficulty adjustment
        recordComputationTime(computeTime)
        
        return ProofOfWorkResult(
            nonce: nonce - 1,
            hash: hash,
            difficulty: difficulty,
            computeTime: computeTime
        )
    }
    
    /// Verify Proof of Work for a message
    /// - Parameters:
    ///   - messageData: The message data
    ///   - senderPubKey: Sender's public key
    ///   - timestamp: Message timestamp
    ///   - powResult: The PoW result to verify
    /// - Returns: True if PoW is valid
    public func verifyProofOfWork(
        messageData: Data,
        senderPubKey: CryptoCurve25519.Signing.PublicKey,
        timestamp: UInt64,
        powResult: ProofOfWorkResult
    ) -> Bool {
        // Recreate the input data
        var inputData = Data()
        inputData.append(messageData)
        inputData.append(senderPubKey.rawRepresentation)
        inputData.append(Data(withUnsafeBytes(of: timestamp.littleEndian) { Data($0) }))
        inputData.append(Data(withUnsafeBytes(of: powResult.nonce.littleEndian) { Data($0) }))
        
        // Compute hash
        let computedHash = SHA256.hash(data: inputData)
        
        // Verify hash matches
        guard computedHash == powResult.hash else {
            print("❌ PoW verification failed: hash mismatch")
            return false
        }
        
        // Verify difficulty requirement
        let hashData = Data(computedHash)
        guard hasRequiredLeadingZeros(hashData, difficulty: powResult.difficulty) else {
            print("❌ PoW verification failed: insufficient difficulty")
            return false
        }
        
        print("✅ PoW verification passed")
        return true
    }
    
    /// Get current network difficulty
    public func getCurrentDifficulty() -> UInt8 {
        return currentDifficulty
    }
    
    /// Get statistics about recent PoW computations
    public func getStatistics() -> ProofOfWorkStatistics {
        statisticsLock.lock()
        defer { statisticsLock.unlock() }
        
        guard !powComputations.isEmpty else {
            return ProofOfWorkStatistics(
                currentDifficulty: currentDifficulty,
                averageComputeTime: 0,
                totalComputations: 0,
                targetComputeTime: targetComputeTime
            )
        }
        
        let averageTime = powComputations.reduce(0, +) / Double(powComputations.count)
        
        return ProofOfWorkStatistics(
            currentDifficulty: currentDifficulty,
            averageComputeTime: averageTime,
            totalComputations: powComputations.count,
            targetComputeTime: targetComputeTime
        )
    }
    
    // MARK: - Private Methods
    
    /// Check if hash has required number of leading zeros
    private func hasRequiredLeadingZeros(_ hashData: Data, difficulty: UInt8) -> Bool {
        guard difficulty > 0 else { return true }
        
        let requiredBytes = Int(difficulty / 8)
        let remainingBits = difficulty % 8
        
        // Check full zero bytes
        for i in 0..<requiredBytes {
            if hashData[i] != 0 {
                return false
            }
        }
        
        // Check remaining bits in the next byte
        if remainingBits > 0 && requiredBytes < hashData.count {
            let mask = UInt8(0xFF >> remainingBits)
            if (hashData[requiredBytes] & ~mask) != 0 {
                return false
            }
        }
        
        return true
    }
    
    /// Record computation time and adjust difficulty if needed
    private func recordComputationTime(_ time: TimeInterval) {
        statisticsLock.lock()
        defer { statisticsLock.unlock() }
        
        powComputations.append(time)
        
        // Keep only recent computations for difficulty adjustment
        if powComputations.count > difficultyAdjustmentWindow {
            powComputations.removeFirst()
        }
        
        // Adjust difficulty if we have enough samples
        if powComputations.count >= difficultyAdjustmentWindow {
            adjustDifficulty()
        }
    }
    
    /// Adjust difficulty based on recent computation times
    private func adjustDifficulty() {
        let averageTime = powComputations.reduce(0, +) / Double(powComputations.count)
        
        let oldDifficulty = currentDifficulty
        
        if averageTime < targetComputeTime * 0.5 && currentDifficulty < maxDifficulty {
            // Too fast, increase difficulty
            currentDifficulty += 1
            print("📈 PoW difficulty increased to \(currentDifficulty) (avg time: \(String(format: "%.2f", averageTime))s)")
        } else if averageTime > targetComputeTime * 2.0 && currentDifficulty > minDifficulty {
            // Too slow, decrease difficulty
            currentDifficulty -= 1
            print("📉 PoW difficulty decreased to \(currentDifficulty) (avg time: \(String(format: "%.2f", averageTime))s)")
        }
        
        // Clear statistics when difficulty changes
        if oldDifficulty != currentDifficulty {
            powComputations.removeAll()
        }
    }
}

// MARK: - Data Structures

/// Result of Proof of Work computation
public struct ProofOfWorkResult {
    public let nonce: UInt64
    public let hash: SHA256Digest
    public let difficulty: UInt8
    public let computeTime: TimeInterval
    
    public init(nonce: UInt64, hash: SHA256Digest, difficulty: UInt8, computeTime: TimeInterval) {
        self.nonce = nonce
        self.hash = hash
        self.difficulty = difficulty
        self.computeTime = computeTime
    }
    
    /// Serialize to data for network transmission
    public func toData() -> Data {
        var data = Data()
        data.append(Data(withUnsafeBytes(of: nonce.littleEndian) { Data($0) }))
        data.append(Data(hash))
        data.append(difficulty)
        return data
    }
    
    /// Deserialize from network data
    public static func fromData(_ data: Data) throws -> ProofOfWorkResult {
        guard data.count >= 41 else { // 8 + 32 + 1
            throw ProofOfWorkError.invalidData
        }
        
        let nonce = data.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        let hashData = data.subdata(in: 8..<40)
        let difficulty = data[40]
        
        let hash = SHA256Digest(data: hashData)
        
        return ProofOfWorkResult(nonce: nonce, hash: hash, difficulty: difficulty, computeTime: 0)
    }
}

/// Statistics about Proof of Work performance
public struct ProofOfWorkStatistics {
    public let currentDifficulty: UInt8
    public let averageComputeTime: TimeInterval
    public let totalComputations: Int
    public let targetComputeTime: TimeInterval
    
    public init(currentDifficulty: UInt8, averageComputeTime: TimeInterval, totalComputations: Int, targetComputeTime: TimeInterval) {
        self.currentDifficulty = currentDifficulty
        self.averageComputeTime = averageComputeTime
        self.totalComputations = totalComputations
        self.targetComputeTime = targetComputeTime
    }
    
    /// Human-readable description
    public var description: String {
        return "PoW Stats: difficulty \(currentDifficulty), avg time \(String(format: "%.2f", averageComputeTime))s, \(totalComputations) computations"
    }
}

/// Proof of Work related errors
public enum ProofOfWorkError: Error {
    case invalidData
    case computationFailed
    case verificationFailed
    
    public var localizedDescription: String {
        switch self {
        case .invalidData:
            return "Invalid Proof of Work data"
        case .computationFailed:
            return "Proof of Work computation failed"
        case .verificationFailed:
            return "Proof of Work verification failed"
        }
    }
}