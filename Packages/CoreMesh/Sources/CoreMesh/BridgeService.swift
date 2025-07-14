import Foundation
import Network
import Crypto

/// Service for managing bridge nodes and internet connectivity
/// Implements bridge infrastructure for connecting local mesh to global networks
public final class BridgeService {
    
    // MARK: - Properties
    
    /// Network monitor for connectivity detection
    private let networkMonitor = NWPathMonitor()
    
    /// Current bridge status
    @Published public private(set) var bridgeStatus: BridgeStatus = .offline
    
    /// List of available bridge nodes
    @Published public private(set) var availableBridges: [BridgeNode] = []
    
    /// Current bridge node (if connected)
    @Published public private(set) var currentBridge: BridgeNode?
    
    /// Bridge service configuration
    private let config: BridgeConfig
    
    /// Queue for bridge operations
    private let bridgeQueue = DispatchQueue(label: "bitchat.bridge", qos: .background)
    
    /// Delegate for bridge events
    public weak var delegate: BridgeServiceDelegate?
    
    /// Discovery timer for finding bridge nodes
    private var discoveryTimer: Timer?
    
    /// Heartbeat timer for maintaining bridge connections
    private var heartbeatTimer: Timer?
    
    /// Bridge node registry
    private var bridgeRegistry: [String: BridgeNode] = [:]
    private let registryLock = NSLock()
    
    /// Last connectivity check time
    private var lastConnectivityCheck: Date = Date()
    
    /// Connectivity statistics
    private var connectivityStats = ConnectivityStatistics()
    
    // MARK: - Initialization
    
    public init(config: BridgeConfig = BridgeConfig()) {
        self.config = config
        
        print("🌉 BridgeService initialized")
        
        setupNetworkMonitoring()
        
        if config.enableBridgeDiscovery {
            startBridgeDiscovery()
        }
    }
    
    deinit {
        stopNetworkMonitoring()
        stopBridgeDiscovery()
    }
    
    // MARK: - Public Methods
    
    /// Start bridge service
    public func startBridgeService() {
        print("🌉 Starting bridge service...")
        
        startNetworkMonitoring()
        
        if config.enableBridgeDiscovery {
            startBridgeDiscovery()
        }
        
        // Perform initial connectivity check
        checkInternetConnectivity()
    }
    
    /// Stop bridge service
    public func stopBridgeService() {
        print("🌉 Stopping bridge service...")
        
        stopNetworkMonitoring()
        stopBridgeDiscovery()
        
        // Disconnect from current bridge
        if let currentBridge = currentBridge {
            disconnectFromBridge(currentBridge)
        }
    }
    
    /// Manually check internet connectivity
    public func checkInternetConnectivity() {
        bridgeQueue.async { [weak self] in
            self?.performConnectivityCheck()
        }
    }
    
    /// Connect to a specific bridge node
    public func connectToBridge(_ bridgeNode: BridgeNode) {
        bridgeQueue.async { [weak self] in
            self?.performBridgeConnection(bridgeNode)
        }
    }
    
    /// Disconnect from current bridge
    public func disconnectFromCurrentBridge() {
        guard let currentBridge = currentBridge else { return }
        disconnectFromBridge(currentBridge)
    }
    
    /// Register a bridge node
    public func registerBridgeNode(_ bridgeNode: BridgeNode) {
        registryLock.lock()
        defer { registryLock.unlock() }
        
        bridgeRegistry[bridgeNode.id] = bridgeNode
        updateAvailableBridges()
        
        print("🌉 Bridge node registered: \(bridgeNode.id)")
    }
    
    /// Unregister a bridge node
    public func unregisterBridgeNode(_ bridgeNodeId: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        
        bridgeRegistry.removeValue(forKey: bridgeNodeId)
        updateAvailableBridges()
        
        print("🌉 Bridge node unregistered: \(bridgeNodeId)")
    }
    
    /// Get connectivity statistics
    public func getConnectivityStatistics() -> ConnectivityStatistics {
        return connectivityStats
    }
    
    /// Check if device can act as a bridge
    public func canActAsBridge() -> Bool {
        return bridgeStatus == .hasInternet && config.enableBridgeHosting
    }
    
    /// Start hosting bridge service
    public func startHostingBridge() {
        guard canActAsBridge() else {
            print("❌ Cannot start hosting bridge - requirements not met")
            return
        }
        
        print("🌉 Starting bridge hosting...")
        
        // Create bridge node for this device
        let bridgeNode = BridgeNode(
            id: "bridge-\(UUID().uuidString)",
            address: "local",
            port: config.bridgePort,
            publicKey: generateBridgePublicKey(),
            capabilities: [.internetAccess, .meshRelay],
            quality: calculateBridgeQuality(),
            lastSeen: Date()
        )
        
        // Register as available bridge
        registerBridgeNode(bridgeNode)
        
        // Update status
        bridgeStatus = .hostingBridge
        
        // Start heartbeat
        startHeartbeat()
        
        delegate?.bridgeService(self, didStartHostingBridge: bridgeNode)
    }
    
    /// Stop hosting bridge service
    public func stopHostingBridge() {
        print("🌉 Stopping bridge hosting...")
        
        stopHeartbeat()
        
        // Update status
        updateBridgeStatus()
        
        delegate?.bridgeService(self, didStopHostingBridge: nil)
    }
    
    // MARK: - Private Methods
    
    /// Setup network monitoring
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(path)
        }
    }
    
    /// Start network monitoring
    private func startNetworkMonitoring() {
        networkMonitor.start(queue: bridgeQueue)
    }
    
    /// Stop network monitoring
    private func stopNetworkMonitoring() {
        networkMonitor.cancel()
    }
    
    /// Handle network path updates
    private func handleNetworkPathUpdate(_ path: NWPath) {
        let wasConnected = bridgeStatus != .offline
        
        // Update bridge status based on connectivity
        if path.status == .satisfied {
            // Check if we have internet access
            checkInternetConnectivity()
        } else {
            bridgeStatus = .offline
            currentBridge = nil
        }
        
        // Notify delegate of status change
        if wasConnected != (bridgeStatus != .offline) {
            delegate?.bridgeService(self, didUpdateStatus: bridgeStatus)
        }
        
        // Update connectivity statistics
        connectivityStats.updateConnectivity(path.status == .satisfied)
    }
    
    /// Perform connectivity check
    private func performConnectivityCheck() {
        guard Date().timeIntervalSince(lastConnectivityCheck) > 30.0 else {
            return  // Rate limit connectivity checks
        }
        
        lastConnectivityCheck = Date()
        
        // Simulate connectivity check
        // In a real implementation, this would ping known internet hosts
        let hasInternet = networkMonitor.currentPath.status == .satisfied
        
        let previousStatus = bridgeStatus
        
        if hasInternet {
            if bridgeStatus == .offline {
                bridgeStatus = .hasInternet
            }
        } else {
            bridgeStatus = .offline
            currentBridge = nil
        }
        
        // Notify delegate if status changed
        if previousStatus != bridgeStatus {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.bridgeService(self, didUpdateStatus: self.bridgeStatus)
            }
        }
        
        print("🌉 Connectivity check: \(bridgeStatus)")
    }
    
    /// Start bridge discovery
    private func startBridgeDiscovery() {
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: config.discoveryInterval, repeats: true) { [weak self] _ in
            self?.performBridgeDiscovery()
        }
        
        // Perform immediate discovery
        performBridgeDiscovery()
    }
    
    /// Stop bridge discovery
    private func stopBridgeDiscovery() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
    }
    
    /// Perform bridge discovery
    private func performBridgeDiscovery() {
        bridgeQueue.async { [weak self] in
            self?.performBridgeDiscoveryInternal()
        }
    }
    
    /// Internal bridge discovery implementation
    private func performBridgeDiscoveryInternal() {
        print("🌉 Discovering bridge nodes...")
        
        // In a real implementation, this would:
        // 1. Broadcast discovery packets
        // 2. Query known bridge registries
        // 3. Use DHT for bridge discovery
        
        // For now, simulate finding bridge nodes
        simulateBridgeDiscovery()
    }
    
    /// Simulate bridge discovery
    private func simulateBridgeDiscovery() {
        // Create some simulated bridge nodes
        let bridgeNodes = [
            BridgeNode(
                id: "bridge-1",
                address: "192.168.1.100",
                port: 8080,
                publicKey: generateBridgePublicKey(),
                capabilities: [.internetAccess, .meshRelay],
                quality: 0.8,
                lastSeen: Date()
            ),
            BridgeNode(
                id: "bridge-2",
                address: "192.168.1.101",
                port: 8080,
                publicKey: generateBridgePublicKey(),
                capabilities: [.internetAccess, .meshRelay, .lowLatency],
                quality: 0.9,
                lastSeen: Date()
            )
        ]
        
        // Register discovered bridges
        for bridgeNode in bridgeNodes {
            registerBridgeNode(bridgeNode)
        }
    }
    
    /// Update available bridges list
    private func updateAvailableBridges() {
        let currentTime = Date()
        
        // Filter out stale bridges
        let activeBridges = bridgeRegistry.values.filter { bridge in
            currentTime.timeIntervalSince(bridge.lastSeen) < config.bridgeTimeout
        }
        
        // Sort by quality
        let sortedBridges = activeBridges.sorted { $0.quality > $1.quality }
        
        DispatchQueue.main.async { [weak self] in
            self?.availableBridges = sortedBridges
        }
    }
    
    /// Perform bridge connection
    private func performBridgeConnection(_ bridgeNode: BridgeNode) {
        print("🌉 Connecting to bridge: \(bridgeNode.id)")
        
        // Simulate connection process
        // In a real implementation, this would:
        // 1. Establish secure connection
        // 2. Authenticate with bridge
        // 3. Set up message relaying
        
        // For now, simulate successful connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            
            self.currentBridge = bridgeNode
            self.bridgeStatus = .connectedToBridge
            
            // Start heartbeat
            self.startHeartbeat()
            
            // Notify delegate
            self.delegate?.bridgeService(self, didConnectToBridge: bridgeNode)
            
            print("✅ Connected to bridge: \(bridgeNode.id)")
        }
    }
    
    /// Disconnect from bridge
    private func disconnectFromBridge(_ bridgeNode: BridgeNode) {
        print("🌉 Disconnecting from bridge: \(bridgeNode.id)")
        
        stopHeartbeat()
        
        currentBridge = nil
        updateBridgeStatus()
        
        // Notify delegate
        delegate?.bridgeService(self, didDisconnectFromBridge: bridgeNode)
    }
    
    /// Update bridge status
    private func updateBridgeStatus() {
        if networkMonitor.currentPath.status == .satisfied {
            bridgeStatus = .hasInternet
        } else {
            bridgeStatus = .offline
        }
    }
    
    /// Start heartbeat for maintaining connections
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: config.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.performHeartbeat()
        }
    }
    
    /// Stop heartbeat
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    /// Perform heartbeat
    private func performHeartbeat() {
        guard let currentBridge = currentBridge else { return }
        
        // Send heartbeat to bridge
        // In a real implementation, this would send a ping message
        
        // Update bridge last seen time
        registryLock.lock()
        if var bridge = bridgeRegistry[currentBridge.id] {
            bridge.lastSeen = Date()
            bridgeRegistry[currentBridge.id] = bridge
        }
        registryLock.unlock()
        
        print("💓 Heartbeat sent to bridge: \(currentBridge.id)")
    }
    
    /// Generate bridge public key
    private func generateBridgePublicKey() -> String {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        return publicKey.rawRepresentation.base64EncodedString()
    }
    
    /// Calculate bridge quality
    private func calculateBridgeQuality() -> Double {
        // In a real implementation, this would consider:
        // - Network latency
        // - Bandwidth
        // - Reliability
        // - Load
        
        return Double.random(in: 0.5...1.0)
    }
}

// MARK: - Configuration

/// Configuration for bridge service
public struct BridgeConfig {
    /// Whether bridge discovery is enabled
    public let enableBridgeDiscovery: Bool
    
    /// Whether this device can host bridges
    public let enableBridgeHosting: Bool
    
    /// Bridge discovery interval (seconds)
    public let discoveryInterval: TimeInterval
    
    /// Bridge timeout (seconds)
    public let bridgeTimeout: TimeInterval
    
    /// Heartbeat interval (seconds)
    public let heartbeatInterval: TimeInterval
    
    /// Bridge hosting port
    public let bridgePort: Int
    
    /// Maximum number of bridges to track
    public let maxBridges: Int
    
    public init(
        enableBridgeDiscovery: Bool = true,
        enableBridgeHosting: Bool = true,
        discoveryInterval: TimeInterval = 60.0,
        bridgeTimeout: TimeInterval = 300.0,
        heartbeatInterval: TimeInterval = 30.0,
        bridgePort: Int = 8080,
        maxBridges: Int = 10
    ) {
        self.enableBridgeDiscovery = enableBridgeDiscovery
        self.enableBridgeHosting = enableBridgeHosting
        self.discoveryInterval = discoveryInterval
        self.bridgeTimeout = bridgeTimeout
        self.heartbeatInterval = heartbeatInterval
        self.bridgePort = bridgePort
        self.maxBridges = maxBridges
    }
}

// MARK: - Data Structures

/// Bridge node information
public struct BridgeNode {
    public let id: String
    public let address: String
    public let port: Int
    public let publicKey: String
    public let capabilities: Set<BridgeCapability>
    public let quality: Double
    public var lastSeen: Date
    
    public init(
        id: String,
        address: String,
        port: Int,
        publicKey: String,
        capabilities: Set<BridgeCapability>,
        quality: Double,
        lastSeen: Date
    ) {
        self.id = id
        self.address = address
        self.port = port
        self.publicKey = publicKey
        self.capabilities = capabilities
        self.quality = quality
        self.lastSeen = lastSeen
    }
}

/// Bridge capabilities
public enum BridgeCapability: String, CaseIterable {
    case internetAccess
    case meshRelay
    case lowLatency
    case highBandwidth
    case encryption
    case authentication
}

/// Bridge status
public enum BridgeStatus {
    case offline
    case hasInternet
    case connectedToBridge
    case hostingBridge
}

/// Connectivity statistics
public struct ConnectivityStatistics {
    public private(set) var totalConnections: Int = 0
    public private(set) var successfulConnections: Int = 0
    public private(set) var lastConnectionTime: Date?
    public private(set) var averageConnectionDuration: TimeInterval = 0
    
    public var successRate: Double {
        guard totalConnections > 0 else { return 0.0 }
        return Double(successfulConnections) / Double(totalConnections)
    }
    
    mutating func updateConnectivity(_ isConnected: Bool) {
        if isConnected {
            successfulConnections += 1
            lastConnectionTime = Date()
        }
        totalConnections += 1
    }
}

// MARK: - Delegate

/// Delegate for bridge service events
public protocol BridgeServiceDelegate: AnyObject {
    func bridgeService(_ service: BridgeService, didUpdateStatus status: BridgeStatus)
    func bridgeService(_ service: BridgeService, didConnectToBridge bridge: BridgeNode)
    func bridgeService(_ service: BridgeService, didDisconnectFromBridge bridge: BridgeNode)
    func bridgeService(_ service: BridgeService, didStartHostingBridge bridge: BridgeNode)
    func bridgeService(_ service: BridgeService, didStopHostingBridge bridge: BridgeNode?)
} 