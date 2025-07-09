
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
