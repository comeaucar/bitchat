import Foundation
import SQLite3
import Crypto

/// Wallet manager for tracking balances and transaction history
public final class WalletManager {
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "wallet.manager", qos: .userInitiated)
    
    // µRLT conversion: 1 RLT = 1,000,000 µRLT
    public static let microRLTPerRLT: UInt64 = 1_000_000
    
    public init(dbPath: String) throws {
        self.dbPath = dbPath
        
        // Create database directory if needed
        let dbDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        
        // Open database
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            throw WalletError.databaseError("Failed to open wallet database: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        // Enable foreign key support
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        
        try createTables()
        try migrateDatabase()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    private func migrateDatabase() throws {
        // Check if we need to migrate the database schema
        let checkConstraintQuery = """
            SELECT sql FROM sqlite_master 
            WHERE type='table' AND name='wallet_transactions'
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkConstraintQuery, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️  Could not check database schema, assuming migration not needed")
            return
        }
        
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let sqlPtr = sqlite3_column_text(stmt, 0) {
                let sql = String(cString: sqlPtr)
                
                // Check if the UNIQUE constraint exists
                if !sql.contains("UNIQUE(public_key, transaction_id)") {
                    print("🔄 Migrating database schema to add UNIQUE constraint...")
                    
                    // Drop the old table and recreate it
                    let dropQuery = "DROP TABLE IF EXISTS wallet_transactions_old"
                    sqlite3_exec(db, dropQuery, nil, nil, nil)
                    
                    // Rename current table to backup
                    let renameQuery = "ALTER TABLE wallet_transactions RENAME TO wallet_transactions_old"
                    let renameResult = sqlite3_exec(db, renameQuery, nil, nil, nil)
                    
                    if renameResult == SQLITE_OK {
                        // Create new table with constraint
                        let createNewTable = """
                            CREATE TABLE wallet_transactions (
                                id TEXT PRIMARY KEY,
                                public_key BLOB NOT NULL,
                                transaction_id BLOB NOT NULL,
                                amount_micro_rlt INTEGER NOT NULL,
                                transaction_type TEXT NOT NULL,
                                created_at INTEGER NOT NULL,
                                description TEXT,
                                UNIQUE(public_key, transaction_id)
                            )
                        """
                        
                        let createResult = sqlite3_exec(db, createNewTable, nil, nil, nil)
                        if createResult == SQLITE_OK {
                            // Copy data from old table, handling duplicates
                            let copyQuery = """
                                INSERT OR IGNORE INTO wallet_transactions 
                                SELECT * FROM wallet_transactions_old
                            """
                            
                            let copyResult = sqlite3_exec(db, copyQuery, nil, nil, nil)
                            if copyResult == SQLITE_OK {
                                // Drop old table
                                let dropOldQuery = "DROP TABLE wallet_transactions_old"
                                sqlite3_exec(db, dropOldQuery, nil, nil, nil)
                                
                                print("✅ Database migration completed successfully")
                            } else {
                                print("❌ Failed to copy data during migration")
                            }
                        } else {
                            print("❌ Failed to create new table during migration")
                        }
                    } else {
                        print("❌ Failed to rename table during migration")
                    }
                } else {
                    print("✅ Database schema is up to date")
                }
            }
        }
    }
    
    private func createTables() throws {
        // Table for wallet balances
        let createWalletsTable = """
            CREATE TABLE IF NOT EXISTS wallets (
                public_key BLOB PRIMARY KEY,
                balance_micro_rlt INTEGER NOT NULL DEFAULT 0,
                last_updated INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            )
        """
        
        // Table for transaction history
        let createTransactionsTable = """
            CREATE TABLE IF NOT EXISTS wallet_transactions (
                id TEXT PRIMARY KEY,
                public_key BLOB NOT NULL,
                transaction_id BLOB NOT NULL,
                amount_micro_rlt INTEGER NOT NULL,
                transaction_type TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                description TEXT,
                UNIQUE(public_key, transaction_id)
            )
        """
        
        // Indexes for performance
        let createIndexes = """
            CREATE INDEX IF NOT EXISTS idx_wallets_public_key ON wallets(public_key);
            CREATE INDEX IF NOT EXISTS idx_transactions_public_key ON wallet_transactions(public_key);
            CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON wallet_transactions(created_at);
            CREATE INDEX IF NOT EXISTS idx_transactions_type ON wallet_transactions(transaction_type);
            CREATE INDEX IF NOT EXISTS idx_transactions_tx_id ON wallet_transactions(transaction_id);
        """
        
        var result = sqlite3_exec(db, createWalletsTable, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw WalletError.databaseError("Failed to create wallets table: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        result = sqlite3_exec(db, createTransactionsTable, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw WalletError.databaseError("Failed to create transactions table: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        result = sqlite3_exec(db, createIndexes, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw WalletError.databaseError("Failed to create indexes: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    // MARK: - Wallet Operations
    
    /// Create a new wallet for a public key
    public func createWallet(for publicKey: CryptoCurve25519.Signing.PublicKey) throws {
        let keyHash = publicKey.rawRepresentation.prefix(8).hexEncodedString()
        print("💳 Starting wallet creation for public key: \(keyHash)...")
        
        // Check database connection first
        guard db != nil else {
            print("❌ Database connection is nil!")
            throw WalletError.databaseError("Database connection is nil")
        }
        
        print("💳 About to enter queue.sync for wallet creation...")
        
        do {
            try queue.sync {
                print("💳 Inside queue.sync, creating wallet for public key: \(keyHash)...")
                
                // First check if wallet already exists
                let checkQuery = "SELECT 1 FROM wallets WHERE public_key = ? LIMIT 1"
                var checkStmt: OpaquePointer?
                
                let checkPrepResult = sqlite3_prepare_v2(db, checkQuery, -1, &checkStmt, nil)
                if checkPrepResult == SQLITE_OK {
                    defer { sqlite3_finalize(checkStmt) }
                    
                    let pubKeyData = publicKey.rawRepresentation
                    sqlite3_bind_blob(checkStmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
                    
                    if sqlite3_step(checkStmt) == SQLITE_ROW {
                        print("✅ Wallet already exists for key: \(keyHash)")
                        return
                    }
                } else {
                    let errorMsg = String(cString: sqlite3_errmsg(db))
                    print("❌ Failed to prepare check query: \(errorMsg)")
                }
                
                print("💳 Wallet doesn't exist, creating new one...")
                
                let query = """
                    INSERT OR IGNORE INTO wallets (public_key, balance_micro_rlt, last_updated, created_at)
                    VALUES (?, 0, ?, ?)
                """
                
                var stmt: OpaquePointer?
                let prepResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
                guard prepResult == SQLITE_OK else {
                    let errorMsg = String(cString: sqlite3_errmsg(db))
                    print("❌ Failed to prepare wallet creation query: \(errorMsg)")
                    throw WalletError.databaseError("Failed to prepare wallet creation statement: \(errorMsg)")
                }
                
                defer { 
                    print("💳 Finalizing wallet creation statement...")
                    sqlite3_finalize(stmt) 
                }
                
                let pubKeyData = publicKey.rawRepresentation
                let timestamp = Int64(Date().timeIntervalSince1970)
                
                print("   Public key data length: \(pubKeyData.count)")
                print("   Timestamp: \(timestamp)")
                
                sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
                sqlite3_bind_int64(stmt, 2, timestamp)
                sqlite3_bind_int64(stmt, 3, timestamp)
                
                print("💳 Executing wallet creation statement...")
                let stepResult = sqlite3_step(stmt)
                guard stepResult == SQLITE_DONE else {
                    let errorMsg = String(cString: sqlite3_errmsg(db))
                    print("❌ Failed to execute wallet creation: \(errorMsg), result code: \(stepResult)")
                    throw WalletError.databaseError("Failed to create wallet: \(errorMsg)")
                }
                
                print("✅ Wallet created successfully")
            }
        } catch {
            print("❌ createWallet failed: \(error)")
            throw error
        }
    }
    
    /// Create a new wallet for a public key (unsafe version - no queue, for internal use)
    private func createWalletUnsafe(for publicKey: CryptoCurve25519.Signing.PublicKey) throws {
        let keyHash = publicKey.rawRepresentation.prefix(8).hexEncodedString()
        print("💳 Creating wallet inline for public key: \(keyHash)...")
        
        // Check database connection first
        guard db != nil else {
            print("❌ Database connection is nil!")
            throw WalletError.databaseError("Database connection is nil")
        }
        
        // First check if wallet already exists
        let checkQuery = "SELECT 1 FROM wallets WHERE public_key = ? LIMIT 1"
        var checkStmt: OpaquePointer?
        
        let checkPrepResult = sqlite3_prepare_v2(db, checkQuery, -1, &checkStmt, nil)
        if checkPrepResult == SQLITE_OK {
            defer { sqlite3_finalize(checkStmt) }
            
            let pubKeyData = publicKey.rawRepresentation
            sqlite3_bind_blob(checkStmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
            
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                print("✅ Wallet already exists for key: \(keyHash)")
                return
            }
        } else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("❌ Failed to prepare check query: \(errorMsg)")
        }
        
        print("💳 Wallet doesn't exist, creating new one...")
        
        // Starting balance for testing: 100,000 µRLT (0.1 RLT)
        let testingBalance: Int64 = 100_000
        let query = """
            INSERT OR IGNORE INTO wallets (public_key, balance_micro_rlt, last_updated, created_at)
            VALUES (?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("❌ Failed to prepare wallet creation query: \(errorMsg)")
            throw WalletError.databaseError("Failed to prepare wallet creation statement: \(errorMsg)")
        }
        
        defer { 
            print("💳 Finalizing wallet creation statement...")
            sqlite3_finalize(stmt) 
        }
        
        let pubKeyData = publicKey.rawRepresentation
        let timestamp = Int64(Date().timeIntervalSince1970)
        
        print("   Public key data length: \(pubKeyData.count)")
        print("   Timestamp: \(timestamp)")
        print("   Starting balance: \(testingBalance)µRLT (testing)")
        
        sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
        sqlite3_bind_int64(stmt, 2, testingBalance)
        sqlite3_bind_int64(stmt, 3, timestamp)
        sqlite3_bind_int64(stmt, 4, timestamp)
        
        print("💳 Executing wallet creation statement...")
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("❌ Failed to execute wallet creation: \(errorMsg), result code: \(stepResult)")
            throw WalletError.databaseError("Failed to create wallet: \(errorMsg)")
        }
        
        print("✅ Wallet created successfully with \(testingBalance)µRLT starting balance")
    }
    
    /// Get wallet balance in µRLT
    public func getBalance(for publicKey: CryptoCurve25519.Signing.PublicKey) throws -> UInt64 {
        return try queue.sync {
            let query = "SELECT balance_micro_rlt FROM wallets WHERE public_key = ?"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                throw WalletError.databaseError("Failed to prepare balance query")
            }
            
            defer { sqlite3_finalize(stmt) }
            
            let pubKeyData = publicKey.rawRepresentation
            sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                return UInt64(sqlite3_column_int64(stmt, 0))
            } else {
                // Wallet doesn't exist, create it inline to avoid queue deadlock
                try createWalletUnsafe(for: publicKey)
                
                // Re-execute query to get the actual balance from newly created wallet
                sqlite3_finalize(stmt)
                
                guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                    throw WalletError.databaseError("Failed to prepare balance query after wallet creation")
                }
                
                sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let balance = UInt64(sqlite3_column_int64(stmt, 0))
                    print("💰 Retrieved balance after wallet creation: \(balance)µRLT")
                    return balance
                } else {
                    throw WalletError.databaseError("Failed to read balance after wallet creation")
                }
            }
        }
    }
    
    /// Get wallet balance in µRLT (unsafe version - no queue, for internal use)
    private func getBalanceUnsafe(for publicKey: CryptoCurve25519.Signing.PublicKey) throws -> UInt64 {
        let query = "SELECT balance_micro_rlt FROM wallets WHERE public_key = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw WalletError.databaseError("Failed to prepare balance query")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        let pubKeyData = publicKey.rawRepresentation
        sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return UInt64(sqlite3_column_int64(stmt, 0))
        } else {
            // Wallet doesn't exist, create it inline to avoid queue deadlock
            try createWalletUnsafe(for: publicKey)
            
            // Now query the actual balance from the newly created wallet
            if sqlite3_step(stmt) == SQLITE_ROW {
                return UInt64(sqlite3_column_int64(stmt, 0))
            } else {
                // Re-prepare and execute the query after wallet creation
                sqlite3_finalize(stmt)
                
                guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                    throw WalletError.databaseError("Failed to prepare balance query after wallet creation")
                }
                
                sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    return UInt64(sqlite3_column_int64(stmt, 0))
                } else {
                    throw WalletError.databaseError("Failed to read balance after wallet creation")
                }
            }
        }
    }
    
    /// Award relay rewards to a wallet
    public func awardReward(
        to publicKey: CryptoCurve25519.Signing.PublicKey,
        amount: UInt64,
        transactionId: SHA256Digest
    ) throws {
        try queue.sync {
            // Begin transaction
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            
            do {
                // Ensure wallet exists (using unsafe version to avoid deadlock)
                try createWalletUnsafe(for: publicKey)
                
                // Update balance
                let updateQuery = """
                    UPDATE wallets 
                    SET balance_micro_rlt = balance_micro_rlt + ?, last_updated = ?
                    WHERE public_key = ?
                """
                
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateQuery, -1, &stmt, nil) == SQLITE_OK else {
                    throw WalletError.databaseError("Failed to prepare balance update")
                }
                
                defer { sqlite3_finalize(stmt) }
                
                let pubKeyData = publicKey.rawRepresentation
                let timestamp = Int64(Date().timeIntervalSince1970)
                
                sqlite3_bind_int64(stmt, 1, Int64(amount))
                sqlite3_bind_int64(stmt, 2, timestamp)
                sqlite3_bind_blob(stmt, 3, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw WalletError.databaseError("Failed to update balance")
                }
                
                // Record transaction
                try recordTransaction(
                    publicKey: publicKey,
                    transactionId: transactionId,
                    amount: amount,
                    type: .reward,
                    description: "Relay reward"
                )
                
                // Commit transaction
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }
    
    /// Spend tokens from a wallet
    public func spendTokens(
        from publicKey: CryptoCurve25519.Signing.PublicKey,
        amount: UInt64,
        transactionId: SHA256Digest,
        description: String
    ) throws {
        try queue.sync {
            // Begin transaction
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            
            do {
                // Check balance using unsafe version to avoid deadlock
                let currentBalance = try getBalanceUnsafe(for: publicKey)
                guard currentBalance >= amount else {
                    throw WalletError.insufficientBalance
                }
                
                // Update balance
                let updateQuery = """
                    UPDATE wallets 
                    SET balance_micro_rlt = balance_micro_rlt - ?, last_updated = ?
                    WHERE public_key = ?
                """
                
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, updateQuery, -1, &stmt, nil) == SQLITE_OK else {
                    throw WalletError.databaseError("Failed to prepare balance update")
                }
                
                defer { sqlite3_finalize(stmt) }
                
                let pubKeyData = publicKey.rawRepresentation
                let timestamp = Int64(Date().timeIntervalSince1970)
                
                sqlite3_bind_int64(stmt, 1, Int64(amount))
                sqlite3_bind_int64(stmt, 2, timestamp)
                sqlite3_bind_blob(stmt, 3, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw WalletError.databaseError("Failed to update balance")
                }
                
                // Record transaction
                try recordTransaction(
                    publicKey: publicKey,
                    transactionId: transactionId,
                    amount: amount,
                    type: .spend,
                    description: description
                )
                
                // Commit transaction
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }
    
    /// Get transaction history for a wallet
    public func getTransactionHistory(
        for publicKey: CryptoCurve25519.Signing.PublicKey,
        limit: Int = 100
    ) throws -> [WalletTransaction] {
        return try queue.sync {
            let query = """
                SELECT id, transaction_id, amount_micro_rlt, transaction_type, created_at, description
                FROM wallet_transactions
                WHERE public_key = ?
                ORDER BY created_at DESC
                LIMIT ?
            """
            
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                throw WalletError.databaseError("Failed to prepare history query")
            }
            
            defer { sqlite3_finalize(stmt) }
            
            let pubKeyData = publicKey.rawRepresentation
            sqlite3_bind_blob(stmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            
            var transactions: [WalletTransaction] = []
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let transactionIdData = Data(bytes: sqlite3_column_blob(stmt, 1), count: Int(sqlite3_column_bytes(stmt, 1)))
                let amount = UInt64(sqlite3_column_int64(stmt, 2))
                let typeString = String(cString: sqlite3_column_text(stmt, 3))
                let createdAt = sqlite3_column_int64(stmt, 4)
                let description = String(cString: sqlite3_column_text(stmt, 5))
                
                let transactionId = SHA256Digest(data: transactionIdData)
                let type = WalletTransactionType(rawValue: typeString) ?? .unknown
                
                let transaction = WalletTransaction(
                    id: id,
                    transactionId: transactionId,
                    amount: amount,
                    type: type,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    description: description
                )
                
                transactions.append(transaction)
            }
            
            return transactions
        }
    }
    
    /// Get wallet summary
    public func getWalletSummary(for publicKey: CryptoCurve25519.Signing.PublicKey) throws -> WalletSummary {
        return try queue.sync {
            let balance = try getBalanceUnsafe(for: publicKey)
            let transactions = try getTransactionHistory(for: publicKey, limit: 10)
            
            return WalletSummary(
                publicKey: publicKey,
                balanceMicroRLT: balance,
                balanceRLT: Double(balance) / Double(Self.microRLTPerRLT),
                recentTransactions: transactions
            )
        }
    }
    
    /// Get overall wallet statistics
    public func getStatistics() throws -> WalletStatistics {
        return try queue.sync {
            // Get total balance across all wallets
            let totalBalanceQuery = "SELECT SUM(balance_micro_rlt) FROM wallets"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, totalBalanceQuery, -1, &stmt, nil) == SQLITE_OK else {
                throw WalletError.databaseError("Failed to prepare total balance query")
            }
            
            defer { sqlite3_finalize(stmt) }
            
            var totalBalance: UInt64 = 0
            if sqlite3_step(stmt) == SQLITE_ROW {
                totalBalance = UInt64(sqlite3_column_int64(stmt, 0))
            }
            
            // Get total transaction count
            let transactionCountQuery = "SELECT COUNT(*) FROM wallet_transactions"
            var countStmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, transactionCountQuery, -1, &countStmt, nil) == SQLITE_OK else {
                throw WalletError.databaseError("Failed to prepare transaction count query")
            }
            
            defer { sqlite3_finalize(countStmt) }
            
            var transactionCount: Int = 0
            if sqlite3_step(countStmt) == SQLITE_ROW {
                transactionCount = Int(sqlite3_column_int(countStmt, 0))
            }
            
            // Get reward count
            let rewardCountQuery = "SELECT COUNT(*) FROM wallet_transactions WHERE transaction_type = 'reward'"
            var rewardStmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, rewardCountQuery, -1, &rewardStmt, nil) == SQLITE_OK else {
                throw WalletError.databaseError("Failed to prepare reward count query")
            }
            
            defer { sqlite3_finalize(rewardStmt) }
            
            var rewardCount: Int = 0
            if sqlite3_step(rewardStmt) == SQLITE_ROW {
                rewardCount = Int(sqlite3_column_int(rewardStmt, 0))
            }
            
            return WalletStatistics(
                totalBalance: totalBalance,
                transactionCount: transactionCount,
                rewardCount: rewardCount
            )
        }
    }
    
    // MARK: - Private Helper Methods
    
    private func recordTransaction(
        publicKey: CryptoCurve25519.Signing.PublicKey,
        transactionId: SHA256Digest,
        amount: UInt64,
        type: WalletTransactionType,
        description: String
    ) throws {
        let keyHash = publicKey.rawRepresentation.prefix(8).hexEncodedString()
        let txHash = Data(transactionId).prefix(8).hexEncodedString()
        
        // First check if this transaction already exists for this public key
        let checkQuery = """
            SELECT 1 FROM wallet_transactions 
            WHERE public_key = ? AND transaction_id = ? 
            LIMIT 1
        """
        
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkQuery, -1, &checkStmt, nil) == SQLITE_OK else {
            throw WalletError.databaseError("Failed to prepare transaction check query")
        }
        
        defer { sqlite3_finalize(checkStmt) }
        
        let pubKeyData = publicKey.rawRepresentation
        let txIdData = Data(transactionId)
        
        sqlite3_bind_blob(checkStmt, 1, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
        sqlite3_bind_blob(checkStmt, 2, txIdData.withUnsafeBytes { $0.baseAddress }, Int32(txIdData.count), nil)
        
        // If transaction already exists, just return without error
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            print("⚠️  Transaction \(txHash) already recorded for wallet \(keyHash), skipping duplicate")
            return
        }
        
        // Insert the new transaction record
        let query = """
            INSERT OR IGNORE INTO wallet_transactions (id, public_key, transaction_id, amount_micro_rlt, transaction_type, created_at, description)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw WalletError.databaseError("Failed to prepare transaction record")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        let id = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970)
        
        sqlite3_bind_text(stmt, 1, id, -1, nil)
        sqlite3_bind_blob(stmt, 2, pubKeyData.withUnsafeBytes { $0.baseAddress }, Int32(pubKeyData.count), nil)
        sqlite3_bind_blob(stmt, 3, txIdData.withUnsafeBytes { $0.baseAddress }, Int32(txIdData.count), nil)
        sqlite3_bind_int64(stmt, 4, Int64(amount))
        sqlite3_bind_text(stmt, 5, type.rawValue, -1, nil)
        sqlite3_bind_int64(stmt, 6, timestamp)
        sqlite3_bind_text(stmt, 7, description, -1, nil)
        
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            let errorCode = sqlite3_errcode(db)
            
            // Check if it's a constraint error (likely duplicate)
            if errorCode == SQLITE_CONSTRAINT {
                print("⚠️  Constraint violation when recording transaction \(txHash) for wallet \(keyHash): \(errorMsg)")
                // This is likely a duplicate transaction, which is acceptable in a distributed system
                return
            } else {
                print("❌ Failed to record transaction \(txHash) for wallet \(keyHash): \(errorMsg) (code: \(errorCode))")
                throw WalletError.databaseError("Failed to record transaction: \(errorMsg)")
            }
        }
        
        print("✅ Recorded transaction \(txHash) for wallet \(keyHash): \(amount)µRLT (\(type.rawValue))")
    }
}

// MARK: - Data Structures

public struct WalletTransaction {
    let id: String
    let transactionId: SHA256Digest
    let amount: UInt64
    let type: WalletTransactionType
    let createdAt: Date
    let description: String
}

public enum WalletTransactionType: String, CaseIterable {
    case reward = "reward"
    case spend = "spend"
    case unknown = "unknown"
}

public struct WalletSummary {
    let publicKey: CryptoCurve25519.Signing.PublicKey
    let balanceMicroRLT: UInt64
    let balanceRLT: Double
    let recentTransactions: [WalletTransaction]
}

public struct WalletStatistics {
    public let totalBalance: UInt64
    public let transactionCount: Int
    public let rewardCount: Int
    
    public init(totalBalance: UInt64, transactionCount: Int, rewardCount: Int) {
        self.totalBalance = totalBalance
        self.transactionCount = transactionCount
        self.rewardCount = rewardCount
    }
}

// MARK: - Error Types

public enum WalletError: Error {
    case databaseError(String)
    case insufficientBalance
    case walletNotFound
    case invalidTransaction
}

// Extensions are now in CoreMesh.swift