// WalletCardStack.swift
// Apple Wallet–style stacked load cards for drivers with multiple assignments.
// • Cards fan out vertically — each card peeks below the one above it.
// • Tap any card to bring it to the front (active).
// • Swipe UP on a completed/cancelled card to dismiss it.

import SwiftUI

// MARK: - Constants

private enum WalletLayout {
    static let cardHeight: CGFloat   = 190
    static let peekHeight: CGFloat   = 56   // how much of each card shows below the active one
    static let maxFanCards: Int      = 4    // beyond this many we clip the fan
    static let cornerRadius: CGFloat = 20
    static let scaleStep: CGFloat    = 0.03 // each card behind is scaled down a little
    static let offsetStep: CGFloat   = 14   // px shift per depth level
}

// MARK: - WalletCardStack

struct WalletCardStack: View {
    @ObservedObject var wallet: LoadWallet

    /// Called when the driver taps Start/Stop Tracking on the active card
    var onTrack: (WalletEntry) -> Void
    /// Called when the driver taps Accept on the active card
    var onAccept: (WalletEntry) -> Void

    var body: some View {
        let cards = wallet.cards
        return ZStack(alignment: .top) {
            if cards.isEmpty {
                EmptyView()
            } else {
                ForEach(Array(cards.enumerated().reversed()), id: \.element.id) { index, entry in
                    WalletCard(
                        entry: entry,
                        isActive: wallet.activeId == entry.id || (wallet.activeId == nil && index == 0),
                        depth: depthIndex(for: entry.id, in: cards),
                        totalCards: min(cards.count, WalletLayout.maxFanCards),
                        onTap: {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                                wallet.activate(id: entry.id)
                            }
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                wallet.remove(id: entry.id)
                            }
                        },
                        onTrack: { onTrack(entry) },
                        onAccept: { onAccept(entry) }
                    )
                    .zIndex(zIndex(for: entry.id, in: cards))
                }
            }
        }
        .frame(minHeight: stackHeight(cardCount: cards.count))
        .padding(.horizontal, 16)
    }

    // MARK: - Layout Helpers

    private func depthIndex(for id: String, in cards: [WalletEntry]) -> Int {
        guard let activeId = wallet.activeId ?? cards.first?.id,
              let activeIdx = cards.firstIndex(where: { $0.id == activeId }),
              let idx = cards.firstIndex(where: { $0.id == id }) else { return 0 }
        if id == activeId { return 0 }
        return idx > activeIdx ? (idx - activeIdx) : (activeIdx - idx)
    }

    private func zIndex(for id: String, in cards: [WalletEntry]) -> Double {
        if id == (wallet.activeId ?? cards.first?.id) { return Double(cards.count) }
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return 0 }
        return Double(cards.count - idx)
    }

    private func stackHeight(cardCount: Int) -> CGFloat {
        let fan = min(cardCount, WalletLayout.maxFanCards)
        return WalletLayout.cardHeight + CGFloat(fan - 1) * WalletLayout.peekHeight + 20
    }
}

// MARK: - Individual Wallet Card

struct WalletCard: View {
    let entry: WalletEntry
    let isActive: Bool
    let depth: Int          // 0 = front
    let totalCards: Int
    let onTap: () -> Void
    let onDismiss: () -> Void
    let onTrack: () -> Void
    let onAccept: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false

    private var cappedDepth: Int { min(depth, WalletLayout.maxFanCards - 1) }

    // Vertical offset — active card is at top, others peek below
    private var yOffset: CGFloat {
        isActive ? 0 : CGFloat(cappedDepth) * WalletLayout.peekHeight
    }

    private var scale: CGFloat {
        isActive ? 1.0 : max(1.0 - CGFloat(cappedDepth) * WalletLayout.scaleStep, 0.88)
    }

    private var cardColor: Color {
        // Each depth level gets a slightly lighter tint
        let base = 0.110 + Double(cappedDepth) * 0.02
        return Color(red: base, green: base, blue: base + 0.07)
    }

    var body: some View {
        cardContent
            .offset(y: yOffset + dragOffset)
            .scaleEffect(x: scale, y: scale, anchor: .top)
            .opacity(isDismissing ? 0 : (cappedDepth >= WalletLayout.maxFanCards ? 0 : 1))
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isActive)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: depth)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { val in
                        // Only allow upward swipe to dismiss completed cards
                        if entry.isComplete && val.translation.height < 0 {
                            dragOffset = val.translation.height
                        }
                    }
                    .onEnded { val in
                        if entry.isComplete && val.translation.height < -60 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                isDismissing = true
                                dragOffset = -500
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                onDismiss()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(spacing: 0) {

            // ── Company / dispatcher banner ────────────────────────────────
            if !entry.companyName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)
                    Text(entry.companyName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    // Status badge
                    statusPill(entry.status)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.purple.opacity(0.14))
            }

            // ── Main content (only fully visible on active card) ───────────
            if isActive {
                VStack(alignment: .leading, spacing: 0) {

                    // Load # + status (when no company banner)
                    if entry.companyName.isEmpty {
                        HStack {
                            Label(entry.loadNumber, systemImage: "shippingbox.fill")
                                .font(.headline).fontWeight(.bold).foregroundColor(.white)
                            Spacer()
                            statusPill(entry.status)
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                    } else {
                        HStack {
                            Label(entry.loadNumber, systemImage: "shippingbox.fill")
                                .font(.headline).fontWeight(.bold).foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                    }

                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(.subheadline).foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                    }

                    Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)

                    // Route
                    VStack(spacing: 0) {
                        routeRow(icon: "circle.fill", color: .green,
                                 label: "PICKUP", address: entry.pickupAddress)
                        Rectangle().fill(Color.white.opacity(0.08))
                            .frame(width: 1, height: 12).padding(.leading, 28)
                        routeRow(icon: "mappin.circle.fill", color: .red,
                                 label: "DELIVERY", address: entry.deliveryAddress)
                    }
                    .padding(.vertical, 6)

                    Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)

                    // Action buttons
                    actionButtons
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 14)
                }
            } else {
                // Collapsed peek — just show load number + route summary
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundColor(.secondary).font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.loadNumber)
                            .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                        Text("\(entry.pickupAddress.split(separator: ",").first ?? "") → \(entry.deliveryAddress.split(separator: ",").first ?? "")")
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if entry.companyName.isEmpty {
                        statusPill(entry.status)
                    }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: WalletLayout.cornerRadius)
                .fill(cardColor)
                .overlay(
                    RoundedRectangle(cornerRadius: WalletLayout.cornerRadius)
                        .stroke(
                            isActive
                                ? Color.white.opacity(0.12)
                                : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(isActive ? 0.35 : 0.15),
                        radius: isActive ? 16 : 6, x: 0, y: isActive ? 6 : 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: WalletLayout.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: WalletLayout.cornerRadius))
        .onTapGesture {
            if !isActive { onTap() }
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if entry.isComplete {
            // Completed — show swipe-to-dismiss hint
            HStack(spacing: 8) {
                Image(systemName: entry.status == "Delivered" ? "checkmark.seal.fill" : "xmark.circle.fill")
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Text(entry.status == "Delivered" ? "Delivered" : "Cancelled")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Swipe up to remove")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        } else if entry.status == "Assigned" {
            Button(action: onAccept) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Accept Load")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.purple)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        } else if entry.status == "Accepted" || entry.status == "In Transit" {
            Button(action: onTrack) {
                HStack(spacing: 8) {
                    Image(systemName: entry.status == "In Transit" ? "pause.fill" : "play.fill")
                    Text(entry.status == "In Transit" ? "Stop Tracking" : "Start Tracking")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(entry.status == "In Transit" ? Color.orange : Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func routeRow(icon: String, color: Color, label: String, address: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 12))
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary).kerning(0.8)
                Text(address)
                    .font(.subheadline).foregroundColor(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusPill(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(statusColor(status).opacity(0.2))
            .foregroundColor(statusColor(status))
            .overlay(Capsule().stroke(statusColor(status).opacity(0.4), lineWidth: 1))
            .clipShape(Capsule())
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Assigned":   return .blue
        case "Accepted":   return .purple
        case "In Transit": return .orange
        case "Delivered":  return .green
        case "Cancelled":  return .red
        default:           return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    let wallet = LoadWallet.shared
    // Add sample entries
    wallet.add(entry: WalletEntry(
        id: "1", token: "tok1", loadNumber: "CMP-0001",
        description: "Electronics – 48 pallets", pickupAddress: "123 Warehouse Blvd, Chicago, IL",
        deliveryAddress: "456 Distribution Ave, Dallas, TX",
        pickupDate: "Mar 26 at 8:00 AM", deliveryDate: "Mar 27 at 5:00 PM",
        status: "In Transit", companyName: "OTTIO LLC", notes: "", weight: "38000 lbs",
        addedAt: Date()
    ))
    wallet.add(entry: WalletEntry(
        id: "2", token: "tok2", loadNumber: "CMP-0002",
        description: "Auto Parts – 20 pallets", pickupAddress: "789 Parts St, Detroit, MI",
        deliveryAddress: "321 Depot Rd, Nashville, TN",
        pickupDate: "Mar 27 at 9:00 AM", deliveryDate: "Mar 28 at 3:00 PM",
        status: "Assigned", companyName: "Acme Freight", notes: "", weight: "22000 lbs",
        addedAt: Date()
    ))

    return ZStack {
        Color(red: 0.059, green: 0.059, blue: 0.102).ignoresSafeArea()
        ScrollView {
            WalletCardStack(
                wallet: wallet,
                onTrack: { _ in },
                onAccept: { _ in }
            )
            .padding(.top, 20)
        }
    }
}
