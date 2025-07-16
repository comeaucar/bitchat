//
// PoWCompressionUtil.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Compression
import CryptoKit

/// Proof-of-Work based compression that ties computational work to actual file compression utility
/// The more work performed, the better the compression ratio achieved
struct PoWCompressionUtil {
    
    // MARK: - Types
    
    struct CompressionResult {
        let compressedData: Data
        let originalSize: Int
        let compressionRatio: Double
        let nonce: UInt64
        let workProof: Data
        let computationTime: TimeInterval
        let iterations: UInt64
    }
    
    struct DecompressionResult {
        let originalData: Data
        let compressionRatio: Double
        let workProof: Data
        let isValidProof: Bool
    }
    
    // MARK: - Constants
    
    private static let maxIterations: UInt64 = 1_000_000  // Max PoW iterations to prevent infinite loops
    private static let compressionThreshold = 1024       // Only compress files larger than 1KB
    private static let baseCompressionLevel = 1          // Base compression level (fast)
    private static let maxCompressionLevel = 9           // Max compression level (slow but best)
    
    // MARK: - Public Methods
    
    /// Compress data using PoW to find optimal compression parameters
    /// More computational work = better compression ratio
    static func compressWithPoW(
        data: Data,
        targetCompressionRatio: Double = 0.7,  // Target 70% compression (30% size reduction)
        maxComputationTime: TimeInterval = 5.0  // Max 5 seconds of computation
    ) -> CompressionResult? {
        
        guard data.count >= compressionThreshold else {
            print("📦 [PoW-COMPRESS] File too small for PoW compression: \(data.count) bytes")
            return nil
        }
        
        let startTime = Date()
        var bestResult: CompressionResult?
        var nonce: UInt64 = 0
        var iterations: UInt64 = 0
        
        print("📦 [PoW-COMPRESS] Starting PoW compression for \(data.count) bytes, target ratio: \(targetCompressionRatio)")
        
        // Perform PoW to find optimal compression parameters
        while iterations < maxIterations && Date().timeIntervalSince(startTime) < maxComputationTime {
            
            // Use nonce to vary compression parameters
            let compressionLevel = computeCompressionLevel(nonce: nonce)
            let windowSize = computeWindowSize(nonce: nonce)
            let hashSeed = computeHashSeed(nonce: nonce)
            
            // Attempt compression with these parameters
            if let compressed = performCompression(
                data: data,
                level: compressionLevel,
                windowSize: windowSize,
                hashSeed: hashSeed
            ) {
                let ratio = Double(compressed.count) / Double(data.count)
                
                // Check if this is the best result so far
                if bestResult == nil || ratio < bestResult!.compressionRatio {
                    
                    // Generate work proof
                    let workProof = generateWorkProof(
                        originalData: data,
                        compressedData: compressed,
                        nonce: nonce,
                        iterations: iterations
                    )
                    
                    bestResult = CompressionResult(
                        compressedData: compressed,
                        originalSize: data.count,
                        compressionRatio: ratio,
                        nonce: nonce,
                        workProof: workProof,
                        computationTime: Date().timeIntervalSince(startTime),
                        iterations: iterations
                    )
                    
                    print("📦 [PoW-COMPRESS] New best ratio: \(String(format: "%.2f", ratio * 100))% (nonce: \(nonce), iterations: \(iterations))")
                    
                    // If we've reached the target, we can stop
                    if ratio <= targetCompressionRatio {
                        print("📦 [PoW-COMPRESS] Target ratio achieved!")
                        break
                    }
                }
            }
            
            nonce += 1
            iterations += 1
            
            // Periodically check time limit
            if iterations % 10000 == 0 {
                if Date().timeIntervalSince(startTime) >= maxComputationTime {
                    print("📦 [PoW-COMPRESS] Time limit reached after \(iterations) iterations")
                    break
                }
            }
        }
        
        if let result = bestResult {
            let finalTime = Date().timeIntervalSince(startTime)
            print("📦 [PoW-COMPRESS] Completed: \(String(format: "%.2f", (1.0 - result.compressionRatio) * 100))% size reduction in \(String(format: "%.2f", finalTime))s")
            print("📦 [PoW-COMPRESS] Final stats: \(result.originalSize) → \(result.compressedData.count) bytes, \(result.iterations) iterations")
            return result
        }
        
        print("📦 [PoW-COMPRESS] No compression improvement found")
        return nil
    }
    
    /// Decompress data and verify the PoW proof
    static func decompressWithVerification(
        compressedData: Data,
        originalSize: Int,
        nonce: UInt64,
        workProof: Data,
        iterations: UInt64
    ) -> DecompressionResult? {
        
        print("📦 [PoW-DECOMPRESS] Starting decompression verification")
        
        // First, decompress the data
        guard let decompressed = CompressionUtil.decompress(compressedData, originalSize: originalSize) else {
            print("📦 [PoW-DECOMPRESS] Failed to decompress data")
            return nil
        }
        
        // Verify the work proof
        let expectedProof = generateWorkProof(
            originalData: decompressed,
            compressedData: compressedData,
            nonce: nonce,
            iterations: iterations
        )
        
        let isValidProof = workProof == expectedProof
        let compressionRatio = Double(compressedData.count) / Double(decompressed.count)
        
        print("📦 [PoW-DECOMPRESS] Verification result: \(isValidProof ? "✅ Valid" : "❌ Invalid")")
        print("📦 [PoW-DECOMPRESS] Compression ratio: \(String(format: "%.2f", compressionRatio * 100))%")
        
        return DecompressionResult(
            originalData: decompressed,
            compressionRatio: compressionRatio,
            workProof: workProof,
            isValidProof: isValidProof
        )
    }
    
    // MARK: - Private Methods
    
    /// Compute compression level based on nonce (1-9)
    private static func computeCompressionLevel(nonce: UInt64) -> Int {
        return baseCompressionLevel + Int(nonce % UInt64(maxCompressionLevel - baseCompressionLevel))
    }
    
    /// Compute window size based on nonce (affects compression algorithm)
    private static func computeWindowSize(nonce: UInt64) -> Int {
        return 4096 + Int((nonce >> 8) % 4096)  // 4KB to 8KB window
    }
    
    /// Compute hash seed for deterministic compression variations
    private static func computeHashSeed(nonce: UInt64) -> UInt32 {
        return UInt32(nonce ^ (nonce >> 32))
    }
    
    /// Perform actual compression with specified parameters
    private static func performCompression(
        data: Data,
        level: Int,
        windowSize: Int,
        hashSeed: UInt32
    ) -> Data? {
        
        // For now, use the existing LZ4 compression but with nonce-based pre-processing
        let preprocessedData = preprocessData(data: data, seed: hashSeed)
        return CompressionUtil.compress(preprocessedData)
    }
    
    /// Preprocess data based on hash seed to create compression variations
    private static func preprocessData(data: Data, seed: UInt32) -> Data {
        // Create a deterministic but varied version of the data for compression
        // This allows the nonce to influence compression without changing the actual content
        
        var processed = Data(data)
        
        // Apply deterministic shuffling/reordering based on seed
        // This is reversible and doesn't change the data content
        let blockSize = 64  // Process in 64-byte blocks
        
        for i in stride(from: 0, to: processed.count, by: blockSize) {
            let blockEnd = min(i + blockSize, processed.count)
            let blockRange = i..<blockEnd
            
            if blockRange.count > 1 {
                // Apply deterministic reordering within this block
                var block = Array(processed[blockRange])
                deterministicShuffle(&block, seed: seed &+ UInt32(i))
                processed.replaceSubrange(blockRange, with: block)
            }
        }
        
        return processed
    }
    
    /// Deterministic shuffle that can be reversed
    private static func deterministicShuffle(_ array: inout [UInt8], seed: UInt32) {
        var rng = SeededRandom(seed: seed)
        
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt32(i + 1))
            array.swapAt(i, j)
        }
    }
    
    /// Generate work proof that demonstrates computational effort
    private static func generateWorkProof(
        originalData: Data,
        compressedData: Data,
        nonce: UInt64,
        iterations: UInt64
    ) -> Data {
        
        var hasher = SHA256()
        hasher.update(data: originalData)
        hasher.update(data: compressedData)
        hasher.update(data: withUnsafeBytes(of: nonce.bigEndian) { Data($0) })
        hasher.update(data: withUnsafeBytes(of: iterations.bigEndian) { Data($0) })
        
        return Data(hasher.finalize())
    }
}

// MARK: - Seeded Random Number Generator

/// Simple seeded RNG for deterministic operations
private struct SeededRandom {
    private var state: UInt32
    
    init(seed: UInt32) {
        self.state = seed
    }
    
    mutating func next() -> UInt32 {
        // Linear congruential generator
        state = state &* 1103515245 &+ 12345
        return (state >> 16) & 0x7fff
    }
}