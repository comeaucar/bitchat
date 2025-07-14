import Foundation

/// Fee calculation engine for the BitChat crypto system
public final class FeeCalculator {
    
    // Base fee configuration (in µRLT)
    private let baseFeePerHop: UInt32 = 100  // 0.0001 RLT per hop
    private let baseFeePerKB: UInt32 = 1000  // 0.001 RLT per KB
    private let minFeePerMessage: UInt32 = 50  // 0.00005 RLT minimum
    
    // Network conditions
    private var networkCongestion: Double = 0.5  // 0.0 to 1.0
    private var averageLatency: TimeInterval = 0.1  // seconds
    
    // Fee history for adaptive pricing
    private var recentFees: [UInt32] = []
    private let maxFeeHistory = 1000
    private var feeHistoryLock = NSLock()
    
    public init() {}
    
    // MARK: - Fee Calculation
    
    /// Calculate fee for a message based on size, TTL, and network conditions
    public func calculateFee(
        messageSize: Int,
        ttl: UInt8,
        priority: MessagePriority = .normal,
        networkConditions: NetworkConditions? = nil
    ) -> FeeCalculation {
        let conditions = networkConditions ?? getCurrentNetworkConditions()
        
        // Base fee calculation
        let sizeInKB = max(1, (messageSize + 1023) / 1024)  // Round up to nearest KB
        let sizeFee = UInt32(sizeInKB) * baseFeePerKB
        let hopFee = UInt32(ttl) * baseFeePerHop
        
        var totalFee = sizeFee + hopFee
        
        // Apply priority multiplier
        totalFee = UInt32(Double(totalFee) * priority.multiplier)
        
        // Apply network congestion multiplier
        let congestionMultiplier = 1.0 + (conditions.congestion * 2.0)  // 1.0x to 3.0x
        totalFee = UInt32(Double(totalFee) * congestionMultiplier)
        
        // Apply latency penalty for high-priority messages
        if priority == .high && conditions.averageLatency > 0.5 {
            let latencyPenalty = conditions.averageLatency * 100.0  // Up to 50% increase
            totalFee = UInt32(Double(totalFee) * (1.0 + latencyPenalty))
        }
        
        // Ensure minimum fee
        totalFee = max(totalFee, minFeePerMessage)
        
        // Create fee calculation result
        return FeeCalculation(
            totalFee: totalFee,
            baseFee: sizeFee + hopFee,
            sizeFee: sizeFee,
            hopFee: hopFee,
            priorityMultiplier: priority.multiplier,
            congestionMultiplier: congestionMultiplier,
            messageSize: messageSize,
            ttl: ttl,
            priority: priority,
            estimatedDeliveryTime: estimateDeliveryTime(ttl: ttl, conditions: conditions)
        )
    }
    
    /// Calculate total cost for a message route
    public func calculateRouteCost(
        messageSize: Int,
        route: [String],  // peer IDs in route
        priority: MessagePriority = .normal
    ) -> RouteCostCalculation {
        let hopCount = max(1, route.count - 1)  // Number of hops between peers
        let fee = calculateFee(
            messageSize: messageSize,
            ttl: UInt8(hopCount),
            priority: priority
        )
        
        return RouteCostCalculation(
            route: route,
            hopCount: hopCount,
            feeCalculation: fee,
            estimatedCost: fee.totalFee,
            qualityScore: calculateRouteQuality(route: route)
        )
    }
    
    /// Get adaptive fee recommendation based on recent network activity
    public func getAdaptiveBaseFee() -> UInt32 {
        feeHistoryLock.lock()
        defer { feeHistoryLock.unlock() }
        
        guard !recentFees.isEmpty else {
            return baseFeePerHop
        }
        
        // Calculate EMA (Exponential Moving Average) of last 1000 fees
        let recentFeesCount = min(recentFees.count, 100)  // Use last 100 fees
        let relevantFees = Array(recentFees.suffix(recentFeesCount))
        
        let sum = relevantFees.reduce(0, +)
        let average = sum / UInt32(relevantFees.count)
        
        // Return 80% of average to encourage usage
        return UInt32(Double(average) * 0.8)
    }
    
    /// Record a fee that was actually paid
    public func recordPaidFee(_ fee: UInt32) {
        feeHistoryLock.lock()
        defer { feeHistoryLock.unlock() }
        
        recentFees.append(fee)
        
        // Keep only recent history
        if recentFees.count > maxFeeHistory {
            recentFees.removeFirst(recentFees.count - maxFeeHistory)
        }
    }
    
    // MARK: - Network Conditions
    
    /// Update network conditions based on recent activity
    public func updateNetworkConditions(
        congestion: Double,
        averageLatency: TimeInterval
    ) {
        self.networkCongestion = max(0.0, min(1.0, congestion))
        self.averageLatency = max(0.01, averageLatency)
        
        print("📊 Network conditions updated: congestion=\(String(format: "%.2f", congestion)), latency=\(String(format: "%.3f", averageLatency))s")
    }
    
    /// Get current network conditions
    public func getCurrentNetworkConditions() -> NetworkConditions {
        return NetworkConditions(
            congestion: networkCongestion,
            averageLatency: averageLatency
        )
    }
    
    // MARK: - Private Helper Methods
    
    /// Estimate delivery time based on TTL and network conditions
    private func estimateDeliveryTime(ttl: UInt8, conditions: NetworkConditions) -> TimeInterval {
        let baseTimePerHop = 0.1  // 100ms per hop in ideal conditions
        let congestionDelay = conditions.congestion * 0.5  // Up to 500ms delay per hop
        let latencyFactor = conditions.averageLatency * 2.0  // Latency affects all hops
        
        let timePerHop = baseTimePerHop + congestionDelay + latencyFactor
        return TimeInterval(ttl) * timePerHop
    }
    
    /// Calculate route quality score (0.0 to 1.0)
    private func calculateRouteQuality(route: [String]) -> Double {
        // Simple quality calculation based on route length
        // In a real implementation, this would consider peer reliability, RSSI, etc.
        let idealHops = 3.0
        let actualHops = Double(max(1, route.count - 1))
        
        if actualHops <= idealHops {
            return 1.0 - (actualHops - 1.0) / (idealHops - 1.0) * 0.3  // 1.0 to 0.7
        } else {
            return 0.7 * (idealHops / actualHops)  // Decreases with more hops
        }
    }
}

// MARK: - Data Structures

// NetworkConditions is now in CoreMesh.swift

/// Fee calculation result
public struct FeeCalculation {
    public let totalFee: UInt32  // µRLT
    public let baseFee: UInt32   // µRLT
    public let sizeFee: UInt32   // µRLT
    public let hopFee: UInt32    // µRLT
    public let priorityMultiplier: Double
    public let congestionMultiplier: Double
    public let messageSize: Int  // bytes
    public let ttl: UInt8
    public let priority: MessagePriority
    public let estimatedDeliveryTime: TimeInterval
    
    /// Fee in RLT (for display)
    public var feeInRLT: Double {
        return Double(totalFee) / Double(WalletManager.microRLTPerRLT)
    }
    
    /// Human-readable fee description
    public var description: String {
        return String(format: "%.6f RLT (%d µRLT) for %d bytes, %d hops, %@ priority",
                     feeInRLT, totalFee, messageSize, ttl, priority.rawValue)
    }
}

/// Route cost calculation result
public struct RouteCostCalculation {
    let route: [String]
    let hopCount: Int
    let feeCalculation: FeeCalculation
    let estimatedCost: UInt32  // µRLT
    let qualityScore: Double   // 0.0 to 1.0
    
    /// Cost-effectiveness score (higher is better)
    public var costEffectiveness: Double {
        return qualityScore / (Double(estimatedCost) / 1000.0)  // Quality per milli-RLT
    }
}

// MARK: - Fee Strategies

/// Strategy for choosing fees based on user preferences
public enum FeeStrategy {
    case minimize    // Minimize cost
    case balance     // Balance cost and speed
    case maximize    // Maximize speed
    case custom(UInt32)  // Custom fee per hop
    
    func calculateFee(
        using calculator: FeeCalculator,
        messageSize: Int,
        ttl: UInt8,
        conditions: NetworkConditions
    ) -> UInt32 {
        switch self {
        case .minimize:
            let baseFee = calculator.calculateFee(
                messageSize: messageSize,
                ttl: ttl,
                priority: .low,
                networkConditions: conditions
            )
            return UInt32(Double(baseFee.totalFee) * 0.8)  // 20% discount
            
        case .balance:
            return calculator.calculateFee(
                messageSize: messageSize,
                ttl: ttl,
                priority: .normal,
                networkConditions: conditions
            ).totalFee
            
        case .maximize:
            return calculator.calculateFee(
                messageSize: messageSize,
                ttl: ttl,
                priority: .high,
                networkConditions: conditions
            ).totalFee
            
        case .custom(let feePerHop):
            return feePerHop * UInt32(ttl)
        }
    }
} 