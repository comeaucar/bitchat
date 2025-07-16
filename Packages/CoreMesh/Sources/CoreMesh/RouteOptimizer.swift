import Foundation

/// Optimizes routing based on cost, speed, and user preferences
public final class RouteOptimizer {
    
    // MARK: - Properties
    
    /// Fee beacon manager for cost information
    private let feeBeaconManager: FeeBeaconManager
    
    /// Route cache to avoid recalculating frequently used routes
    private var routeCache: [String: CachedRoute] = [:]
    private let routeCacheLock = NSLock()
    
    /// Maximum cache age (5 minutes)
    private let maxCacheAge: TimeInterval = 300.0
    
    // MARK: - Initialization
    
    public init(feeBeaconManager: FeeBeaconManager) {
        self.feeBeaconManager = feeBeaconManager
    }
    
    // MARK: - Route Optimization
    
    /// Find optimal route based on user preferences
    /// - Parameters:
    ///   - availablePeers: List of available peer IDs
    ///   - destination: Target destination (for private messages)
    ///   - messageSize: Size of the message in bytes
    ///   - preference: User's routing preference (cost vs speed)
    ///   - maxHops: Maximum number of hops allowed
    /// - Returns: Optimized route and its cost estimate
    public func findOptimalRoute(
        availablePeers: [String],
        destination: String? = nil,
        messageSize: Int,
        preference: RoutingPreference,
        maxHops: Int = 7
    ) -> OptimizedRoute? {
        
        // Check cache first
        let cacheKey = createCacheKey(
            peers: availablePeers,
            destination: destination,
            messageSize: messageSize,
            preference: preference
        )
        
        if let cachedRoute = getCachedRoute(key: cacheKey) {
            //print("📍 Using cached route: \(cachedRoute.route.count) hops, \(cachedRoute.cost)µRLT")
            return OptimizedRoute(
                route: cachedRoute.route,
                totalCost: cachedRoute.cost,
                estimatedDeliveryTime: cachedRoute.estimatedDeliveryTime,
                reliabilityScore: cachedRoute.reliabilityScore,
                routingStrategy: preference.strategy,
                alternativeRoutes: []
            )
        }
        
        // Generate possible routes
        let possibleRoutes = generatePossibleRoutes(
            availablePeers: availablePeers,
            destination: destination,
            maxHops: maxHops
        )
        
        guard !possibleRoutes.isEmpty else {
            print("❌ No possible routes found")
            return nil
        }
        
        // Evaluate each route
        let evaluatedRoutes = possibleRoutes.compactMap { route in
            evaluateRoute(route: route, messageSize: messageSize, preference: preference)
        }
        
        guard !evaluatedRoutes.isEmpty else {
            print("❌ No viable routes after evaluation")
            return nil
        }
        
        // Select best route based on preference
        let bestRoute = selectBestRoute(from: evaluatedRoutes, preference: preference)
        
        // Cache the result
        cacheRoute(key: cacheKey, route: bestRoute)
        
        // Generate alternative routes
        let alternatives = evaluatedRoutes
            .filter { $0.route != bestRoute.route }
            .sorted { $0.totalScore > $1.totalScore }
            .prefix(3)
            .map { $0.toOptimizedRoute() }
        
        let optimizedRoute = OptimizedRoute(
            route: bestRoute.route,
            totalCost: bestRoute.totalCost,
            estimatedDeliveryTime: bestRoute.estimatedDeliveryTime,
            reliabilityScore: bestRoute.reliabilityScore,
            routingStrategy: preference.strategy,
            alternativeRoutes: Array(alternatives)
        )
        
        //print("📍 Selected route: \(bestRoute.route.count) hops, \(bestRoute.totalCost)µRLT, \(String(format: "%.2f", bestRoute.estimatedDeliveryTime))s")
        
        return optimizedRoute
    }
    
    /// Calculate route cost for a specific path
    /// - Parameters:
    ///   - route: Array of peer IDs representing the route
    ///   - messageSize: Size of the message in bytes
    /// - Returns: Route cost estimate
    public func calculateRouteCost(for route: [String], messageSize: Int) -> RouteCostEstimate? {
        // Calculate basic cost estimate
        let baseFee: UInt32 = 50 // Base fee in µRLT
        let hopFee = UInt32(route.count) * 10 // 10µRLT per hop
        let sizeFee = UInt32(messageSize / 100) * 5 // 5µRLT per 100 bytes
        let totalCost = baseFee + hopFee + sizeFee
        
        return RouteCostEstimate(
            route: route,
            totalCost: totalCost,
            sizeFee: sizeFee,
            hopCount: route.count,
            availableNodes: route, // Assume all nodes in route are available
            unavailableNodes: [],
            estimatedDeliveryTime: Double(route.count) * 0.5 // 0.5s per hop
        )
    }
    
    /// Get route recommendations based on different preferences
    /// - Parameters:
    ///   - availablePeers: List of available peer IDs
    ///   - messageSize: Size of the message in bytes
    /// - Returns: Dictionary of route recommendations by preference
    public func getRouteRecommendations(
        availablePeers: [String],
        messageSize: Int
    ) -> [RoutingPreference: OptimizedRoute] {
        
        var recommendations: [RoutingPreference: OptimizedRoute] = [:]
        
        let preferences: [RoutingPreference] = [.cheapest, .balanced, .fastest]
        
        for preference in preferences {
            if let route = findOptimalRoute(
                availablePeers: availablePeers,
                destination: nil,
                messageSize: messageSize,
                preference: preference
            ) {
                recommendations[preference] = route
            }
        }
        
        return recommendations
    }
    
    // MARK: - Route Generation
    
    /// Generate possible routes to reach peers
    private func generatePossibleRoutes(
        availablePeers: [String],
        destination: String?,
        maxHops: Int
    ) -> [[String]] {
        var routes: [[String]] = []
        
        // Direct routes (1 hop)
        for peer in availablePeers {
            if let destination = destination {
                if peer == destination {
                    routes.append([peer])
                }
            } else {
                // For broadcast messages, each peer is a potential route
                routes.append([peer])
            }
        }
        
        // Multi-hop routes (2+ hops)
        // For simplicity, we'll create routes by combining peers
        // In a real implementation, this would use network topology
        if maxHops > 1 && availablePeers.count >= 2 {
            // Generate 2-hop routes
            for i in 0..<availablePeers.count {
                for j in 0..<availablePeers.count {
                    if i != j {
                        let route = [availablePeers[i], availablePeers[j]]
                        if destination == nil || route.contains(destination!) {
                            routes.append(route)
                        }
                    }
                }
            }
        }
        
        // Remove duplicates and sort by length
        let uniqueRoutes = Array(Set(routes.map { $0.joined(separator: "->") }))
            .compactMap { $0.split(separator: "->").map(String.init) }
            .sorted { $0.count < $1.count }
        
        return uniqueRoutes
    }
    
    /// Evaluate a route based on cost, speed, and reliability
    private func evaluateRoute(
        route: [String],
        messageSize: Int,
        preference: RoutingPreference
    ) -> EvaluatedRoute? {
        
        guard let costEstimate = calculateRouteCost(for: route, messageSize: messageSize) else {
            return nil
        }
        
        // Calculate additional metrics
        let reliabilityScore = calculateReliabilityScore(for: route)
        let networkQuality = calculateNetworkQuality(for: route)
        
        // Calculate total score based on preference
        let totalScore = calculateTotalScore(
            cost: costEstimate.totalCost,
            deliveryTime: costEstimate.estimatedDeliveryTime,
            reliability: reliabilityScore,
            networkQuality: networkQuality,
            preference: preference
        )
        
        return EvaluatedRoute(
            route: route,
            totalCost: costEstimate.totalCost,
            estimatedDeliveryTime: costEstimate.estimatedDeliveryTime,
            reliabilityScore: reliabilityScore,
            networkQuality: networkQuality,
            totalScore: totalScore,
            costEstimate: costEstimate
        )
    }
    
    /// Select the best route from evaluated options
    private func selectBestRoute(
        from routes: [EvaluatedRoute],
        preference: RoutingPreference
    ) -> EvaluatedRoute {
        
        return routes.max { route1, route2 in
            route1.totalScore < route2.totalScore
        } ?? routes.first!
    }
    
    // MARK: - Scoring and Metrics
    
    /// Calculate reliability score for a route
    private func calculateReliabilityScore(for route: [String]) -> Double {
        let feeBeacons = feeBeaconManager.getAllFeeBeacons()
        let beaconMap = Dictionary(uniqueKeysWithValues: feeBeacons.map { ($0.peerID, $0) })
        
        var reliabilityScore = 1.0
        
        for peerID in route {
            if let beacon = beaconMap[peerID] {
                // Factor in RSSI and battery level
                let rssiScore = beacon.rssi.map { Double(max(-100, $0) + 100) / 100.0 } ?? 0.5
                let batteryScore = beacon.batteryLevel
                let peerReliability = (rssiScore * 0.6) + (batteryScore * 0.4)
                
                reliabilityScore *= peerReliability
            } else {
                // Unknown peer, assume moderate reliability
                reliabilityScore *= 0.7
            }
        }
        
        return reliabilityScore
    }
    
    /// Calculate network quality for a route
    private func calculateNetworkQuality(for route: [String]) -> Double {
        let feeBeacons = feeBeaconManager.getAllFeeBeacons()
        let beaconMap = Dictionary(uniqueKeysWithValues: feeBeacons.map { ($0.peerID, $0) })
        
        var totalCongestion = 0.0
        var validBeacons = 0
        
        for peerID in route {
            if let beacon = beaconMap[peerID] {
                totalCongestion += beacon.congestion
                validBeacons += 1
            }
        }
        
        guard validBeacons > 0 else { return 0.5 }
        
        let averageCongestion = totalCongestion / Double(validBeacons)
        return 1.0 - averageCongestion  // Lower congestion = higher quality
    }
    
    /// Calculate total score for a route
    private func calculateTotalScore(
        cost: UInt32,
        deliveryTime: TimeInterval,
        reliability: Double,
        networkQuality: Double,
        preference: RoutingPreference
    ) -> Double {
        
        // Normalize values (0-1 scale)
        let normalizedCost = 1.0 / (Double(cost) / 1000.0 + 1.0)  // Lower cost = higher score
        let normalizedTime = 1.0 / (deliveryTime + 1.0)  // Lower time = higher score
        
        switch preference {
        case .cheapest:
            return (normalizedCost * 0.6) + (reliability * 0.2) + (networkQuality * 0.2)
        case .fastest:
            return (normalizedTime * 0.6) + (reliability * 0.2) + (networkQuality * 0.2)
        case .balanced:
            return (normalizedCost * 0.3) + (normalizedTime * 0.3) + (reliability * 0.2) + (networkQuality * 0.2)
        case .reliable:
            return (reliability * 0.5) + (networkQuality * 0.3) + (normalizedCost * 0.2)
        }
    }
    
    // MARK: - Caching
    
    /// Create cache key for route
    private func createCacheKey(
        peers: [String],
        destination: String?,
        messageSize: Int,
        preference: RoutingPreference
    ) -> String {
        let peersKey = peers.sorted().joined(separator: ",")
        let destKey = destination ?? "broadcast"
        let sizeKey = String(messageSize / 1024)  // KB
        let prefKey = preference.rawValue
        
        return "\(peersKey)|\(destKey)|\(sizeKey)|\(prefKey)"
    }
    
    /// Get cached route if available and fresh
    private func getCachedRoute(key: String) -> CachedRoute? {
        routeCacheLock.lock()
        defer { routeCacheLock.unlock() }
        
        guard let cachedRoute = routeCache[key] else { return nil }
        
        // Check if cache is still fresh
        if Date().timeIntervalSince(cachedRoute.timestamp) > maxCacheAge {
            routeCache.removeValue(forKey: key)
            return nil
        }
        
        return cachedRoute
    }
    
    /// Cache a route result
    private func cacheRoute(key: String, route: EvaluatedRoute) {
        routeCacheLock.lock()
        defer { routeCacheLock.unlock() }
        
        let cachedRoute = CachedRoute(
            route: route.route,
            cost: route.totalCost,
            estimatedDeliveryTime: route.estimatedDeliveryTime,
            reliabilityScore: route.reliabilityScore,
            timestamp: Date()
        )
        
        routeCache[key] = cachedRoute
        
        // Cleanup old cache entries
        if routeCache.count > 100 {
            let sortedEntries = routeCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let toRemove = sortedEntries.prefix(20).map { $0.key }
            for key in toRemove {
                routeCache.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - Data Structures

/// Routing preference for message delivery
public enum RoutingPreference: String, CaseIterable {
    case cheapest = "cheapest"
    case fastest = "fastest"
    case balanced = "balanced"
    case reliable = "reliable"
    
    var strategy: String {
        switch self {
        case .cheapest: return "Minimize cost"
        case .fastest: return "Minimize delivery time"
        case .balanced: return "Balance cost and speed"
        case .reliable: return "Maximize reliability"
        }
    }
    
    var description: String {
        switch self {
        case .cheapest: return "Cheapest route (may be slower)"
        case .fastest: return "Fastest route (may cost more)"
        case .balanced: return "Balanced cost and speed"
        case .reliable: return "Most reliable route"
        }
    }
}

/// Evaluated route with all metrics
private struct EvaluatedRoute {
    let route: [String]
    let totalCost: UInt32
    let estimatedDeliveryTime: TimeInterval
    let reliabilityScore: Double
    let networkQuality: Double
    let totalScore: Double
    let costEstimate: RouteCostEstimate
    
    func toOptimizedRoute() -> OptimizedRoute {
        return OptimizedRoute(
            route: route,
            totalCost: totalCost,
            estimatedDeliveryTime: estimatedDeliveryTime,
            reliabilityScore: reliabilityScore,
            routingStrategy: "Evaluated",
            alternativeRoutes: []
        )
    }
}

/// Cached route information
private struct CachedRoute {
    let route: [String]
    let cost: UInt32
    let estimatedDeliveryTime: TimeInterval
    let reliabilityScore: Double
    let timestamp: Date
}


/// Final optimized route with alternatives
public struct OptimizedRoute {
    public let route: [String]
    public let totalCost: UInt32
    public let estimatedDeliveryTime: TimeInterval
    public let reliabilityScore: Double
    public let routingStrategy: String
    public let alternativeRoutes: [OptimizedRoute]
    
    public init(
        route: [String],
        totalCost: UInt32,
        estimatedDeliveryTime: TimeInterval,
        reliabilityScore: Double,
        routingStrategy: String,
        alternativeRoutes: [OptimizedRoute]
    ) {
        self.route = route
        self.totalCost = totalCost
        self.estimatedDeliveryTime = estimatedDeliveryTime
        self.reliabilityScore = reliabilityScore
        self.routingStrategy = routingStrategy
        self.alternativeRoutes = alternativeRoutes
    }
    
    /// Cost in RLT for display
    public var costInRLT: Double {
        return Double(totalCost) / 1_000_000.0
    }
    
    /// Human-readable description
    public var description: String {
        return "Route: \(route.count) hops, \(String(format: "%.6f", costInRLT)) RLT, \(String(format: "%.2f", estimatedDeliveryTime))s"
    }
} 