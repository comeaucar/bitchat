//
// FileTransferView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import ObjectiveC
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
// Helper class for dismiss action
private class DismissHelper: NSObject {
    weak var navController: UINavigationController?
    
    init(navController: UINavigationController) {
        self.navController = navController
    }
    
    @objc func dismiss() {
        navController?.dismiss(animated: true)
    }
}
#endif

struct FileTransferView: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var selectedPeerID: String = ""
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("File Transfer")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Send files securely over the mesh network")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    // Cost info
                    HStack {
                        Image(systemName: "dollarsign.circle")
                            .foregroundColor(.green)
                        Text("50,000µRLT per MB")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Max: 100 MB")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                
                // Send File Section
                GroupBox("Send File") {
                    VStack(spacing: 12) {
                        // Peer Selection
                        HStack {
                            Text("To:")
                                .fontWeight(.medium)
                            
                            Picker("Select Peer", selection: $selectedPeerID) {
                                Text("Select peer...").tag("")
                                ForEach(Array(viewModel.connectedPeers), id: \.self) { peerID in
                                    if let nickname = viewModel.meshService.getPeerNicknames()[peerID] {
                                        Text("\(nickname) (\(peerID.prefix(8)))")
                                            .tag(peerID)
                                    } else {
                                        Text(peerID)
                                            .tag(peerID)
                                    }
                                }
                            }
                            .disabled(viewModel.connectedPeers.isEmpty)
                        }
                        
                        // File Picker Button
                        Button(action: {
                            showingFilePicker = true
                        }) {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                Text("Choose File")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedPeerID.isEmpty ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(selectedPeerID.isEmpty)
                        
                        if viewModel.connectedPeers.isEmpty {
                            Text("No connected peers")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding()
                }
                .padding(.horizontal)
                
                // Active Transfers
                if !viewModel.fileTransferManager.activeTransfers.isEmpty {
                    GroupBox("Active Transfers") {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(viewModel.fileTransferManager.activeTransfers.values), id: \.id) { transfer in
                                FileTransferRowView(transfer: transfer, viewModel: viewModel)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal)
                }
                
                // Transfer History
                if !viewModel.fileTransferManager.transferHistory.isEmpty {
                    GroupBox("Recent Transfers") {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.fileTransferManager.transferHistory.suffix(5).reversed(), id: \.id) { transfer in
                                FileTransferRowView(transfer: transfer, viewModel: viewModel)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .navigationTitle("File Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Auto-select current chat recipient
            if let privatePeer = viewModel.selectedPrivateChatPeer {
                selectedPeerID = privatePeer
            } else if viewModel.currentChannel != nil {
                // For channels, we'll need to pick a specific peer
                // For now, show all connected peers
                selectedPeerID = ""
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.data, .image, .movie, .audio, .text, .pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .alert("File Transfer", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        print("📎 *** FileTransferView.handleFileSelection called ***")
        switch result {
        case .success(let urls):
            print("📎 FileTransferView: File selection successful, URLs: \(urls)")
            guard let url = urls.first else { 
                print("📎 FileTransferView: ❌ No URL in selection")
                return 
            }
            print("📎 FileTransferView: Selected file URL: \(url)")
            
            // Start accessing security scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            
            Task {
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                do {
                    print("📎 FileTransferView: Attempting to read file: \(url.path)")
                    
                    // Read file data first to ensure we have access
                    let fileData = try Data(contentsOf: url)
                    let fileName = url.lastPathComponent
                    let fileSize = UInt64(fileData.count)
                    
                    print("📎 FileTransferView: Successfully read file: \(fileName), size: \(fileSize) bytes")
                    
                    // Create a temporary file in the app's documents directory
                    let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let tempDir = documentsPath.appendingPathComponent("temp_uploads")
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    // Create a unique filename to avoid conflicts
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let uniqueFileName = "\(timestamp)_\(fileName)"
                    let tempFileURL = tempDir.appendingPathComponent(uniqueFileName)
                    
                    // Write file with proper attributes
                    try fileData.write(to: tempFileURL, options: [.atomic])
                    
                    // Set proper file permissions
                    try FileManager.default.setAttributes([
                        .posixPermissions: 0o644
                    ], ofItemAtPath: tempFileURL.path)
                    
                    print("📎 FileTransferView: Created temp file at: \(tempFileURL.path) with \(fileData.count) bytes")
                    
                    // Now initiate transfer with the file data directly
                    let transferID = try await viewModel.fileTransferManager.initiateFileTransfer(
                        filePath: tempFileURL.path,
                        recipientID: selectedPeerID,
                        fileData: fileData
                    )
                    
                    await MainActor.run {
                        showAlert("File transfer started: \(fileName) → \(transferID.prefix(8))")
                    }
                    
                    // Clean up temp file after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 300) { // 5 minutes
                        try? FileManager.default.removeItem(at: tempFileURL)
                    }
                    
                } catch {
                    print("📎 FileTransferView: File transfer error: \(error)")
                    await MainActor.run {
                        let errorMessage = (error as? FileTransferError)?.localizedDescription ?? error.localizedDescription
                        showAlert("Failed to start transfer: \(errorMessage)")
                    }
                }
            }
            
        case .failure(let error):
            showAlert("File selection failed: \(error.localizedDescription)")
        }
    }
    
    private func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }
}

struct FileTransferRowView: View {
    @ObservedObject var transfer: FileTransfer
    let viewModel: ChatViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // File icon
                Image(systemName: fileIcon(for: transfer.fileName))
                    .foregroundColor(statusColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack {
                        Text(formatFileSize(transfer.fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text("\(transfer.totalCost)µRLT")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                Spacer()
                
                // Direction indicator
                Image(systemName: transfer.isOutgoing ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundColor(transfer.isOutgoing ? .blue : .green)
            }
            
            // Status
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.status.displayText)
                        .font(.caption)
                        .foregroundColor(statusColor)
                    
                    // Additional debug info for development
                    if case .transferring(let complete, let total) = transfer.status {
                        Text("Debug: \(complete)/\(total)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Show transfer ID for debugging
                    Text("ID: \(transfer.id.prefix(8))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Progress bar for transferring status
                if case .transferring(let complete, let total) = transfer.status {
                    VStack(spacing: 2) {
                        ProgressView(value: Double(complete), total: Double(total))
                            .frame(width: 60)
                            .scaleEffect(0.8)
                        
                        // Show percentage
                        if total > 0 {
                            Text("\(Int((Double(complete) / Double(total)) * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Cancel button for active transfers
                if case .transferring = transfer.status {
                    Button("Cancel") {
                        Task {
                            try? await viewModel.fileTransferManager.cancelFileTransfer(
                                transferID: transfer.id,
                                reason: "User cancelled"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
                
                // View/Download button for completed transfers
                if case .completed = transfer.status, !transfer.isOutgoing, let savedPath = transfer.savedFilePath {
                    HStack(spacing: 4) {
                        Button("View") {
                            openFile(at: savedPath)
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        
                        if canPreviewFile(transfer.fileName) {
                            Button("Preview") {
                                previewFile(at: savedPath, fileName: transfer.fileName)
                            }
                            .font(.caption)
                            .foregroundColor(.green)
                        }
                    }
                }
            }
            
            // Peer info
            Text(transfer.isOutgoing ? "To: \(peerDisplayName(transfer.recipientID))" : "From: \(peerDisplayName(transfer.senderID))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch transfer.status {
        case .requesting, .accepted, .transferring:
            return .blue
        case .completed:
            return .green
        case .rejected, .failed, .cancelled:
            return .red
        }
    }
    
    private func fileIcon(for fileName: String) -> String {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        
        switch fileExtension {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "video"
        case "mp3", "wav", "aac", "flac":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "txt", "md":
            return "doc.text"
        case "zip", "rar", "7z":
            return "archivebox"
        case "doc", "docx":
            return "doc"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        default:
            return "doc"
        }
    }
    
    private func formatFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func peerDisplayName(_ peerID: String) -> String {
        if let nickname = viewModel.meshService.getPeerNicknames()[peerID] {
            return "\(nickname) (\(peerID.prefix(8)))"
        } else {
            return String(peerID.prefix(12))
        }
    }
    
    private func openFile(at path: String) {
        let fileURL = URL(fileURLWithPath: path)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌ File not found at path: \(path)")
            return
        }
        
        #if os(iOS)
        // On iOS, use UIDocumentInteractionController for file interaction
        let documentController = UIDocumentInteractionController(url: fileURL)
        
        // Present options to view or share the file
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            // Find the topmost view controller
            var topViewController = rootViewController
            while let presentedViewController = topViewController.presentedViewController {
                topViewController = presentedViewController
            }
            
            // Present the document interaction controller
            documentController.presentOptionsMenu(from: CGRect(x: 0, y: 0, width: 100, height: 100), in: topViewController.view, animated: true)
        }
        #elseif os(macOS)
        // On macOS, use NSWorkspace to open the file
        NSWorkspace.shared.open(fileURL)
        #endif
    }
    
    private func canPreviewFile(_ fileName: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        
        // Support common previewable file types
        let previewableExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "pdf", "txt", "md", "json", "xml"]
        return previewableExtensions.contains(fileExtension)
    }
    
    private func previewFile(at path: String, fileName: String) {
        let fileURL = URL(fileURLWithPath: path)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌ File not found at path: \(path)")
            return
        }
        
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        
        #if os(iOS)
        if ["jpg", "jpeg", "png", "gif", "bmp", "tiff"].contains(fileExtension) {
            // Preview image files
            if let image = UIImage(contentsOfFile: path) {
                previewImage(image, fileName: fileName)
            }
        } else if ["txt", "md", "json", "xml"].contains(fileExtension) {
            // Preview text files
            if let content = try? String(contentsOf: fileURL) {
                previewText(content, fileName: fileName)
            }
        } else {
            // Fallback to opening the file
            openFile(at: path)
        }
        #elseif os(macOS)
        // On macOS, use Quick Look or NSWorkspace
        NSWorkspace.shared.open(fileURL)
        #endif
    }
    
    #if os(iOS)
    private func previewImage(_ image: UIImage, fileName: String) {
        // Create a simple image preview
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .systemBackground
        
        let viewController = UIViewController()
        viewController.view = imageView
        viewController.title = fileName
        
        let navController = UINavigationController(rootViewController: viewController)
        
        // Create a helper class for the dismiss action
        let dismissHelper = DismissHelper(navController: navController)
        navController.navigationBar.topItem?.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: dismissHelper,
            action: #selector(DismissHelper.dismiss)
        )
        
        // Keep a reference to prevent deallocation
        objc_setAssociatedObject(navController, "dismissHelper", dismissHelper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            var topViewController = rootViewController
            while let presentedViewController = topViewController.presentedViewController {
                topViewController = presentedViewController
            }
            
            topViewController.present(navController, animated: true)
        }
    }
    
    private func previewText(_ content: String, fileName: String) {
        let textView = UITextView()
        textView.text = content
        textView.isEditable = false
        textView.font = UIFont.systemFont(ofSize: 14)
        textView.backgroundColor = .systemBackground
        
        let viewController = UIViewController()
        viewController.view = textView
        viewController.title = fileName
        
        let navController = UINavigationController(rootViewController: viewController)
        
        // Create a helper class for the dismiss action
        let dismissHelper = DismissHelper(navController: navController)
        navController.navigationBar.topItem?.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: dismissHelper,
            action: #selector(DismissHelper.dismiss)
        )
        
        // Keep a reference to prevent deallocation
        objc_setAssociatedObject(navController, "dismissHelper", dismissHelper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            var topViewController = rootViewController
            while let presentedViewController = topViewController.presentedViewController {
                topViewController = presentedViewController
            }
            
            topViewController.present(navController, animated: true)
        }
    }
    #endif
}

#Preview {
    FileTransferView(viewModel: ChatViewModel())
}