//
// WalletView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct WalletView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var walletStats: WalletStatistics?
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    private var cardBackgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.95)
    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Text("Wallet")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            walletContent
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            walletContent
                .navigationTitle("Wallet")
                .navigationBarTitleDisplayMode(.large)
                .navigationBarBackground(color: backgroundColor)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                        .foregroundColor(textColor)
                    }
                }
        }
        #endif
    }
    
    private var walletContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView("Loading wallet...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundColor(textColor)
                } else if let errorMessage = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        
                        Text("Error Loading Wallet")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(textColor)
                        
                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(secondaryTextColor)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Balance Card
                    if let stats = walletStats {
                        balanceCard(stats: stats)
                    }
                    
                    // Stats Cards
                    if let stats = walletStats {
                        statsCards(stats: stats)
                    }
                    
                    // Wallet Info
                    walletInfoCard()
                    
                    // Temporary reset button for testing/cleanup
                    resetDataCard()
                }
            }
            .padding()
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .onAppear {
            loadWalletStats()
        }
        .onReceive(viewModel.$walletUpdateTrigger) { trigger in
            print("🔔 WalletView received wallet update trigger: \(trigger)")
            loadWalletStats()
        }
    }
    
    private func balanceCard(stats: WalletStatistics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wallet.pass")
                    .font(.system(size: 20))
                    .foregroundColor(textColor)
                
                Text("Balance")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                
                Spacer()
            }
            
            HStack(alignment: .bottom, spacing: 4) {
                Text(formatBalance(stats.totalBalance))
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text("RLT")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .offset(y: -4)
            }
            
            Text("\(stats.totalBalance) µRLT")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(secondaryTextColor)
        }
        .padding()
        .background(cardBackgroundColor)
        .cornerRadius(12)
    }
    
    private func statsCards(stats: WalletStatistics) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Statistics")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                Spacer()
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                statCard(
                    title: "Total Transactions",
                    value: "\(stats.transactionCount)",
                    icon: "arrow.left.arrow.right"
                )
                
                statCard(
                    title: "Rewards Earned",
                    value: "\(stats.rewardCount)",
                    icon: "gift"
                )
            }
        }
    }
    
    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(textColor)
                
                Spacer()
            }
            
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(textColor)
            
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(secondaryTextColor)
        }
        .padding()
        .background(cardBackgroundColor)
        .cornerRadius(12)
    }
    
    private func walletInfoCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundColor(textColor)
                
                Text("About RLT")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("• RLT (Relay Token) is earned by participating in the mesh network")
                Text("• 1 RLT = 1,000,000 µRLT (micro RLT)")
                Text("• Rewards are distributed for message relaying and network participation")
                Text("• Your balance updates as you help relay messages across the network")
            }
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(secondaryTextColor)
        }
        .padding()
        .background(cardBackgroundColor)
        .cornerRadius(12)
    }
    
    private func loadWalletStats() {
        print("🔔 WalletView.loadWalletStats() called")
        Task {
            do {
                let stats = try await viewModel.getWalletStatistics()
                await MainActor.run {
                    print("🔔 Loaded wallet stats - Balance: \(stats.totalBalance)µRLT, Transactions: \(stats.transactionCount)")
                    self.walletStats = stats
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    print("❌ Failed to load wallet stats: \(error)")
                    self.errorMessage = "Failed to load wallet data: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func formatBalance(_ microRLT: UInt64) -> String {
        let rlt = Double(microRLT) / Double(WalletManager.microRLTPerRLT)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: rlt)) ?? "0"
    }
    
    private func resetDataCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "trash.circle")
                    .font(.system(size: 16))
                    .foregroundColor(.red)
                
                Text("Reset Data")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.red)
                
                Spacer()
            }
            
            Text("Reset all wallet and transaction data for testing. This will:")
                .font(.caption)
                .foregroundColor(textColor.opacity(0.8))
            
            VStack(alignment: .leading, spacing: 4) {
                Text("• Clear all transaction history")
                Text("• Reset wallet balances")
                Text("• Clear DAG storage")
                Text("• Start fresh with new wallet")
            }
            .font(.caption2)
            .foregroundColor(textColor.opacity(0.7))
            
            Button(action: {
                viewModel.resetCoreSystemData()
            }) {
                HStack {
                    Image(systemName: "trash")
                    Text("Reset All Data")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(cardBackgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}

extension View {
    @ViewBuilder
    func navigationBarBackground(color: Color) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.toolbarBackground(color, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

struct WalletView_Previews: PreviewProvider {
    static var previews: some View {
        WalletView()
            .environmentObject(ChatViewModel())
    }
} 
