import Foundation
import SQLite3

/// SQLite-based DAG storage implementation
public final class SQLiteDAGStorage: DAGStorage {
    private var db: OpaquePointer?
    private let dbPath: String
    private let maxTransactions: Int
    private let queue = DispatchQueue(label: "dag.storage", qos: .userInitiated)
    
    /// Current tip transactions (those with no children)
    private var currentTips: Set<SHA256Digest> = []
    private var tipUpdateLock = NSLock()
    
    public init(dbPath: String, maxTransactions: Int = 1000) throws {
        self.dbPath = dbPath
        self.maxTransactions = maxTransactions
        
        // Create database directory if needed
        let dbDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        
        // Open database
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        try createTables()
        try loadTips()
        try rebuildTipsFromDatabase()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    private func createTables() throws {
        let createTransactionsTable = """
            CREATE TABLE IF NOT EXISTS transactions (
                id BLOB PRIMARY KEY,
                parent1_id BLOB NOT NULL,
                parent2_id BLOB NOT NULL,
                fee_per_hop INTEGER NOT NULL,
                sender_pub BLOB NOT NULL,
                signature BLOB NOT NULL,
                created_at INTEGER NOT NULL,
                is_tip INTEGER NOT NULL DEFAULT 1
            )
        """
        
        let createIndexes = """
            CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at);
            CREATE INDEX IF NOT EXISTS idx_transactions_is_tip ON transactions(is_tip);
            CREATE INDEX IF NOT EXISTS idx_transactions_parent1 ON transactions(parent1_id);
            CREATE INDEX IF NOT EXISTS idx_transactions_parent2 ON transactions(parent2_id);
        """
        
        var result = sqlite3_exec(db, createTransactionsTable, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to create transactions table: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        result = sqlite3_exec(db, createIndexes, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to create indexes: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    private func loadTips() throws {
        let query = "SELECT id FROM transactions WHERE is_tip = 1"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to prepare tips query")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        tipUpdateLock.lock()
        currentTips.removeAll()
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idData = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
            let digest = SHA256Digest(data: idData)
            currentTips.insert(digest)
        }
        tipUpdateLock.unlock()
    }
    
    /// Rebuild tips from database to ensure consistency
    private func rebuildTipsFromDatabase() throws {
        print("🔄 Rebuilding tips from database...")
        
        // Find all transactions that have no children (i.e., are tips)
        let query = """
            SELECT DISTINCT t1.id 
            FROM transactions t1
            LEFT JOIN transactions t2 ON (t1.id = t2.parent1_id OR t1.id = t2.parent2_id)
            WHERE t2.id IS NULL
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to prepare tips rebuild query")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        tipUpdateLock.lock()
        currentTips.removeAll()
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idData = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
            let digest = SHA256Digest(data: idData)
            currentTips.insert(digest)
            print("   Found tip: \(digest.hexString)")
        }
        tipUpdateLock.unlock()
        
        print("✅ Rebuilt \(currentTips.count) tips from database")
    }
    
    // MARK: - DAGStorage Protocol Implementation
    
    public func contains(transactionID: SHA256Digest) -> Bool {
        return queue.sync {
            let query = "SELECT 1 FROM transactions WHERE id = ? LIMIT 1"
            var stmt: OpaquePointer?
            
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                return false
            }
            
            defer { sqlite3_finalize(stmt) }
            
            let idData = Data(transactionID)
            sqlite3_bind_blob(stmt, 1, idData.withUnsafeBytes { $0.baseAddress }, Int32(idData.count), nil)
            
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }
    
    public func getTips() -> [SHA256Digest] {
        tipUpdateLock.lock()
        defer { tipUpdateLock.unlock() }
        
        // Clean up any tips that don't actually exist in storage
        let validTips = currentTips.filter { tip in
            let exists = self.contains(transactionID: tip)
            if !exists {
                print("⚠️  Removing stale tip: \(tip.hexString)")
            }
            return exists
        }
        
        // Update currentTips to only contain valid tips
        currentTips = Set(validTips)
        
        return Array(validTips)
    }
    
    public func addTransaction(_ transaction: SignedRelayTx) throws {
        try queue.sync {
            // Begin transaction
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            
            do {
                // Insert the transaction
                let insertQuery = """
                    INSERT INTO transactions (id, parent1_id, parent2_id, fee_per_hop, sender_pub, signature, created_at, is_tip)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                """
                
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertQuery, -1, &stmt, nil) == SQLITE_OK else {
                    throw DAGStorageError.databaseError("Failed to prepare insert statement")
                }
                
                defer { sqlite3_finalize(stmt) }
                
                let idData = Data(transaction.transaction.id)
                let parent1Data = Data(transaction.transaction.parents[0])
                let parent2Data = Data(transaction.transaction.parents[1])
                let senderPubData = transaction.transaction.senderPub.rawRepresentation
                let timestamp = Int64(Date().timeIntervalSince1970)
                
                sqlite3_bind_blob(stmt, 1, idData.withUnsafeBytes { $0.baseAddress }, Int32(idData.count), nil)
                sqlite3_bind_blob(stmt, 2, parent1Data.withUnsafeBytes { $0.baseAddress }, Int32(parent1Data.count), nil)
                sqlite3_bind_blob(stmt, 3, parent2Data.withUnsafeBytes { $0.baseAddress }, Int32(parent2Data.count), nil)
                sqlite3_bind_int64(stmt, 4, Int64(transaction.transaction.feePerHop))
                sqlite3_bind_blob(stmt, 5, senderPubData.withUnsafeBytes { $0.baseAddress }, Int32(senderPubData.count), nil)
                sqlite3_bind_blob(stmt, 6, transaction.signature.withUnsafeBytes { $0.baseAddress }, Int32(transaction.signature.count), nil)
                sqlite3_bind_int64(stmt, 7, timestamp)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAGStorageError.databaseError("Failed to insert transaction")
                }
                
                // Update parent tips status (they're no longer tips)
                try updateParentTipStatus(transaction.transaction.parents)
                
                // Update current tips
                try updateCurrentTips(newTxId: transaction.transaction.id, parents: transaction.transaction.parents)
                
                // Prune old transactions if necessary
                try pruneOldTransactions()
                
                // Commit transaction
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }
    
    public func getTransaction(_ id: SHA256Digest) -> SignedRelayTx? {
        return queue.sync {
            let query = """
                SELECT parent1_id, parent2_id, fee_per_hop, sender_pub, signature 
                FROM transactions WHERE id = ?
            """
            
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            
            defer { sqlite3_finalize(stmt) }
            
            let idData = Data(id)
            sqlite3_bind_blob(stmt, 1, idData.withUnsafeBytes { $0.baseAddress }, Int32(idData.count), nil)
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            
            do {
                let parent1Data = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
                let parent2Data = Data(bytes: sqlite3_column_blob(stmt, 1), count: Int(sqlite3_column_bytes(stmt, 1)))
                let feePerHop = UInt32(sqlite3_column_int64(stmt, 2))
                let senderPubData = Data(bytes: sqlite3_column_blob(stmt, 3), count: Int(sqlite3_column_bytes(stmt, 3)))
                let signature = Data(bytes: sqlite3_column_blob(stmt, 4), count: Int(sqlite3_column_bytes(stmt, 4)))
                
                let parent1 = SHA256Digest(data: parent1Data)
                let parent2 = SHA256Digest(data: parent2Data)
                let senderPub = try CryptoCurve25519.Signing.PublicKey(rawRepresentation: senderPubData)
                
                let transaction = RelayTx(parents: [parent1, parent2], feePerHop: feePerHop, senderPub: senderPub)
                return SignedRelayTx(transaction: transaction, signature: signature)
                
            } catch {
                return nil
            }
        }
    }
    
    // MARK: - Private Helper Methods
    
    private func updateParentTipStatus(_ parents: [SHA256Digest]) throws {
        let updateQuery = "UPDATE transactions SET is_tip = 0 WHERE id = ?"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, updateQuery, -1, &stmt, nil) == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to prepare update statement")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        for parent in parents {
            let parentData = Data(parent)
            sqlite3_bind_blob(stmt, 1, parentData.withUnsafeBytes { $0.baseAddress }, Int32(parentData.count), nil)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAGStorageError.databaseError("Failed to update parent tip status")
            }
            
            sqlite3_reset(stmt)
        }
    }
    
    private func updateCurrentTips(newTxId: SHA256Digest, parents: [SHA256Digest]) throws {
        tipUpdateLock.lock()
        defer { tipUpdateLock.unlock() }
        
        // Remove parents from tips (they're no longer tips)
        for parent in parents {
            currentTips.remove(parent)
        }
        
        // Add new transaction as tip
        currentTips.insert(newTxId)
    }
    
    private func pruneOldTransactions() throws {
        let countQuery = "SELECT COUNT(*) FROM transactions"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, countQuery, -1, &stmt, nil) == SQLITE_OK else {
            throw DAGStorageError.databaseError("Failed to prepare count query")
        }
        
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DAGStorageError.databaseError("Failed to get transaction count")
        }
        
        let count = Int(sqlite3_column_int64(stmt, 0))
        
        if count > maxTransactions {
            let deleteCount = count - maxTransactions
            let deleteQuery = """
                DELETE FROM transactions WHERE id IN (
                    SELECT id FROM transactions 
                    ORDER BY created_at ASC 
                    LIMIT ?
                )
            """
            
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteQuery, -1, &deleteStmt, nil) == SQLITE_OK else {
                throw DAGStorageError.databaseError("Failed to prepare delete statement")
            }
            
            defer { sqlite3_finalize(deleteStmt) }
            
            sqlite3_bind_int64(deleteStmt, 1, Int64(deleteCount))
            
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw DAGStorageError.databaseError("Failed to prune old transactions")
            }
        }
    }
    
    /// Get DAG storage statistics
    public func getStatistics() -> DAGStatistics {
        return queue.sync {
            var totalTransactions = 0
            var totalWeight: UInt64 = 0
            
            // Count total transactions and calculate total weight
            let query = "SELECT COUNT(*), SUM(fee_per_hop) FROM transactions"
            var stmt: OpaquePointer?
            
            defer { sqlite3_finalize(stmt) }
            
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    totalTransactions = Int(sqlite3_column_int(stmt, 0))
                    totalWeight = UInt64(sqlite3_column_int64(stmt, 1))
                }
            }
            
            // Get current tip count
            tipUpdateLock.lock()
            let tipCount = currentTips.count
            tipUpdateLock.unlock()
            
            return DAGStatistics(
                totalTransactions: totalTransactions,
                tipCount: tipCount,
                totalWeight: totalWeight
            )
        }
    }
}

// MARK: - Error Types

public enum DAGStorageError: Error {
    case databaseError(String)
    case transactionNotFound
    case invalidTransaction
    case pruningError
}

// Helper extensions are now in CoreMesh.swift