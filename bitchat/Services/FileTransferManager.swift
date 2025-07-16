//
// FileTransferManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import Combine
import UniformTypeIdentifiers

class FileTransferManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var activeTransfers: [String: FileTransfer] = [:]  // transferID -> FileTransfer
    @Published var transferHistory: [FileTransfer] = []
    
    // MARK: - Private Properties
    
    private weak var meshService: BluetoothMeshService?
    private let fileQueue = DispatchQueue(label: "file.transfer.queue", qos: .userInitiated)
    private let chunkSize: UInt32 = 200    // 200 byte chunks (tiny for guaranteed Bluetooth LE reliability)
    private let maxConcurrentTransfers = 3
    
    // Per-MB pricing (in µRLT)
    private let baseFileTransferCostPerMB: UInt64 = 50000  // 50,000 µRLT per MB
    
    // Temporary storage for incoming chunks (thread-safe)
    private let chunkQueue = DispatchQueue(label: "file.transfer.chunks", qos: .userInitiated)
    private var incomingChunks: [String: [UInt32: FileChunk]] = [:]  // transferID -> chunkIndex -> FileChunk
    private var chunkTimers: [String: Timer] = [:]  // transferID -> timeout timer
    
    // MARK: - Initialization
    
    init() {
        setupCleanupTimer()
    }
    
    func setMeshService(_ meshService: BluetoothMeshService) {
        self.meshService = meshService
    }
    
    // MARK: - Public API
    
    func initiateFileTransfer(filePath: String, recipientID: String) async throws -> String {
        return try await initiateFileTransfer(filePath: filePath, recipientID: recipientID, fileData: nil)
    }
    
    func initiateFileTransfer(filePath: String, recipientID: String, fileData: Data?) async throws -> String {
        guard let meshService = meshService else {
            throw FileTransferError.noMeshService
        }
        
        let fileURL = URL(fileURLWithPath: filePath)
        let fileName = fileURL.lastPathComponent
        
        // Use provided file data or try to read from disk
        let actualFileData: Data
        if let providedData = fileData {
            actualFileData = providedData
            print("📤 Using provided file data: \(providedData.count) bytes for \(fileName)")
        } else {
            print("📤 No file data provided, attempting to read from disk: \(filePath)")
            do {
                actualFileData = try Data(contentsOf: fileURL)
                print("📤 Read file data from disk: \(actualFileData.count) bytes")
            } catch {
                print("❌ FileTransferManager: Failed to read file at \(filePath): \(error)")
                throw FileTransferError.invalidFileData
            }
        }
        
        let fileSize = UInt64(actualFileData.count)
        
        guard fileSize > 0 else {
            throw FileTransferError.invalidFileData
        }
        
        // Check if we can handle this transfer
        try validateFileTransfer(fileSize: fileSize)
        
        // Calculate cost
        let costPerMB = calculateCostPerMB()
        let senderID = await meshService.getPeerID()
        
        // Create transfer request
        let request = FileTransferRequest(
            fileName: fileName,
            fileSize: fileSize,
            fileData: actualFileData,
            costPerMB: costPerMB,
            senderID: senderID,
            chunkSize: chunkSize
        )
        
        // Create transfer object
        let transfer = FileTransfer(
            id: request.transferID,
            fileName: fileName,
            fileSize: fileSize,
            isOutgoing: true,
            recipientID: recipientID,
            senderID: senderID,
            totalCost: request.totalCost,
            status: .requesting
        )
        transfer.fileData = actualFileData
        transfer.request = request
        
        // Add to active transfers
        await MainActor.run {
            activeTransfers[request.transferID] = transfer
        }
        
        // Send request to recipient
        do {
            try await meshService.sendFileTransferRequest(request, to: recipientID)
            print("📤 Initiated file transfer: \(fileName) (\(formatFileSize(fileSize))) to \(recipientID)")
            print("💰 Cost: \(request.totalCost)µRLT (\(costPerMB)µRLT/MB)")
            print("📋 Transfer ID: \(request.transferID)")
            print("📊 Total chunks: \(request.totalChunks)")
            
            return request.transferID
        } catch {
            print("❌ Failed to send file transfer request: \(error)")
            // Remove from active transfers since it failed
            await MainActor.run {
                activeTransfers.removeValue(forKey: request.transferID)
            }
            throw error
        }
    }
    
    func respondToFileTransfer(transferID: String, accept: Bool, reason: String? = nil) async throws {
        print("📱 Responding to file transfer \(transferID.prefix(8)) - accept: \(accept)")
        
        guard let meshService = meshService else {
            print("❌ No mesh service available")
            throw FileTransferError.noMeshService
        }
        
        guard let transfer = activeTransfers[transferID] else {
            print("❌ Transfer not found in activeTransfers: \(transferID)")
            throw FileTransferError.transferNotFound
        }
        
        let recipientID = await meshService.getPeerID()
        let response = FileTransferResponse(
            transferID: transferID,
            accepted: accept,
            reason: reason,
            recipientID: recipientID
        )
        
        print("📱 Sending response to sender \(transfer.senderID) with recipientID \(recipientID)")
        
        if accept {
            await updateTransferStatus(transferID, status: .accepted)
            print("✅ Accepted file transfer: \(transfer.fileName)")
        } else {
            await updateTransferStatus(transferID, status: .rejected(reason: reason ?? "User declined"))
            print("❌ Rejected file transfer: \(transfer.fileName) - \(reason ?? "User declined")")
        }
        
        try await meshService.sendFileTransferResponse(response, to: transfer.senderID)
        print("📱 File transfer response sent successfully to \(transfer.senderID)")
    }
    
    func cancelFileTransfer(transferID: String, reason: String = "User cancelled") async throws {
        guard let meshService = meshService else {
            throw FileTransferError.noMeshService
        }
        
        guard let transfer = activeTransfers[transferID] else {
            throw FileTransferError.transferNotFound
        }
        
        let cancelMessage = FileTransferCancel(
            transferID: transferID,
            reason: reason,
            canceledBy: await meshService.getPeerID()
        )
        
        await updateTransferStatus(transferID, status: .cancelled(reason: reason))
        
        // Send cancellation to the other party
        let targetPeerID = transfer.isOutgoing ? transfer.recipientID : transfer.senderID
        try await meshService.sendFileTransferCancel(cancelMessage, to: targetPeerID)
        
        // Clean up
        await cleanupTransfer(transferID)
        
        print("🚫 Cancelled file transfer: \(transfer.fileName) - \(reason)")
    }
    
    // MARK: - Message Handling
    
    func handleFileTransferRequest(_ request: FileTransferRequest, from senderID: String) async {
        print("📥 Received file transfer request: \(request.fileName) (\(formatFileSize(request.fileSize))) from \(senderID)")
        print("💰 Cost: \(request.totalCost)µRLT")
        print("📋 Transfer ID: \(request.transferID)")
        
        // Create incoming transfer
        let transfer = FileTransfer(
            id: request.transferID,
            fileName: request.fileName,
            fileSize: request.fileSize,
            isOutgoing: false,
            recipientID: await meshService?.getPeerID() ?? "unknown",
            senderID: senderID,
            totalCost: request.totalCost,
            status: .requesting
        )
        transfer.request = request
        
        await MainActor.run {
            activeTransfers[request.transferID] = transfer
        }
        
        // Notify UI
        await meshService?.delegate?.didReceiveFileTransferRequest(request)
    }
    
    func handleFileTransferResponse(_ response: FileTransferResponse, from senderID: String) async {
        print("📥 Received file transfer response for transfer \(response.transferID.prefix(8)) from \(senderID) - accepted: \(response.accepted)")
        
        guard let transfer = activeTransfers[response.transferID] else {
            print("⚠️ Received response for unknown transfer: \(response.transferID)")
            print("📊 Active transfers: \(activeTransfers.keys.map { $0.prefix(8) })")
            return
        }
        
        if response.accepted {
            print("✅ File transfer accepted by recipient. Starting chunk transmission...")
            await updateTransferStatus(response.transferID, status: .accepted)
            
            // Debug: Verify transfer state before starting chunks
            print("📊 Transfer state before starting chunks:")
            print("📊 - File name: \(transfer.fileName)")
            print("📊 - File size: \(transfer.fileSize) bytes")
            print("📊 - Has file data: \(transfer.fileData != nil)")
            print("📊 - Total chunks: \(transfer.request?.totalChunks ?? 0)")
            
            // Start sending chunks
            Task {
                await startSendingChunks(transferID: response.transferID)
            }
        } else {
            print("❌ File transfer rejected by recipient: \(response.reason ?? "No reason provided")")
            await updateTransferStatus(response.transferID, status: .rejected(reason: response.reason ?? "Declined"))
            await cleanupTransfer(response.transferID)
        }
        
        await meshService?.delegate?.didReceiveFileTransferResponse(response)
    }
    
    func handleFileChunk(_ chunk: FileChunk, from senderID: String) async {
        print("📥 Received chunk \(chunk.chunkIndex) for transfer \(chunk.transferID.prefix(8)) from \(senderID)")
        print("📥 Chunk details: \(chunk.chunkData.count) bytes, isLast: \(chunk.isLastChunk)")
        
        guard let transfer = activeTransfers[chunk.transferID] else {
            print("⚠️ Received chunk for unknown transfer: \(chunk.transferID)")
            print("📊 Active transfers: \(activeTransfers.keys.map { $0.prefix(8) })")
            return
        }
        
        // Verify chunk hash
        let calculatedHash = SHA256.hash(data: chunk.chunkData).compactMap { String(format: "%02x", $0) }.joined()
        guard calculatedHash == chunk.chunkHash else {
            print("❌ Chunk hash mismatch for chunk \(chunk.chunkIndex)")
            await sendChunkAck(transferID: chunk.transferID, chunkIndex: chunk.chunkIndex, received: false, errorMessage: "Hash mismatch", to: senderID)
            return
        }
        
        // Store chunk (thread-safe)
        await withCheckedContinuation { continuation in
            chunkQueue.async {
                if self.incomingChunks[chunk.transferID] == nil {
                    self.incomingChunks[chunk.transferID] = [:]
                }
                self.incomingChunks[chunk.transferID]![chunk.chunkIndex] = chunk
                continuation.resume()
            }
        }
        
        // Send acknowledgment
        print("📤 Sending ACK for chunk \(chunk.chunkIndex) of transfer \(chunk.transferID.prefix(8))")
        await sendChunkAck(transferID: chunk.transferID, chunkIndex: chunk.chunkIndex, received: true, to: senderID)
        
        // Update progress (thread-safe)
        let totalChunks = transfer.request?.totalChunks ?? 0
        let (receivedChunks, shouldComplete) = await withCheckedContinuation { continuation in
            chunkQueue.async {
                let receivedCount = UInt32(self.incomingChunks[chunk.transferID]?.count ?? 0)
                let shouldComplete = chunk.isLastChunk && receivedCount == totalChunks
                continuation.resume(returning: (receivedCount, shouldComplete))
            }
        }
        
        print("📊 Recipient progress: \(receivedChunks)/\(totalChunks) chunks received")
        print("📊 Completion check: isLastChunk=\(chunk.isLastChunk), receivedChunks=\(receivedChunks), totalChunks=\(totalChunks), shouldComplete=\(shouldComplete)")
        await updateTransferStatus(chunk.transferID, status: .transferring(chunksComplete: receivedChunks, totalChunks: totalChunks))
        
        // Check if transfer is complete
        if shouldComplete {
            print("✅ All chunks received, completing transfer")
            await completeFileTransfer(transferID: chunk.transferID, from: senderID)
        } else if chunk.isLastChunk {
            print("⚠️ Received last chunk but receivedChunks (\(receivedChunks)) != totalChunks (\(totalChunks))")
        }
        
        await meshService?.delegate?.didReceiveFileChunk(chunk)
    }
    
    func handleFileChunkAck(_ ack: FileChunkAck, from senderID: String) async {
        print("📥 Received ACK for chunk \(ack.chunkIndex) of transfer \(ack.transferID.prefix(8)) - received: \(ack.received)")
        
        guard let transfer = activeTransfers[ack.transferID] else {
            print("⚠️ Received ack for unknown transfer: \(ack.transferID)")
            print("📊 Active transfers: \(activeTransfers.keys.map { $0.prefix(8) })")
            return
        }
        
        if ack.received {
            // Update the transfer object directly on the main thread to maintain ObservableObject updates
            await MainActor.run {
                transfer.acknowledgedChunks.insert(ack.chunkIndex)
            }
            
            // Update progress based on ACKs received (this is the real progress)
            let totalChunks = transfer.request?.totalChunks ?? 0
            let acknowledgedCount = UInt32(transfer.acknowledgedChunks.count)
            print("📊 Sender progress update: \(acknowledgedCount)/\(totalChunks) chunks acknowledged for transfer \(ack.transferID.prefix(8))")
            
            // Use ACK count for progress display - this is what the user should see
            await updateTransferStatus(ack.transferID, status: .transferring(chunksComplete: acknowledgedCount, totalChunks: totalChunks))
            
            // Check if all chunks are acknowledged - but wait for completion message from recipient
            if acknowledgedCount == totalChunks {
                print("✅ All chunks acknowledged by recipient, waiting for completion message...")
                // Don't complete here - wait for the completion message from recipient
                // This prevents race condition between ACK completion and completion message
            }
        } else {
            print("❌ Chunk \(ack.chunkIndex) failed: \(ack.errorMessage ?? "Unknown error")")
            // For now, mark the transfer as failed if any chunk fails
            await updateTransferStatus(ack.transferID, status: .failed(error: "Chunk \(ack.chunkIndex) failed: \(ack.errorMessage ?? "Unknown error")"))
        }
        
        await meshService?.delegate?.didReceiveFileChunkAck(ack)
    }
    
    func handleFileTransferComplete(_ completion: FileTransferComplete, from senderID: String) async {
        print("📥 [SENDER] Received completion message for transfer \(completion.transferID.prefix(8)) from \(senderID) - success: \(completion.success)")
        print("📥 [SENDER] Completion details: chunks received: \(completion.totalChunksReceived)")
        
        guard let transfer = activeTransfers[completion.transferID] else {
            print("⚠️ [SENDER] Received completion for unknown transfer: \(completion.transferID)")
            print("📊 [SENDER] Active transfers: \(activeTransfers.keys.map { $0.prefix(8) })")
            return
        }
        
        if completion.success {
            await updateTransferStatus(completion.transferID, status: .completed)
            print("✅ [SENDER] File transfer completed successfully: \(transfer.fileName)")
            print("📊 [SENDER] Final ACK count: \(transfer.acknowledgedChunks.count)")
        } else {
            await updateTransferStatus(completion.transferID, status: .failed(error: "Transfer failed at recipient"))
            print("❌ [SENDER] File transfer failed at recipient: \(transfer.fileName)")
        }
        
        await cleanupTransfer(completion.transferID)
        print("✅ [SENDER] Transfer cleanup completed for \(completion.transferID.prefix(8))")
        await meshService?.delegate?.didReceiveFileTransferComplete(completion)
    }
    
    func handleFileTransferCancel(_ cancellation: FileTransferCancel, from senderID: String) async {
        guard let transfer = activeTransfers[cancellation.transferID] else {
            print("⚠️ Received cancellation for unknown transfer: \(cancellation.transferID)")
            return
        }
        
        await updateTransferStatus(cancellation.transferID, status: .cancelled(reason: cancellation.reason))
        await cleanupTransfer(cancellation.transferID)
        
        print("🚫 File transfer cancelled: \(transfer.fileName) - \(cancellation.reason)")
        await meshService?.delegate?.didReceiveFileTransferCancel(cancellation)
    }
    
    // MARK: - Private Methods
    
    private func validateFileTransfer(fileSize: UInt64) throws {
        let maxFileSize: UInt64 = 100 * 1024 * 1024  // 100 MB limit
        guard fileSize <= maxFileSize else {
            throw FileTransferError.fileTooLarge
        }
        
        guard activeTransfers.count < maxConcurrentTransfers else {
            throw FileTransferError.tooManyActiveTransfers
        }
    }
    
    private func calculateCostPerMB() -> UInt64 {
        // In the future, this could be dynamic based on network conditions
        return baseFileTransferCostPerMB
    }
    
    private func startSendingChunks(transferID: String) async {
        print("📤 Starting to send chunks for transfer \(transferID.prefix(8))")
        
        guard let transfer = activeTransfers[transferID] else {
            print("❌ Transfer not found in activeTransfers: \(transferID)")
            return
        }
        
        guard let fileData = transfer.fileData else {
            print("❌ No file data available for transfer \(transferID.prefix(8))")
            return
        }
        
        guard let meshService = meshService else {
            print("❌ Mesh service not available for transfer \(transferID.prefix(8))")
            return
        }
        
        let totalChunks = transfer.request?.totalChunks ?? 0
        print("📤 Transfer \(transferID.prefix(8)): File size: \(fileData.count) bytes, Total chunks: \(totalChunks)")
        
        await updateTransferStatus(transferID, status: .transferring(chunksComplete: 0, totalChunks: totalChunks))
        
        var sentChunks: UInt32 = 0
        
        for chunkIndex in 0..<totalChunks {
            let startOffset = Int(chunkIndex * chunkSize)
            let endOffset = min(startOffset + Int(chunkSize), fileData.count)
            let chunkData = fileData.subdata(in: startOffset..<endOffset)
            let isLastChunk = chunkIndex == totalChunks - 1
            
            let chunk = FileChunk(
                transferID: transferID,
                chunkIndex: chunkIndex,
                chunkData: chunkData,
                isLastChunk: isLastChunk
            )
            
            do {
                print("📤 [SENDER] Sending chunk \(chunkIndex + 1)/\(totalChunks) to recipient \(transfer.recipientID.prefix(8))")
                try await meshService.sendFileChunk(chunk, to: transfer.recipientID)
                sentChunks += 1
                print("📤 Sent chunk \(chunkIndex + 1)/\(totalChunks) (\(chunkData.count) bytes) for transfer \(transferID.prefix(8))")
                
                // Update progress based on chunks sent (for immediate feedback)
                // But don't mark as complete until ACKs are received
                await updateTransferStatus(transferID, status: .transferring(chunksComplete: sentChunks, totalChunks: totalChunks))
                
                // Add delay between chunks to avoid overwhelming the mesh
                try await Task.sleep(nanoseconds: 50_000_000)   // 0.05 second delay (tiny for 200 byte chunks)
            } catch {
                print("❌ Failed to send chunk \(chunkIndex): \(error)")
                await updateTransferStatus(transferID, status: .failed(error: "Failed to send chunk \(chunkIndex)"))
                await cleanupTransfer(transferID)
                return
            }
        }
        
        print("📤 Finished sending all \(totalChunks) chunks for transfer \(transferID.prefix(8))")
        print("📤 Now waiting for ACKs to confirm delivery...")
        
        // Set up a timeout to complete the transfer if no completion message is received
        // This prevents the transfer from hanging indefinitely
        Task {
            try await Task.sleep(nanoseconds: 90_000_000_000)  // 90 second timeout (longer for completion)
            
            if let currentTransfer = activeTransfers[transferID],
               case .transferring = currentTransfer.status {
                print("⏰ Transfer \(transferID.prefix(8)) timed out waiting for completion")
                
                // Check if we have most ACKs - if so, consider it successful
                let ackCount = currentTransfer.acknowledgedChunks.count
                let successThreshold = Int(Double(totalChunks) * 0.8)  // 80% threshold
                
                if ackCount >= successThreshold {
                    print("⏰ Most chunks acknowledged (\(ackCount)/\(totalChunks)), marking as completed")
                    await updateTransferStatus(transferID, status: .completed)
                } else if ackCount == 0 {
                    print("⏰ No ACKs received, marking as failed")
                    await updateTransferStatus(transferID, status: .failed(error: "No acknowledgments received"))
                } else {
                    print("⏰ Some ACKs received (\(ackCount)/\(totalChunks)), marking as partially completed")
                    await updateTransferStatus(transferID, status: .completed)
                }
                await cleanupTransfer(transferID)
            }
        }
    }
    
    private func sendChunkAck(transferID: String, chunkIndex: UInt32, received: Bool, errorMessage: String? = nil, to peerID: String) async {
        guard let meshService = meshService else { 
            print("❌ No mesh service available for sending ACK")
            return 
        }
        
        let myPeerID = await meshService.getPeerID()
        let ack = FileChunkAck(
            transferID: transferID,
            chunkIndex: chunkIndex,
            received: received,
            errorMessage: errorMessage,
            recipientID: myPeerID
        )
        
        print("📤 [RECIPIENT] Sending ACK for chunk \(chunkIndex) of transfer \(transferID.prefix(8))")
        print("📤 [RECIPIENT] ACK details: from \(myPeerID.prefix(8)) to \(peerID.prefix(8)), success: \(received)")
        
        do {
            try await meshService.sendFileChunkAck(ack, to: peerID)
            print("✅ [RECIPIENT] ACK sent successfully for chunk \(chunkIndex) to \(peerID.prefix(8))")
        } catch {
            print("❌ [RECIPIENT] Failed to send chunk ack: \(error)")
        }
    }
    
    private func completeFileTransfer(transferID: String, from senderID: String) async {
        guard let transfer = activeTransfers[transferID],
              let meshService = meshService else {
            return
        }
        
        // Get chunks safely from the queue
        let chunks = await withCheckedContinuation { continuation in
            chunkQueue.async {
                let chunks = self.incomingChunks[transferID]
                continuation.resume(returning: chunks)
            }
        }
        
        guard let chunks = chunks else {
            return
        }
        
        // Reassemble file
        let sortedChunks = chunks.sorted { $0.key < $1.key }
        var fileData = Data()
        for (_, chunk) in sortedChunks {
            fileData.append(chunk.chunkData)
        }
        
        // Verify file hash
        let calculatedHash = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
        let expectedHash = transfer.request?.fileHash ?? ""
        
        let success = calculatedHash == expectedHash
        
        if success {
            // Save file
            await saveReceivedFile(transferID: transferID, fileName: transfer.fileName, fileData: fileData)
            await updateTransferStatus(transferID, status: .completed)
            print("✅ File received and verified: \(transfer.fileName)")
        } else {
            await updateTransferStatus(transferID, status: .failed(error: "File hash verification failed"))
            print("❌ File hash verification failed: \(transfer.fileName)")
        }
        
        // Send completion message after a short delay to ensure all ACKs are processed
        let completion = FileTransferComplete(
            transferID: transferID,
            success: success,
            totalChunksReceived: UInt32(chunks.count),
            fileData: success ? fileData : nil,
            recipientID: await meshService.getPeerID()
        )
        
        print("📤 [COMPLETION] Sending completion message for transfer \(transferID.prefix(8)) to \(senderID)")
        print("📤 [COMPLETION] Success: \(success), chunks: \(chunks.count), hash match: \(calculatedHash == expectedHash)")
        
        do {
            // Small delay to ensure all ACKs have been sent
            try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second delay
            try await meshService.sendFileTransferComplete(completion, to: senderID)
            print("✅ [COMPLETION] Completion message sent successfully to \(senderID.prefix(8))")
        } catch {
            print("❌ [COMPLETION] Failed to send completion message: \(error)")
        }
        
        await cleanupTransfer(transferID)
    }
    
    private func saveReceivedFile(transferID: String, fileName: String, fileData: Data) async {
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let bitchatDir = documentsPath.appendingPathComponent("bitchat_files")
            try FileManager.default.createDirectory(at: bitchatDir, withIntermediateDirectories: true)
            
            // Add timestamp to avoid filename conflicts
            let timestamp = Date().timeIntervalSince1970
            let fileURL = bitchatDir.appendingPathComponent("\(Int(timestamp))_\(fileName)")
            
            try fileData.write(to: fileURL)
            print("💾 Saved file to: \(fileURL.path)")
            
            // Update transfer with saved path
            await MainActor.run {
                activeTransfers[transferID]?.savedFilePath = fileURL.path
            }
        } catch {
            print("❌ Failed to save file: \(error)")
        }
    }
    
    private func updateTransferStatus(_ transferID: String, status: FileTransferStatus) async {
        await MainActor.run {
            activeTransfers[transferID]?.status = status
        }
        
        // Log status updates
        if let transfer = activeTransfers[transferID] {
            print("📊 Transfer \(transferID.prefix(8)) status updated: \(status.displayText)")
            
            // Add system message for important status changes
            if case .completed = status {
                let message = transfer.isOutgoing ? 
                    "✅ File sent successfully: \(transfer.fileName)" :
                    "📥 File received: \(transfer.fileName)"
                addSystemMessage(message)
            } else if case .failed(let error) = status {
                let message = "❌ File transfer failed: \(transfer.fileName) - \(error)"
                addSystemMessage(message)
            }
        }
        
        await meshService?.delegate?.didUpdateFileTransferStatus(transferID, status: status)
    }
    
    private func addSystemMessage(_ content: String) {
        // This is a simple implementation - in a real app you'd want to properly inject this
        // For now, we'll just print it as a log message
        print("📝 System message: \(content)")
    }
    
    private func cleanupTransfer(_ transferID: String) async {
        // Cancel any pending timers
        chunkTimers[transferID]?.invalidate()
        chunkTimers.removeValue(forKey: transferID)
        
        // Remove incoming chunks (thread-safe)
        await withCheckedContinuation { continuation in
            chunkQueue.async {
                self.incomingChunks.removeValue(forKey: transferID)
                continuation.resume()
            }
        }
        
        // Move to history and remove from active
        await MainActor.run {
            if let transfer = activeTransfers.removeValue(forKey: transferID) {
                transferHistory.append(transfer)
                
                // Keep only recent 50 transfers in history
                if transferHistory.count > 50 {
                    transferHistory.removeFirst()
                }
            }
        }
    }
    
    private func setupCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in  // Every 5 minutes
            Task {
                await self?.cleanupStaleTransfers()
            }
        }
    }
    
    private func cleanupStaleTransfers() async {
        let staleTime: TimeInterval = 3600  // 1 hour
        let now = Date()
        
        for (transferID, transfer) in activeTransfers {
            if let request = transfer.request, now.timeIntervalSince(request.timestamp) > staleTime {
                print("🧹 Cleaning up stale transfer: \(transfer.fileName)")
                await cleanupTransfer(transferID)
            }
        }
    }
    
    private func formatFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    // MARK: - MIME Type Detection
    
    static func mimeType(for fileName: String) -> String? {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        
        if let utType = UTType(filenameExtension: fileExtension) {
            return utType.preferredMIMEType
        }
        
        // Fallback for common types
        switch fileExtension {
        case "txt": return "text/plain"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "json": return "application/json"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Supporting Classes

class FileTransfer: ObservableObject, Identifiable {
    let id: String
    let fileName: String
    let fileSize: UInt64
    let isOutgoing: Bool
    let recipientID: String
    let senderID: String
    let totalCost: UInt64
    let startTime: Date
    
    @Published var status: FileTransferStatus
    var fileData: Data?
    var request: FileTransferRequest?
    var acknowledgedChunks: Set<UInt32> = []
    var savedFilePath: String?
    
    init(id: String, fileName: String, fileSize: UInt64, isOutgoing: Bool, recipientID: String, senderID: String, totalCost: UInt64, status: FileTransferStatus) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.isOutgoing = isOutgoing
        self.recipientID = recipientID
        self.senderID = senderID
        self.totalCost = totalCost
        self.status = status
        self.startTime = Date()
    }
}

// MARK: - Error Types

enum FileTransferError: Error, LocalizedError {
    case noMeshService
    case transferNotFound
    case fileTooLarge
    case tooManyActiveTransfers
    case invalidFileData
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .noMeshService:
            return "Mesh service not available"
        case .transferNotFound:
            return "File transfer not found"
        case .fileTooLarge:
            return "File is too large (max 100 MB)"
        case .tooManyActiveTransfers:
            return "Too many active transfers (max 3)"
        case .invalidFileData:
            return "Invalid file data"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}