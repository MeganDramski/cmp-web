// WalletCardStack.swift
// Apple Wallet–style stacked load cards for drivers with multiple assignments.
// • Cards fan out vertically — each card peeks below the one above it.
// • Tap any peeked card to bring it to the front.
// • Swipe UP on a completed/cancelled card to dismiss it.

import SwiftUI

// MARK: - Constants

private enum WalletLayout {
    static let peekHeight:   CGFloat = 68    // how much of each background card shows
    static let cornerRadius: CGFloat = 20
    static let scaleStep:    CGFloat = 0.025 // each card behind shrinks a little
    static let maxVisible:   Int     = 4
}

// MARK: - WalletCardStack

struct WalletCardStack: View {
    @ObservedObject var wallet: LoadWallet
    var onTrack:  (WalletEntry) -> Void
    var onAccept: (WalletEntry) -> Void

    // Measured height of the active (front) card
    @State private var activeCardHeight: CGFloat = 420

    var body: some View {
        let cards    = wallet.cards
        let activeId = wallet.activeId ?? cards.first?.id

        // Active card first, then remaining in original order
        let sorted: [WalletEntry] = {
            var result = cards.filter { $0.id == activeId }
            result += cards.filter { $0.id != activeId }
            return result
        }()

        VStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { depth, entry in
                let isActive = entry.id == activeId
                let cappedD  = min(depth, WalletLayout.maxVisible - 1)
                let scale    = 1.0 - CGFloat(cappedD) * WalletLayout.scaleStep

                WalletCard(
                    entry:     entry,
                    isActive:  isActive,
                    depth:     cappedD,
                    onTap: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                            wallet.activate(id: entry.id)
                        }
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            wallet.remove(id: entry.id)
                        }
                    },
                    onTrack:  { onTrack(entry)  },
                    onAccept: { onAccept(entry) }
                )
                // Measure active card height so we know how much to overlap
                .background(
                    isActive
                        ? GeometryReader { geo in
                            Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
                          }
                        : nil
                )
                .scaleEffect(x: scale, y: 1.0, anchor: .top)
                // Pull each background card up so only peekHeight is visible below active
                .padding(.top, depth == 0 ? 0 : -(activeCardHeight - WalletLayout.peekHeight))
                .zIndex(Double(sorted.count - depth))
                .opacity(cappedD >= WalletLayout.maxVisible ? 0 : 1)
                .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isActive)
                .animation(.spring(response: 0.4, dampingFraction: 0.78), value: activeCardHeight)
            }
        }
        .onPreferenceChange(CardHeightKey.self) { h in
            if h > 0 { activeCardHeight = h }
        }
        .padding(.horizontal, 16)
    }
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Individual Wallet Card

struct WalletCard: View {
    let entry:     WalletEntry
    let isActive:  Bool
    let depth:     Int
    let onTap:     () -> Void
    let onDismiss: () -> Void
    let onTrack:   () -> Void
    let onAccept:  () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false

    private var cardColor: Color {
        let base = 0.13 + Double(depth) * 0.025
        return Color(red: base, green: base, blue: base + 0.07)
    }

    var body: some View {
        cardContent
            .offset(y: dragOffset)
            .opacity(isDismissing ? 0 : 1)
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { val in
                        if entry.isComplete && val.translation.height < 0 {
                            dragOffset = val.translation.height
                        }
                    }
                    .onEnded { val in
                        if entry.isComplete && val.translation.height < -60 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                isDismissing = true
                                dragOffset   = -600
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onDismiss() }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                        }
                    }
            )
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(spacing: 0) {

            // ── Company banner ─────────────────────────────────────────────
            if !entry.companyName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 11)).foregroundColor(.purple)
                    Text(entry.companyName)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    statusPill(entry.status)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.purple.opacity(0.15))
            }

            if isActive {
                // ── Full expanded content ──────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {

                    // Load number row
                    HStack {
                        Label(entry.loadNumber, systemImage: "shippingbox.fill")
                            .font(.headline).fontWeight(.bold).foregroundColor(.white)
                        Spacer()
                        if entry.companyName.isEmpty { statusPill(entry.status) }
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    .padding(.bottom, entry.description.isEmpty ? 10 : 4)

                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(.subheadline).foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.bottom, 10)
                    }

                    Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)

                    // Route rows
                    routeRow(icon: "circle.fill",        color: .green, label: "PICKUP",   address: entry.pickupAddress)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1.5, height: 12).padding(.leading, 34)
                    routeRow(icon: "mappin.circle.fill", color: .red,   label: "DELIVERY", address: entry.deliveryAddress)

                    // Dates + weight
                    let hasDetails = !entry.pickupDate.isEmpty || !entry.deliveryDate.isEmpty || !entry.weight.isEmpty
                    if hasDetails {
                        Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)
                        if !entry.pickupDate.isEmpty {
                            detailRow(icon: "calendar",             color: .green,  label: "PICKUP DATE",   value: entry.pickupDate)
                        }
                        if !entry.deliveryDate.isEmpty {
                            detailRow(icon: "calendar.badge.clock", color: .orange, label: "EST. DELIVERY", value: entry.deliveryDate)
                        }
                        if !entry.weight.isEmpty {
                            detailRow(icon: "scalemass.fill",       color: .blue,   label: "WEIGHT",        value: entry.weight)
                        }
                    }

                    // Notes
                    if !entry.notes.isEmpty {
                        Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "note.text")
                                .font(.system(size: 13)).foregroundColor(.yellow.opacity(0.8))
                                .frame(width: 18).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("NOTES").font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.yellow.opacity(0.7)).kerning(0.8)
                                Text(entry.notes).font(.subheadline).foregroundColor(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }

                    Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)

                    // Action button
                    actionRow
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
                }

            } else {
                // ── Collapsed peek ─────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundColor(.secondary).font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.loadNumber)
                            .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                        Text(
                            [entry.pickupAddress.split(separator: ",").first.map(String.init),
                             entry.deliveryAddress.split(separator: ",").first.map(String.init)]
                                .compactMap { $0 }.joined(separator: " → ")
                        )
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if entry.companyName.isEmpty { statusPill(entry.status) }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 18)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: WalletLayout.cornerRadius)
                .fill(cardColor)
                .shadow(color: .black.opacity(isActive ? 0.45 : 0.25),
                        radius: isActive ? 20 : 8, x: 0, y: isActive ? 8 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WalletLayout.cornerRadius)
                .stroke(Color.white.opacity(isActive ? 0.13 : 0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: WalletLayout.cornerRadius))
        .onTapGesture { if !isActive { onTap() } }
    }

    // MARK: - Rows

    @ViewBuilder private var actionRow: some View {
        if entry.isComplete {
            HStack {
                Image(systemName: entry.status == "Delivered" ? "checkmark.seal.fill" : "xmark.circle.fill")
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Text(entry.status).font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Spacer()
                Label("Swipe up to remove", systemImage: "arrow.up")
                    .font(.caption).foregroundColor(.secondary)
            }
        } else if entry.status == "Assigned" {
            Button(action: onAccept) {
                Label("Accept Load", systemImage: "checkmark.circle.fill")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.purple).foregroundColor(.white).cornerRadius(12)
            }
        } else {
            Button(action: onTrack) {
                let isIT = entry.status == "In Transit"
                Label(isIT ? "Stop Tracking" : "Start Tracking",
                      systemImage: isIT ? "pause.fill" : "play.fill")
                    .fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(isIT ? Color.orange : Color.green)
                    .foregroundColor(.white).cornerRadius(12)
            }
        }
    }

    private func routeRow(icon: String, color: Color, label: String, address: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 13))
                .frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary).kerning(0.8)
                Text(address).font(.subheadline).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func detailRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(color).frame(width: 18)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).kerning(0.5)
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

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
    wallet.add(entry: WalletEntry(
        id: "p1", token: "t1", loadNumber: "CMP-0001",
        description: "Electronics – 48 pallets",
        pickupAddress: "123 Warehouse Blvd, Chicago, IL",
        deliveryAddress: "456 Distribution Ave, Dallas, TX",
        pickupDate: "Mar 26 at 8:00 AM", deliveryDate: "Mar 27 at 5:00 PM",
        status: "In Transit", companyName: "OTTIO LLC", notes: "Handle with care",
        weight: "38000 lbs", addedAt: Date()
    ))
    wallet.add(entry: WalletEntry(
        id: "p2", token: "t2", loadNumber: "CMP-0002",
        description: "Auto Parts",
        pickupAddress: "789 Parts St, Detroit, MI",
        deliveryAddress: "321 Depot Rd, Nashville, TN",
        pickupDate: "Mar 27 at 9:00 AM", deliveryDate: "Mar 28 at 3:00 PM",
        status: "Assigned", companyName: "Acme Freight", notes: "",
        weight: "22000 lbs", addedAt: Date()
    ))
    wallet.add(entry: WalletEntry(
        id: "p3", token: "t3", loadNumber: "CMP-0003",
        description: "Frozen Foods",
        pickupAddress: "555 Cold Ave, Minneapolis, MN",
        deliveryAddress: "900 Fresh Blvd, Kansas City, MO",
        pickupDate: "Mar 28 at 7:00 AM", deliveryDate: "Mar 29 at 2:00 PM",
        status: "Assigned", companyName: "FreshMart", notes: "Keep cold",
        weight: "41000 lbs", addedAt: Date()
    ))

    return ZStack {
        Color(red: 0.059, green: 0.059, blue: 0.102).ignoresSafeArea()
        ScrollView {
            VStack(spacing: 20) {
                WalletCardStack(wallet: wallet, onTrack: { _ in }, onAccept: { _ in })
                    .padding(.top, 20)
            }
        }
    }
}
