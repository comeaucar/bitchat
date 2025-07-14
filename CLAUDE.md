# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

bitchat is a secure, decentralized, peer-to-peer messaging app that operates over Bluetooth mesh networks without requiring internet connectivity. It's a universal iOS/macOS SwiftUI application that uses local Swift Package Manager packages for core functionality.

## Build System & Commands

### Primary Build Method (Recommended)
Use XcodeGen to generate the Xcode project:
```bash
xcodegen generate
open bitchat.xcodeproj
```

### Alternative Build Methods
1. **Swift Package Manager**: `open Package.swift`
2. **Setup Script**: Run `./setup.sh` for guided setup

### Testing
- Tests are located in `bitchatTests/` and `Packages/CoreMesh/Tests/CoreMeshTests/`
- Run tests through Xcode test navigator or via schemes: `bitchatTests_iOS` and `bitchatTests_macOS`
- **Important**: Bluetooth functionality requires physical devices - simulator testing is limited

### Project Generation
- Uses `project.yml` as the XcodeGen configuration
- Targets: iOS app, macOS app, Share Extension, and unit tests
- Minimum deployment: iOS 16.0, macOS 13.0

## Architecture Overview

### Core Components

**Local Package Dependencies:**
- `CoreMesh` (`Packages/CoreMesh/`): Core mesh networking primitives, cryptographic utilities, transaction processing, and packet handling

**Main App Structure:**
- `BitchatApp.swift`: SwiftUI app entry point with notification handling and shared content processing
- `ChatViewModel.swift`: Central state management for messages, peers, channels, and encryption
- `BluetoothMeshService.swift`: Core Bluetooth LE mesh networking implementation
- `BitchatProtocol.swift`: Binary protocol definitions and packet structures

**Service Layer:**
- `EncryptionService.swift`: X25519 key exchange + AES-256-GCM encryption
- `DeliveryTracker.swift`: Message delivery status tracking
- `MessageRetentionService.swift`: Optional channel message persistence
- `NotificationService.swift`: Push notification handling
- `KeychainManager.swift`: Secure storage for channel passwords

**Utilities:**
- `BatteryOptimizer.swift`: Adaptive power management for Bluetooth scanning
- `CompressionUtil.swift`: LZ4 message compression
- `OptimizedBloomFilter.swift`: Message deduplication

### Networking Architecture

**Bluetooth Mesh Protocol:**
- Each device acts as both central and peripheral
- Custom binary protocol with TTL-based routing (max 7 hops)
- Store-and-forward for offline message delivery
- Cover traffic and timing obfuscation for privacy

**Message Flow:**
1. Messages created in `ChatViewModel`
2. Encrypted by `EncryptionService` (if private) or channel-based encryption
3. Packetized by `BitchatProtocol` with TTL and relay headers
4. Transmitted via `BluetoothMeshService` over Bluetooth LE
5. Relayed through mesh network to reach destination

**Key Management:**
- Forward secrecy: New X25519 key pairs per session
- Channel encryption: Argon2id password derivation + AES-256-GCM
- Ed25519 signatures for message authenticity

### Data Model

**Core Message Types:**
- Public messages (unencrypted, broadcast to all)
- Private messages (X25519 + AES-256-GCM between peers)
- Channel messages (password-derived AES-256-GCM)
- System messages (join/leave notifications, status updates)

**State Management:**
- All message data is ephemeral by default (in-memory only)
- Optional message retention for channel owners via `MessageRetentionService`
- Peer state and favorites persisted via UserDefaults and Keychain
- No persistent user accounts or registration

## Development Guidelines

### Testing Requirements
- Always test on physical iOS/macOS devices (Bluetooth LE required)
- Test mesh functionality with multiple devices in range
- Verify encryption with network packet analysis tools

### Security Considerations
- Never log or persist private keys or decrypted message content
- All cryptographic operations should use secure random number generation
- Message retention is opt-in and clearly disclosed to users

### Performance Optimization
- Battery-aware Bluetooth scanning via `BatteryOptimizer`
- Message compression for payloads >100 bytes using LZ4
- Bloom filters for efficient message deduplication
- Connection limits adapt based on battery level

### Platform-Specific Notes
- iOS: Requires Bluetooth permissions in Info.plist
- macOS: Uses AppKit for system integration
- Both platforms support background Bluetooth operation
- Share Extension enables content sharing from other apps

## Common Development Tasks

### Adding New Message Types
1. Define new packet type in `BitchatProtocol.swift`
2. Add encoding/decoding logic for binary protocol
3. Update `BluetoothMeshService` to handle new type
4. Add UI handling in `ChatViewModel` and views

### Modifying Encryption
1. Update `EncryptionService` for new algorithms
2. Ensure backward compatibility with existing sessions
3. Update key derivation in channel encryption if needed
4. Add appropriate unit tests in `bitchatTests/`

### Bluetooth Optimization
1. Modify scanning parameters in `BluetoothMeshService`
2. Update `BatteryOptimizer` for new power modes
3. Test on various iOS/macOS versions for compatibility
4. Consider impact on mesh network connectivity

### CoreMesh Package Development
- Contains blockchain-inspired components (DAG storage, transaction processing, fee calculation)
- Provides cryptographic primitives and hop logging
- Independent testing via `CoreMeshTests`
- Changes require rebuilding main app project

## CoreMesh Integration Features

### Cost Calculation and Logging
- Every message (public/private/channel) now calculates and logs detailed cost information
- Costs include: message size, TTL (hops), priority, base fee, size fee, hop fee, total fee
- Private messages to favorites use higher priority and shorter TTL (3 hops vs 5)
- Real-time logging shows fee in both µRLT (micro-RLT) and RLT units

### Transaction Processing
- Each message creates a relay transaction that gets added to the DAG
- Genesis transaction with zero-digest parents bootstraps the system
- Awards relay rewards to message senders
- Tracks fee payments for adaptive network pricing

### Network Statistics
- `/stats` command displays comprehensive CoreMesh statistics
- Automatic logging every 60 seconds to console
- Tracks DAG state, transaction processing, wallet balances, and network conditions
- Adaptive fee calculation based on network congestion and latency

### Database Storage
- SQLite-based persistent storage for DAG transactions and wallet data
- Stored in iOS/macOS Documents directory (bitchat_dag.db, bitchat_wallet.db)
- Thread-safe operations with proper transaction management
- Automatic database cleanup and pruning