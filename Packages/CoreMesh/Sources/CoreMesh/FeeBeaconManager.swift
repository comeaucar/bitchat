import Foundation
import CoreBluetooth
import Combine

/// Protocol for battery level monitoring
public protocol BatteryLevelProvider {
    var batteryLevelDouble: Double { get }
    var batteryLevelPublisher: AnyPublisher<Double, Never> { get }
}

/// Manages fee beacon advertising and collection for the BitChat relay token system
public final class FeeBeaconManager {
    
    // MARK: - Properties
    
    /// Current minimum fee this node will accept for relaying (in µRLT)
    public private(set) var relayMinFee: UInt32 = 5000  // 0.005 RLT minimum (high enough to trigger PoW for most messages)
    
    /// Collected fee beacons from other nodes
    private var peerFeeBeacons: [String: FeeBeacon] = [:]
    private let peerFeeBeaconsLock = NSLock()
    
    /// Fee beacon update delegates
    public weak var delegate: FeeBeaconManagerDelegate?
    
    /// Fee calculator for adaptive pricing
    private let feeCalculator: FeeCalculator
    
    /// Battery level provider for adaptive fee adjustments
    private let batteryProvider: BatteryLevelProvider
    
    /// Cleanup timer for stale fee beacons
    private var cleanupTimer: Timer?
    
    /// Fee beacon expiration time (30 seconds)
    private let feeBeaconTTL: TimeInterval = 30.0
    
    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(feeCalculator: FeeCalculator, batteryProvider: BatteryLevelProvider) {
        self.feeCalculator = feeCalculator
        self.batteryProvider = batteryProvider
        
        // Start with adaptive base fee
        updateRelayMinFee()
        
        // Start cleanup timer
        startCleanupTimer()
        
        // Monitor battery changes
        observeBatteryChanges()
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    // MARK: - Fee Beacon Management
    
    /// Update our minimum relay fee based on current conditions
    public func updateRelayMinFee() {
        // Base fee from adaptive calculation
        let adaptiveBase = feeCalculator.getAdaptiveBaseFee()
        
        // Apply battery level multiplier
        let batteryMultiplier = getBatteryFeeMultiplier()
        
        // Apply network congestion multiplier
        let congestionMultiplier = getNetworkCongestionMultiplier()
        
        // Calculate new minimum fee
        let newMinFee = UInt32(Double(adaptiveBase) * batteryMultiplier * congestionMultiplier)
        
        // Ensure minimum threshold (high for PoW testing)
        self.relayMinFee = max(newMinFee, 5000)  // At least 5000 µRLT for PoW testing
        
        print("🏷️  Updated relay minimum fee to \(relayMinFee)µRLT (battery: \(String(format: "%.2f", batteryMultiplier))x, congestion: \(String(format: "%.2f", congestionMultiplier))x)")
        
        // Notify delegate of fee update
        delegate?.feeBeaconManager(self, didUpdateMinFee: relayMinFee)
    }
    
    /// Record a fee beacon from a peer
    public func recordFeeBeacon(from peerID: String, minFee: UInt32, rssi: Int?) {
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        let beacon = FeeBeacon(
            peerID: peerID,
            minFee: minFee,
            rssi: rssi,
            timestamp: Date()
        )
        
        peerFeeBeacons[peerID] = beacon
        
        print("📡 Recorded fee beacon from \(peerID): \(minFee)µRLT (RSSI: \(rssi ?? -999))")
        
        // Notify delegate
        delegate?.feeBeaconManager(self, didReceiveFeeBeacon: beacon)
    }
    
    /// Get fee beacon for a specific peer
    public func getFeeBeacon(for peerID: String) -> FeeBeacon? {
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        return peerFeeBeacons[peerID]
    }
    
    /// Get all current fee beacons
    public func getAllFeeBeacons() -> [FeeBeacon] {
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        return Array(peerFeeBeacons.values)
    }
    
    /// Calculate route cost based on collected fee beacons
    public func calculateRouteCost(for route: [String], messageSize: Int) -> RouteCostEstimate {
        var totalCost: UInt32 = 0
        var availableNodes: [String] = []
        var unavailableNodes: [String] = []
        
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        // Calculate cost for each hop in the route
        for peerID in route {
            if let beacon = peerFeeBeacons[peerID] {
                totalCost += beacon.minFee
                availableNodes.append(peerID)
            } else {
                // Use fallback cost for unknown peers
                totalCost += feeCalculator.getAdaptiveBaseFee()
                unavailableNodes.append(peerID)
            }
        }
        
        // Add size fee (charged once by sender)
        let sizeFee = UInt32((messageSize + 1023) / 1024) * 1000  // 1000µRLT per KB
        totalCost += sizeFee
        
        return RouteCostEstimate(
            route: route,
            totalCost: totalCost,
            sizeFee: sizeFee,
            hopCount: route.count,
            availableNodes: availableNodes,
            unavailableNodes: unavailableNodes,
            estimatedDeliveryTime: calculateEstimatedDeliveryTime(for: route)
        )
    }
    
    /// Get network fee statistics
    public func getNetworkFeeStats() -> NetworkFeeStats {
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        let fees = peerFeeBeacons.values.map { $0.minFee }
        
        guard !fees.isEmpty else {
            return NetworkFeeStats(
                peerCount: 0,
                averageFee: relayMinFee,
                minFee: relayMinFee,
                maxFee: relayMinFee,
                medianFee: relayMinFee
            )
        }
        
        let sortedFees = fees.sorted()
        let averageFee = fees.reduce(0) { $0 + $1 } / UInt32(fees.count)
        let minFee = sortedFees.first ?? 0
        let maxFee = sortedFees.last ?? 0
        let medianFee = sortedFees[sortedFees.count / 2]
        
        return NetworkFeeStats(
            peerCount: fees.count,
            averageFee: averageFee,
            minFee: minFee,
            maxFee: maxFee,
            medianFee: medianFee
        )
    }
    
    // MARK: - Fee Beacon Encoding/Decoding
    
    /// Encode fee beacon for Bluetooth advertising
    public func encodeFeeBeacon() -> Data {
        var data = Data()
        
        // Fee beacon magic bytes (2 bytes)
        data.append(contentsOf: [0xFE, 0xE1])
        
        // Minimum fee (4 bytes, little endian)
        var feeLE = relayMinFee.littleEndian
        withUnsafeBytes(of: &feeLE) { data.append(contentsOf: $0) }
        
        // Timestamp (4 bytes, little endian) - seconds since epoch
        let timestamp = UInt32(Date().timeIntervalSince1970)
        var timestampLE = timestamp.littleEndian
        withUnsafeBytes(of: &timestampLE) { data.append(contentsOf: $0) }
        
        // Battery level (1 byte, 0-255)
        let batteryLevel = UInt8(batteryProvider.batteryLevelDouble * 255)
        data.append(batteryLevel)
        
        // Network congestion (1 byte, 0-255)
        let congestion = UInt8(min(feeCalculator.getCurrentNetworkConditions().congestion * 255, 255))
        data.append(congestion)
        
        return data
    }
    
    /// Decode fee beacon from Bluetooth advertising data
    public static func decodeFeeBeacon(from data: Data, peerID: String, rssi: Int?) -> FeeBeacon? {
        guard data.count >= 12 else { return nil }
        
        // Check magic bytes
        guard data[0] == 0xFE && data[1] == 0xE1 else { return nil }
        
        // Extract minimum fee (4 bytes, little endian)
        let feeData = data.subdata(in: 2..<6)
        let minFee = feeData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        
        // Extract timestamp (4 bytes, little endian)
        let timestampData = data.subdata(in: 6..<10)
        let timestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        
        // Extract battery level (1 byte)
        let batteryLevel = Double(data[10]) / 255.0
        
        // Extract network congestion (1 byte)
        let congestion = Double(data[11]) / 255.0
        
        return FeeBeacon(
            peerID: peerID,
            minFee: minFee,
            rssi: rssi,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            batteryLevel: batteryLevel,
            congestion: congestion
        )
    }
    
    // MARK: - Private Methods
    
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.cleanupExpiredBeacons()
        }
    }
    
    private func cleanupExpiredBeacons() {
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        let now = Date()
        let expiredPeers = peerFeeBeacons.filter { _, beacon in
            now.timeIntervalSince(beacon.timestamp) > feeBeaconTTL
        }.keys
        
        for peerID in expiredPeers {
            peerFeeBeacons.removeValue(forKey: peerID)
            print("🗑️  Expired fee beacon from \(peerID)")
        }
    }
    
    private func observeBatteryChanges() {
        // Monitor battery level changes and update fee accordingly
        batteryProvider.batteryLevelPublisher
            .sink { [weak self] _ in
                self?.updateRelayMinFee()
            }
            .store(in: &cancellables)
    }
    
    private func getBatteryFeeMultiplier() -> Double {
        let batteryLevel = batteryProvider.batteryLevelDouble
        
        // Higher fees when battery is low (incentivize conservation)
        if batteryLevel < 0.2 {
            return 3.0  // 3x fee when battery < 20%
        } else if batteryLevel < 0.4 {
            return 2.0  // 2x fee when battery < 40%
        } else if batteryLevel < 0.6 {
            return 1.5  // 1.5x fee when battery < 60%
        } else {
            return 1.0  // Normal fee when battery is good
        }
    }
    
    private func getNetworkCongestionMultiplier() -> Double {
        let congestion = feeCalculator.getCurrentNetworkConditions().congestion
        
        // Higher fees during network congestion
        return 1.0 + (congestion * 1.5)  // 1.0x to 2.5x based on congestion
    }
    
    private func calculateEstimatedDeliveryTime(for route: [String]) -> TimeInterval {
        peerFeeBeaconsLock.lock()
        defer { peerFeeBeaconsLock.unlock() }
        
        var totalTime: TimeInterval = 0
        
        for peerID in route {
            if let beacon = peerFeeBeacons[peerID] {
                // Estimate delivery time based on RSSI and congestion
                let baseTime = 0.1  // 100ms base per hop
                let rssiDelay = beacon.rssi.map { max(0, Double(-$0 - 50) / 100.0) } ?? 0.1
                let congestionDelay = beacon.congestion * 0.5
                
                totalTime += baseTime + rssiDelay + congestionDelay
            } else {
                // Use default time for unknown peers
                totalTime += 0.2
            }
        }
        
        return totalTime
    }
}

// MARK: - Data Structures

/// Represents a fee beacon from a peer
public struct FeeBeacon {
    public let peerID: String
    public let minFee: UInt32  // µRLT
    public let rssi: Int?
    public let timestamp: Date
    public let batteryLevel: Double
    public let congestion: Double
    
    public init(peerID: String, minFee: UInt32, rssi: Int?, timestamp: Date, batteryLevel: Double = 1.0, congestion: Double = 0.0) {
        self.peerID = peerID
        self.minFee = minFee
        self.rssi = rssi
        self.timestamp = timestamp
        self.batteryLevel = batteryLevel
        self.congestion = congestion
    }
}

/// Route cost estimate based on fee beacons
public struct RouteCostEstimate {
    public let route: [String]
    public let totalCost: UInt32  // µRLT
    public let sizeFee: UInt32    // µRLT
    public let hopCount: Int
    public let availableNodes: [String]
    public let unavailableNodes: [String]
    public let estimatedDeliveryTime: TimeInterval
    
    public init(route: [String], totalCost: UInt32, sizeFee: UInt32, hopCount: Int, availableNodes: [String], unavailableNodes: [String], estimatedDeliveryTime: TimeInterval) {
        self.route = route
        self.totalCost = totalCost
        self.sizeFee = sizeFee
        self.hopCount = hopCount
        self.availableNodes = availableNodes
        self.unavailableNodes = unavailableNodes
        self.estimatedDeliveryTime = estimatedDeliveryTime
    }
    
    /// Cost per hop average
    public var averageCostPerHop: UInt32 {
        let hopCost = totalCost - sizeFee
        return hopCount > 0 ? hopCost / UInt32(hopCount) : 0
    }
    
    /// Route reliability score (0.0 to 1.0)
    public var reliabilityScore: Double {
        guard hopCount > 0 else { return 1.0 }
        return Double(availableNodes.count) / Double(hopCount)
    }
}

/// Network fee statistics
public struct NetworkFeeStats {
    public let peerCount: Int
    public let averageFee: UInt32
    public let minFee: UInt32
    public let maxFee: UInt32
    public let medianFee: UInt32
    
    /// Human-readable description
    public var description: String {
        return "Network fees: \(peerCount) peers, avg \(averageFee)µRLT, range \(minFee)-\(maxFee)µRLT"
    }
}

// MARK: - Delegate Protocol

public protocol FeeBeaconManagerDelegate: AnyObject {
    func feeBeaconManager(_ manager: FeeBeaconManager, didUpdateMinFee newFee: UInt32)
    func feeBeaconManager(_ manager: FeeBeaconManager, didReceiveFeeBeacon beacon: FeeBeacon)
} 