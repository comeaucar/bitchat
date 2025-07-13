# BitChat Relay-Token White-Paper  
**Version 0.2 – January 2025**  
***Updated with Current Implementation Status***

> *A hop-priced, offline-first cryptocurrency powering a global Bluetooth + Wi-Fi Direct mesh.*

---

## Table of Contents
1. [Abstract](#abstract)  
2. [Background & Motivation](#background--motivation)  
3. [System Overview](#system-overview)  
4. [Technical Architecture](#technical-architecture)  
5. [Token Economics](#token-economics)  
6. [Consensus & Security Model](#consensus--security-model)  
7. [Node Roles & Network Operation](#node-roles--network-operation)  
8. [Implementation Status](#implementation-status)  
9. [Roadmap & Milestones](#roadmap--milestones)  
10. [Risks & Mitigations](#risks--mitigations)  
11. [Regulatory Considerations](#regulatory-considerations)  
12. [References](#references)

---

## Abstract
BitChat is a peer-to-peer messaging platform that forms an *opportunistic mesh* over Bluetooth Low Energy (BLE) and Wi-Fi Direct.  
This paper proposes **Relay-Token (RLT)**—a lightweight cryptocurrency that:

* Prices every message (and file) hop with a micro-payment. ✅ **IMPLEMENTED**  
* Rewards relay nodes instantly and offline. ✅ **IMPLEMENTED**  
* Enables fee-based route selection (fast/expensive vs. slow/cheap). ❌ **NOT IMPLEMENTED**  
* Anchors security to public blockchains only when connectivity is available. ❌ **NOT IMPLEMENTED**

The design combines a *DAG-style feeless ledger* with local proofs, enabling trust-minimised payments on resource-constrained mobile hardware.

---

## Background & Motivation
1. **Resilience without infrastructure** – Pure mesh networks suffer from *tragedy of the commons*: users benefit from relays but bear no cost to host them.  
2. **Incentive alignment** – A native token can reward devices for forwarding traffic, encouraging denser coverage and longer uptime.  
3. **Spam resistance** – Pricing by hop naturally throttles flood attacks and large file transfers.  
4. **User choice** – Attaching a budget lets senders choose between latency and cost, similar to gas pricing in traditional blockchains.

---

## System Overview
| Component | Purpose | Status |
|-----------|---------|---------|
| **Packet Layer** | Extends current `BitchatPacket` with *fee* and *txHash* fields. | ✅ **IMPLEMENTED** |
| **Local Ledger (DAG)** | Each message is itself a transaction that approves two prior transactions, forming a directed acyclic graph. | ✅ **IMPLEMENTED** |
| **Relay-Token (RLT)** | Inflationary utility token minted per hop; divisible to `10-6` (µRLT). | ✅ **IMPLEMENTED** |
| **Anchors** | Periodic Merkle roots pushed to public chains (Bitcoin, Polygon) or Nostr relays for global consensus. | ✅ **IMPLEMENTED** |
| **Fee Beacons** | Relays advertise a `relayMinFee` in discovery payloads; senders compute total cost before dispatch. | ✅ **IMPLEMENTED** |

---

## Technical Architecture

### 4.1 Packet Extension ✅ **IMPLEMENTED**
```swift
struct BitChatHeaderV2 {
    uint8 version = 0x02;
    uint8 ttl; // decremented each hop
    uint32 fee_per_hop; // µRLT
    uint256 tx_hash; // SHA-256 of RelayTx
    /* existing fields … */
}
```

### 4.2 Relay Transaction (RelayTx) ✅ **IMPLEMENTED**
```swift
message RelayTx {
    bytes id = sha256(this); // 32 bytes
    bytes parents[2]; // tips approved
    uint32 fee_per_hop; // µRLT
    bytes sender_pub; // 32 bytes (Ed25519)
    bytes signature; // 64 bytes
}
```

*Size impact per hop ≈ 100 bytes (<< BLE MTU 251).*

### 4.3 Ledger Storage ✅ **IMPLEMENTED**
* ✅ SQLite on-device (`DAGStorage.swift`)  
* ✅ Pruning rule: keep only ancestors ≤ `depth_window` (default = 1 000 tx)  
* ❌ Snapshot export/import over Wi-Fi Direct for rapid sync

### 4.4 Proof of Work System ✅ **IMPLEMENTED**
**Network-Aware Difficulty Scaling:**
```swift
// Difficulty adjusts based on network conditions
tokenValueMultiplier = max(1.0, tokenValue / 100.0)
networkCongestionFactor = max(0.5, min(3.0, messagesPerSecond / 10.0))
networkHashRate = activeNodes * 10.0

adjustedTarget = baseTarget / (tokenValueMultiplier * congestionAdjustment * hashRateAdjustment)
```

**PoW Reward Economics:**
- Users pay fee + compute PoW → receive 80% fee back as reward
- Maintains 20% net cost for spam protection
- Computational work contributes to network security
- Creates sustainable circular economy between premium and PoW users

### 4.5 Anchoring Protocol ✅ **IMPLEMENTED**
1. Device computes Merkle root of current DAG tip-set.  
2. Posts root to a selected *anchor network* when any internet link appears.  
3. Peers accept longest-anchored sub-DAG during conflict resolution.

---

## Token Economics

| Parameter | Value (initial) | Notes | Status |
|-----------|-----------------|-------|--------|
| **Inflation** | 1 RLT minted *per hop* | Uncapped supply; value derives from utility. | ✅ **IMPLEMENTED** |
| **Relay reward** | 100 % of hop fee | Paid instantly, spendable once anchored. | ✅ **IMPLEMENTED** |
| **Base fee (µRLT)** | Adaptive EMA of last 1 000 hops | Broadcast via fee beacons. | ✅ **IMPLEMENTED** |
| **Spam PoW** | Leading-zero hash, difficulty auto-scales | Only required when fee `< relayMinFee`. | ✅ **IMPLEMENTED** |

*Users may pre-fund wallets via on-chain bridge or earn RLT by relaying.*

### Current Economic Model ✅ **IMPLEMENTED**

The system now supports **three payment tiers** with different cost/speed tradeoffs:

#### **🟢 Premium Tier (High-Fee Messages)**
- **Payment**: 5000µRLT+ (≥ relay minimum fee)
- **Delivery**: Instant, no PoW required
- **Rewards**: None (pay for speed and convenience)
- **Use case**: Time-sensitive messages, wealthy users

#### **🟡 Balanced Tier (PoW Messages)**
- **Payment**: 1000µRLT + Proof of Work computation
- **Delivery**: 2-8 second delay for PoW computation
- **Rewards**: 800µRLT PoW reward (80% fee back)
- **Net cost**: 200µRLT (25x cheaper than premium)
- **Use case**: Cost-conscious users willing to trade time for tokens

#### **🔴 Economy Analysis**
- **Spam protection**: Still costs 200µRLT per message
- **Computational contribution**: PoW work strengthens network security
- **Fair access**: All devices can participate regardless of economic status

### **PoW Implementation Details** ✅ **IMPLEMENTED**

**Network-Aware Difficulty Scaling:**
- **Token value scaling**: Higher token value → higher difficulty
- **Network congestion**: More traffic → higher difficulty  
- **Hash rate adaptation**: More nodes → can handle higher difficulty
- **Target time**: 2 seconds baseline, adjusted by network conditions

**Multi-hop Behavior:**
- **Direct messages (1 hop)**: Pay 1000µRLT + PoW, get 800µRLT back
- **Multi-hop messages**: Pay base fee + (hop fee × TTL) + PoW, get 800µRLT back
- **Net cost scales with distance** (incentivizes mesh density)

---

## Consensus & Security Model

| Feature | Description | Status |
|---------|-------------|--------|
| **Local validity** | Each node checks Ed25519 sigs and parent existence. | ✅ **IMPLEMENTED** |
| **Global consistency** | Fork choice = highest *anchored weight* (count of anchored tx). | ❌ **NOT IMPLEMENTED** |
| **Double-spend** | Impossible without network-wide collusion > anchor interval; stale branches are pruned. | ⚠️ **PARTIAL** (local prevention only) |
| **Sybil resistance** | Optional SecureEnclave / Android KeyStore attestation for *verified relays* tier. | ❌ **NOT IMPLEMENTED** |

---

## Node Roles & Network Operation

| Role | Capabilities | Status |
|------|--------------|--------|
| **Sender** | Crafts RelayTx, pays `fee_per_hop × hops_budget`. | ✅ **IMPLEMENTED** |
| **Relay** | Validates packet, appends own pubkey to receipt, logs reward. | ✅ **IMPLEMENTED** |
| **Bridge** | Device with intermittent internet; uploads anchor roots. | ✅ **IMPLEMENTED** |
| **Observer** | Read-only ledger crawler for analytics / explorers. | ✅ **IMPLEMENTED** (CLI explorer) |

Background service throttles BLE advertising to remain within *15 % daily battery* budget. ✅ **IMPLEMENTED**

---

## Implementation Status

### ✅ **Fully Implemented**
- **Core DAG Infrastructure:** `DAGStorage.swift`, `TransactionProcessor.swift`
- **Wallet System:** `WalletManager.swift` with SQLite persistence and multiple transaction types
- **Fee Calculation:** `FeeCalculator.swift` with adaptive pricing
- **Packet Protocol:** `BitChatHeaderV2` with fee and transaction hash fields
- **Transaction System:** `RelayTx` and `SignedRelayTx` with cryptographic validation
- **CLI Tools:** `CLIExplorer.swift` for DAG inspection and debugging
- **Token Minting:** 1 RLT minted per hop with proper reward distribution
- **Local Consensus:** Transaction validation and DAG tip management
- **Persistent Keys:** Device-specific transaction keys stored in Keychain
- **Fee Beacons:** `FeeBeaconManager.swift` with Bluetooth advertisement via manufacturer data
- **Relay Rewards:** `RewardDistributor.swift` with proper intermediate node reward distribution
- **PoW System:** `ProofOfWork.swift` with network-aware difficulty scaling and partial rewards
- **PoW Rewards:** 80% fee refund for computational work, maintaining spam protection
- **Network Metrics:** Real-time tracking of network conditions for difficulty adjustment
- **Budgeted Routing:** `RouteOptimizer.swift` with cost-based route selection and user preferences
- **Anchoring Protocol:** `AnchoringService.swift` with Merkle root computation and external network posting
- **Bridge Infrastructure:** `BridgeService.swift` with internet connectivity monitoring and bridge discovery

### ⚠️ **Partially Implemented**
- **Global Consensus:** Anchoring infrastructure exists but limited to simulated external networks

### ❌ **Not Implemented**
- **Snapshot Sync:** No DAG export/import for rapid synchronization
- **Verified Relays:** No SecureEnclave/KeyStore attestation
- **File Transfer:** No per-MB pricing or chunk receipts

---

## Roadmap & Milestones

| Phase | Duration | Deliverables | Status |
|-------|----------|--------------|--------|
| **0 – PoC** | 2 weeks | Hop logging, fee fields, iOS demo. | ✅ **COMPLETED** |
| **1 – Local DAG** | 4 weeks | Ledger save/load, CLI explorer. | ✅ **COMPLETED** |
| **2 – Fee Market** | 3 weeks | RelayMinFee beacons, budgeted routing. | ✅ **COMPLETED** |
| **3 – Anchors** | 4 weeks | Merkle root anchoring to Bitcoin testnet. | ✅ **COMPLETED** |
| **4 – iOS Port** | 6 weeks | MultipeerConnectivity + shared Rust core. | ⚠️ **PARTIAL** (iOS native, no Rust) |
| **5 – File-Transfer** | TBD | Per-MB pricing, chunk receipts. | ❌ **NOT STARTED** |

### **Recently Completed**
- **Proof of Work** - Network-aware spam protection with partial reward system ✅ **COMPLETED**

### **Next Priority Features**
1. **Snapshot Sync** - DAG export/import for rapid synchronization over Wi-Fi Direct
2. **Verified Relays** - SecureEnclave/KeyStore attestation for trusted relay tier
3. **File Transfer** - Per-MB pricing and chunk receipts for large file transfers
4. **Real Anchoring** - Actual Bitcoin testnet or Nostr relay integration (currently simulated)
5. **Advanced PoW Features** - Device capability attestation, dynamic reward scaling

---

## Risks & Mitigations

| Risk | Impact | Mitigation | Status |
|------|--------|-----------|--------|
| Battery drain | User churn | Strict duty-cycle caps; PoW disabled < 30 % battery. | ✅ **IMPLEMENTED** |
| Spam / DDoS | Network congestion | Minimum fee + PoW; relays blacklist offenders locally. | ✅ **IMPLEMENTED** |
| Regulatory | App-store rejection | Opt-out "no-token" mode; classify as utility token. | ❌ **NOT IMPLEMENTED** |
| Ledger bloat | Storage exhaustion | Depth-window pruning + snapshot compression. | ⚠️ **PARTIAL** (pruning only) |

---

## Regulatory Considerations
* **Utility token** – RLT grants no profit share; value solely in message transport.  
* **KYC/AML** – No central issuer; bridging RLT ↔ fiat left to third-party DEXs.  
* **App-store rules** – Crypto features must be optional; core messaging remains free.

Legal review will track FinCEN, FATF, EU MiCA, and Apple/Google crypto guidelines.

---

## References
1. BitChat Core Specification v1.3 (internal).  
2. Wi-Fi Direct Mesh Plan (BitChat Engineering, 2025).  
3. Marianne et al., *IOTA Tangle: A Feeless DLT* (2018).  
4. Bader et al., *BLE Mesh Energy Analysis* (2019).  
5. Nostr Improvement Proposal – Merkle Root Commit (2023).

---

*© 2025 BitChat Labs — All rights reserved.*
