# BitChat Relay-Token White-Paper  
**Version 0.1 – July 2025**

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
8. [Roadmap & Milestones](#roadmap--milestones)  
9. [Risks & Mitigations](#risks--mitigations)  
10. [Regulatory Considerations](#regulatory-considerations)  
11. [References](#references)

---

## Abstract
BitChat is a peer-to-peer messaging platform that forms an *opportunistic mesh* over Bluetooth Low Energy (BLE) and Wi-Fi Direct.  
This paper proposes **Relay-Token (RLT)**—a lightweight cryptocurrency that:

* Prices every message (and file) hop with a micro-payment.  
* Rewards relay nodes instantly and offline.  
* Enables fee-based route selection (fast/expensive vs. slow/cheap).  
* Anchors security to public blockchains only when connectivity is available.

The design combines a *DAG-style feeless ledger* with local proofs, enabling trust-minimised payments on resource-constrained mobile hardware.

---

## Background & Motivation
1. **Resilience without infrastructure** – Pure mesh networks suffer from *tragedy of the commons*: users benefit from relays but bear no cost to host them.  
2. **Incentive alignment** – A native token can reward devices for forwarding traffic, encouraging denser coverage and longer uptime.  
3. **Spam resistance** – Pricing by hop naturally throttles flood attacks and large file transfers.  
4. **User choice** – Attaching a budget lets senders choose between latency and cost, similar to gas pricing in traditional blockchains.

---

## System Overview
| Component | Purpose |
|-----------|---------|
| **Packet Layer** | Extends current `BitchatPacket` with *fee* and *txHash* fields. |
| **Local Ledger (DAG)** | Each message is itself a transaction that approves two prior transactions, forming a directed acyclic graph. |
| **Relay-Token (RLT)** | Inflationary utility token minted per hop; divisible to `10-6` (µRLT). |
| **Anchors** | Periodic Merkle roots pushed to public chains (Bitcoin, Polygon) or Nostr relays for global consensus. |
| **Fee Beacons** | Relays advertise a `relayMinFee` in discovery payloads; senders compute total cost before dispatch. |

---

## Technical Architecture

### 4.1 Packet Extension
struct BitchatHeaderV2 {
uint8 version = 0x02;
uint8 ttl; // decremented each hop
uint32 fee_per_hop; // µRLT
uint256 tx_hash; // SHA-256 of RelayTx
/* existing fields … */
}

### 4.2 Relay Transaction (RelayTx)
message RelayTx {
bytes id = sha256(this); // 32 bytes
bytes parents[2]; // tips approved
uint32 fee_per_hop; // µRLT
bytes sender_pub; // 32 bytes (Ed25519)
bytes signature; // 64 bytes
}

*Size impact per hop ≈ 100 bytes (<< BLE MTU 251).*

### 4.3 Ledger Storage
* SQLite or RocksDB on-device.  
* Pruning rule: keep only ancestors ≤ `depth_window` (default = 1 000 tx).  
* Snapshot export/import over Wi-Fi Direct for rapid sync.

### 4.4 Anchoring Protocol
1. Device computes Merkle root of current DAG tip-set.  
2. Posts root to a selected *anchor network* when any internet link appears.  
3. Peers accept longest-anchored sub-DAG during conflict resolution.

---

## Token Economics

| Parameter | Value (initial) | Notes |
|-----------|-----------------|-------|
| **Inflation** | 1 RLT minted *per hop* | Uncapped supply; value derives from utility. |
| **Relay reward** | 100 % of hop fee | Paid instantly, spendable once anchored. |
| **Base fee (µRLT)** | Adaptive EMA of last 1 000 hops | Broadcast via fee beacons. |
| **Spam PoW** | Leading-zero hash, difficulty auto-scales | Only required when fee `< relayMinFee`. |

*Users may pre-fund wallets via on-chain bridge or earn RLT by relaying.*

---

## Consensus & Security Model

1. **Local validity** – Each node checks Ed25519 sigs and parent existence.  
2. **Global consistency** – Fork choice = highest *anchored weight* (count of anchored tx).  
3. **Double-spend** – Impossible without network-wide collusion > anchor interval; stale branches are pruned.  
4. **Sybil resistance** – Optional SecureEnclave / Android KeyStore attestation for *verified relays* tier.

---

## Node Roles & Network Operation

| Role | Capabilities |
|------|--------------|
| **Sender** | Crafts RelayTx, pays `fee_per_hop × hops_budget`. |
| **Relay** | Validates packet, appends own pubkey to receipt, logs reward. |
| **Bridge** | Device with intermittent internet; uploads anchor roots. |
| **Observer** | Read-only ledger crawler for analytics / explorers. |

Background service throttles BLE advertising to remain within *15 % daily battery* budget.

---

## Roadmap & Milestones

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| **0 – PoC** | 2 weeks | Hop logging, fee fields, Android demo. |
| **1 – Local DAG** | 4 weeks | Ledger save/load, CLI explorer. |
| **2 – Fee Market** | 3 weeks | RelayMinFee beacons, budgeted routing. |
| **3 – Anchors** | 4 weeks | Merkle root anchoring to Bitcoin testnet. |
| **4 – iOS Port** | 6 weeks | MultipeerConnectivity + shared Rust core. |
| **5 – File-Transfer** | TBD | Per-MB pricing, chunk receipts. |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Battery drain | User churn | Strict duty-cycle caps; PoW disabled < 30 % battery. |
| Spam / DDoS | Network congestion | Minimum fee + PoW; relays blacklist offenders locally. |
| Regulatory | App-store rejection | Opt-out “no-token” mode; classify as utility token. |
| Ledger bloat | Storage exhaustion | Depth-window pruning + snapshot compression. |

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
