import Foundation
import CoreMesh

// MARK: - CLI Tool Setup
// (Setup code moved to main function for better access to components)

// MARK: - Demo Data Creation

func createDemoData(
    transactionProcessor: TransactionProcessor,
    walletManager: WalletManager
) throws {
    print("🎭 Creating demo data...")
    
    // Create some demo transactions
    let demoKey = CryptoCurve25519.Signing.PrivateKey()
    
    // Create a few transactions
    for i in 1...5 {
        let transaction = try transactionProcessor.createMessageTransaction(
            feePerHop: UInt32(100 + i * 50),
            senderPrivateKey: demoKey,
            messagePayload: Data("Demo message \(i)".utf8)
        )
        
        try transactionProcessor.processTransaction(transaction)
        print("✅ Created demo transaction \(i)")
    }
    
    print("🎭 Demo data created!\n")
}

// MARK: - Main CLI Entry Point

func main() {
    do {
        // Create database paths in user's home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let bitchatDir = homeDir.appendingPathComponent(".bitchat")
        
        // Create .bitchat directory if it doesn't exist
        try FileManager.default.createDirectory(at: bitchatDir, withIntermediateDirectories: true)
        
        let dagPath = bitchatDir.appendingPathComponent("dag.db").path
        let walletPath = bitchatDir.appendingPathComponent("wallet.db").path
        
        print("📁 Using database files:")
        print("   DAG: \(dagPath)")
        print("   Wallet: \(walletPath)")
        print("")
        
        // Initialize components
        let dagStorage = try SQLiteDAGStorage(dbPath: dagPath)
        let walletManager = try WalletManager(dbPath: walletPath)
        let transactionProcessor = try TransactionProcessor(
            dagStorage: dagStorage,
            walletManager: walletManager
        )
        let feeCalculator = FeeCalculator()
        let proofOfWork = ProofOfWork()
        
        // Create CLI explorer
        let explorer = CLIExplorer(
            dagStorage: dagStorage,
            walletManager: walletManager,
            transactionProcessor: transactionProcessor,
            feeCalculator: feeCalculator,
            proofOfWork: proofOfWork
        )
        
        // Get command line arguments
        let args = Array(CommandLine.arguments.dropFirst())
        
        if args.isEmpty {
            // No arguments - start interactive mode
            print("🚀 BitChat Crypto CLI Explorer")
            print("==============================")
            print("Type 'help' for available commands or 'exit' to quit.")
            print("Type 'demo' to create sample data for testing.")
            print("")
            explorer.startInteractiveSession()
        } else if args[0] == "demo" {
            // Create demo data
            try createDemoData(
                transactionProcessor: transactionProcessor,
                walletManager: walletManager
            )
        } else {
            // Run single command
            let command = args.joined(separator: " ")
            explorer.processCommand(command)
        }
        
    } catch {
        print("❌ Error: \(error)")
        exit(1)
    }
}

// Extension removed - components accessed directly in main function

// Run the CLI
main() 