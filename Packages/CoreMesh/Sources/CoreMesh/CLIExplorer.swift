import Foundation

/// CLI explorer for the BitChat crypto system
public class CLIExplorer {
    private let dagStorage: DAGStorage
    private let walletManager: WalletManager
    private let transactionProcessor: TransactionProcessor
    private let feeCalculator: FeeCalculator
    private let proofOfWork: ProofOfWork
    
    public init(
        dagStorage: DAGStorage,
        walletManager: WalletManager,
        transactionProcessor: TransactionProcessor,
        feeCalculator: FeeCalculator,
        proofOfWork: ProofOfWork
    ) {
        self.dagStorage = dagStorage
        self.walletManager = walletManager
        self.transactionProcessor = transactionProcessor
        self.feeCalculator = feeCalculator
        self.proofOfWork = proofOfWork
    }
    
    // MARK: - CLI Commands
    
    /// Display DAG statistics
    public func showDAGStats() {
        print("\n📊 DAG Statistics")
        print("================")
        
        let tips = dagStorage.getTips()
        let stats = transactionProcessor.getStatistics()
        
        print("Current Tips: \(tips.count)")
        print("Total Transactions: \(stats.processedTransactionCount)")
        print("Total Fees Processed: \(formatMicroRLT(stats.totalFeesProcessed))")
        print("Total Rewards Awarded: \(formatMicroRLT(stats.totalRewardsAwarded))")
        print("Network Conditions: \(formatNetworkConditions(feeCalculator.getCurrentNetworkConditions()))")
        print("Adaptive Base Fee: \(formatMicroRLT(UInt64(feeCalculator.getAdaptiveBaseFee())))")
        
        print("\n🔗 Current Tips:")
        for (index, tip) in tips.enumerated() {
            print("  \(index + 1). \(tip.hexString)")
        }
    }
    
    /// Display transaction details
    public func showTransaction(_ transactionId: String) {
        guard let digest = SHA256Digest(hexString: transactionId) else {
            print("❌ Invalid transaction ID format")
            return
        }
        
        guard let transaction = transactionProcessor.getTransaction(digest) else {
            print("❌ Transaction not found: \(transactionId)")
            return
        }
        
        print("\n📋 Transaction Details")
        print("=====================")
        print("ID: \(transaction.transaction.id.hexString)")
        print("Fee per Hop: \(formatMicroRLT(UInt64(transaction.transaction.feePerHop)))")
        print("Sender: \(transaction.transaction.senderPub.rawRepresentation.prefix(8).hexEncodedString())...")
        print("Signature Valid: \(transaction.verify() ? "✅" : "❌")")
        
        print("\nParents:")
        for (index, parent) in transaction.transaction.parents.enumerated() {
            print("  \(index + 1). \(parent.hexString)")
        }
        
        print("\nTransaction Data:")
        let txData = transaction.encode()
        print("  Size: \(txData.count) bytes")
        print("  Hash: \(transaction.transaction.id.hexString)")
    }
    
    /// Display wallet information
    public func showWallet(publicKeyHex: String) {
        guard let publicKeyData = Data(hexString: publicKeyHex),
              let publicKey = try? CryptoCurve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            print("❌ Invalid public key format")
            return
        }
        
        do {
            let summary = try walletManager.getWalletSummary(for: publicKey)
            
            print("\n💰 Wallet Summary")
            print("================")
            print("Public Key: \(publicKey.rawRepresentation.hexEncodedString())")
            print("Balance: \(formatMicroRLT(summary.balanceMicroRLT))")
            print("Balance (RLT): \(String(format: "%.6f", summary.balanceRLT))")
            print("Recent Transactions: \(summary.recentTransactions.count)")
            
            if !summary.recentTransactions.isEmpty {
                print("\n📜 Recent Transactions:")
                for (index, tx) in summary.recentTransactions.enumerated() {
                    let typeIcon = tx.type == .reward ? "🏆" : "💸"
                    print("  \(index + 1). \(typeIcon) \(formatMicroRLT(tx.amount)) - \(tx.description)")
                    print("      \(tx.createdAt.formatted()) - \(tx.transactionId.hexString)")
                }
            }
        } catch {
            print("❌ Error fetching wallet: \(error)")
        }
    }
    
    /// Calculate and display fee for a hypothetical message
    public func calculateMessageFee(
        messageSize: Int,
        ttl: UInt8,
        priority: MessagePriority = .normal
    ) {
        let feeCalc = feeCalculator.calculateFee(
            messageSize: messageSize,
            ttl: ttl,
            priority: priority
        )
        
        print("\n💰 Fee Calculation")
        print("==================")
        print("Message Size: \(messageSize) bytes")
        print("TTL (Hops): \(ttl)")
        print("Priority: \(priority.description)")
        print("")
        print("Base Fee: \(formatMicroRLT(UInt64(feeCalc.baseFee)))")
        print("Size Fee: \(formatMicroRLT(UInt64(feeCalc.sizeFee)))")
        print("Hop Fee: \(formatMicroRLT(UInt64(feeCalc.hopFee)))")
        print("Priority Multiplier: \(String(format: "%.2fx", feeCalc.priorityMultiplier))")
        print("Congestion Multiplier: \(String(format: "%.2fx", feeCalc.congestionMultiplier))")
        print("")
        print("Total Fee: \(formatMicroRLT(UInt64(feeCalc.totalFee)))")
        print("Total Fee (RLT): \(String(format: "%.6f", feeCalc.feeInRLT))")
        print("Estimated Delivery: \(String(format: "%.3f", feeCalc.estimatedDeliveryTime))s")
    }
    
    /// List all transactions in the DAG
    public func listTransactions(limit: Int = 10) {
        let tips = dagStorage.getTips()
        var allTransactions: [SignedRelayTx] = []
        
        // Collect transactions from tips (simplified approach)
        for tip in tips.prefix(limit) {
            if let tx = dagStorage.getTransaction(tip) {
                allTransactions.append(tx)
            }
        }
        
        print("\n📜 Recent Transactions")
        print("=====================")
        
        if allTransactions.isEmpty {
            print("No transactions found")
            return
        }
        
        for (index, tx) in allTransactions.enumerated() {
            let fee = formatMicroRLT(UInt64(tx.transaction.feePerHop))
            let sender = tx.transaction.senderPub.rawRepresentation.prefix(4).hexEncodedString()
            let valid = tx.verify() ? "✅" : "❌"
            
            print("\(index + 1). \(valid) \(tx.transaction.id.hexString)")
            print("   Fee: \(fee) | Sender: \(sender)... | Parents: \(tx.transaction.parents.count)")
        }
    }
    
    /// Display Proof of Work statistics
    public func showPoWStats() {
        print("\n🔨 Proof of Work Statistics")
        print("===========================")
        
        let stats = proofOfWork.getStatistics()
        
        print("Current Difficulty: \(stats.currentDifficulty) leading zeros")
        print("Target Compute Time: \(String(format: "%.1f", stats.targetComputeTime))s")
        print("Average Compute Time: \(String(format: "%.2f", stats.averageComputeTime))s")
        print("Total Computations: \(stats.totalComputations)")
        
        // Performance indicator
        let performance: String
        if stats.averageComputeTime < stats.targetComputeTime * 0.8 {
            performance = "🟢 Fast (difficulty may increase)"
        } else if stats.averageComputeTime > stats.targetComputeTime * 1.5 {
            performance = "🔴 Slow (difficulty may decrease)"
        } else {
            performance = "🟡 Balanced"
        }
        print("Performance: \(performance)")
        
        if stats.totalComputations == 0 {
            print("\n💡 No PoW computations performed yet")
            print("   PoW is only required when message fee < relay minimum fee")
        }
    }
    
    /// Show help information
    public func showHelp() {
        print("""
        
        🚀 BitChat Crypto CLI Explorer
        ===============================
        
        Commands:
        
        📊 DAG Operations:
          dag-stats          - Show DAG statistics
          list-txs [limit]   - List recent transactions
          show-tx <id>       - Show transaction details
        
        💰 Wallet Operations:
          wallet <pubkey>    - Show wallet summary
          fee-calc <size> <ttl> [priority] - Calculate message fee
        
        🔨 Proof of Work:
          pow-stats          - Show PoW statistics and difficulty
        
        🔧 Utility:
          help               - Show this help
          
        Examples:
          dag-stats
          wallet 1a2b3c4d5e6f7890abcdef...
          fee-calc 1024 5 normal
          show-tx abc123...
        """)
    }
    
    // MARK: - Interactive CLI
    
    /// Start interactive CLI session
    public func startInteractiveSession() {
        print("🚀 Welcome to BitChat Crypto CLI Explorer!")
        print("Type 'help' for available commands or 'exit' to quit.\n")
        
        while true {
            print("bitchat> ", terminator: "")
            
            guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else {
                continue
            }
            
            if input.isEmpty {
                continue
            }
            
            if input.lowercased() == "exit" || input.lowercased() == "quit" {
                print("👋 Goodbye!")
                break
            }
            
            processCommand(input)
        }
    }
    
    /// Process a single command
    public func processCommand(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return }
        
        let cmd = parts[0].lowercased()
        let args = Array(parts.dropFirst())
        
        switch cmd {
        case "dag-stats":
            showDAGStats()
            
        case "list-txs":
            let limit = args.first.flatMap(Int.init) ?? 10
            listTransactions(limit: limit)
            
        case "show-tx":
            guard let txId = args.first else {
                print("❌ Usage: show-tx <transaction-id>")
                return
            }
            showTransaction(txId)
            
        case "pow-stats":
            showPoWStats()
            
        case "wallet":
            guard let pubkey = args.first else {
                print("❌ Usage: wallet <public-key-hex>")
                return
            }
            showWallet(publicKeyHex: pubkey)
            
        case "fee-calc":
            guard args.count >= 2,
                  let messageSize = Int(args[0]),
                  let ttl = UInt8(args[1]) else {
                print("❌ Usage: fee-calc <message-size> <ttl> [priority]")
                return
            }
            let priority = args.count > 2 ? MessagePriority(rawValue: args[2]) ?? .normal : .normal
            calculateMessageFee(messageSize: messageSize, ttl: ttl, priority: priority)
            
        case "help":
            showHelp()
            
        default:
            print("❌ Unknown command: \(cmd)")
            print("Type 'help' for available commands")
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatMicroRLT(_ amount: UInt64) -> String {
        let rlt = Double(amount) / Double(WalletManager.microRLTPerRLT)
        return String(format: "%.6f RLT (%d µRLT)", rlt, amount)
    }
    
    private func formatNetworkConditions(_ conditions: NetworkConditions) -> String {
        return String(format: "congestion=%.2f, latency=%.3fs", conditions.congestion, conditions.averageLatency)
    }
}

// Extensions are now in CoreMesh.swift

extension Date {
    func formatted() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: self)
    }
}