//
// FileTransferRequestView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct FileTransferRequestView: View {
    let request: FileTransferRequest
    let viewModel: ChatViewModel
    @Environment(\.presentationMode) var presentationMode
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("File Transfer Request")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                
                // File Details
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("File:")
                                .fontWeight(.medium)
                            Spacer()
                            Text(request.fileName)
                                .foregroundColor(.primary)
                        }
                        
                        HStack {
                            Text("Size:")
                                .fontWeight(.medium)
                            Spacer()
                            Text(formatFileSize(request.fileSize))
                                .foregroundColor(.primary)
                        }
                        
                        if let mimeType = request.mimeType {
                            HStack {
                                Text("Type:")
                                    .fontWeight(.medium)
                                Spacer()
                                Text(mimeType)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        
                        HStack {
                            Text("From:")
                                .fontWeight(.medium)
                            Spacer()
                            Text(senderDisplayName)
                                .foregroundColor(.primary)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Cost:")
                                .fontWeight(.medium)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(request.totalCost)µRLT")
                                    .foregroundColor(.green)
                                    .fontWeight(.semibold)
                                Text("(\(request.costPerMB)µRLT/MB)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("Chunks:")
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(request.totalChunks) chunks")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                
                // Warning/Info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("File Transfer Info")
                                .fontWeight(.medium)
                        }
                        
                        Text("• Files are transferred in encrypted chunks over the mesh network")
                        Text("• Transfer may take several minutes depending on network conditions")
                        Text("• The file will be saved to your Documents/bitchat_files folder")
                        Text("• You can cancel the transfer at any time")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Action Buttons
                HStack(spacing: 16) {
                    Button("Decline") {
                        handleResponse(accept: false)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    
                    Button("Accept") {
                        handleResponse(accept: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .alert("File Transfer", isPresented: $showingAlert) {
            Button("OK") {
                presentationMode.wrappedValue.dismiss()
            }
        } message: {
            Text(alertMessage)
        }
    }
    
    private var senderDisplayName: String {
        if let nickname = viewModel.meshService.getPeerNicknames()[request.senderID] {
            return "\(nickname) (\(request.senderID.prefix(8)))"
        } else {
            return String(request.senderID.prefix(12))
        }
    }
    
    private func formatFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func handleResponse(accept: Bool) {
        print("📱 User \(accept ? "accepted" : "declined") file transfer request for \(request.transferID.prefix(8))")
        
        Task {
            do {
                try await viewModel.fileTransferManager.respondToFileTransfer(
                    transferID: request.transferID,
                    accept: accept,
                    reason: accept ? nil : "User declined"
                )
                
                print("📱 File transfer response sent successfully")
                
                await MainActor.run {
                    alertMessage = accept ? "File transfer accepted" : "File transfer declined"
                    showingAlert = true
                }
            } catch {
                print("📱 Failed to send file transfer response: \(error)")
                await MainActor.run {
                    alertMessage = "Failed to respond: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }
}

#Preview {
    let request = FileTransferRequest(
        fileName: "example.pdf",
        fileSize: 2048576, // ~2MB
        fileData: Data(),
        costPerMB: 50000,
        senderID: "test-peer-id"
    )
    
    FileTransferRequestView(request: request, viewModel: ChatViewModel())
}