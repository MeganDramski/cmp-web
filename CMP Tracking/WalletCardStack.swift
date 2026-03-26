// WalletCardStack.swift
// Apple Wallet-style stacked load cards.
// Active card expands fully; background cards show as tappable collapsed rows below.

import SwiftUI

private let CORNER: CGFloat = 20

// MARK: - WalletCardStack

struct WalletCardStack: View {
    @ObservedObject var wallet: LoadWallet
    var onTrack:  (WalletEntry) -> Void
    var onAccept: (WalletEntry) -> Void

    var body: some View {
        let cards = wallet.cards
        guard !cards.isEmpty else { return AnyView(EmptyView()) }

        let activeId = wallet.activeId ?? cards.first!.id

        // Active card first, rest in order
        let sorted: [WalletEntry] = {
            var r = cards.filter { $0.id == activeId }
            r += cards.filter { $0.id != activeId }
            return r
        }()

        return AnyView(
            VStack(spacing: 8) {
                // Active card — fully expanded
                if let active = sorted.first {
                    WalletCard(
                        entry: active, isActive: true, depth: 0,
                        onTap:     { },
                        onDismiss: { withAnimation(.spring()) { wallet.remove(id: active.id) } },
                        onTrack:   { onTrack(active) },
                        onAccept:  { onAccept(active) }
                    )
                }

                // Background cards — collapsed peek rows, tappable to bring to front
                ForEach(Array(sorted.dropFirst().enumerated()), id: \.element.id) { i, entry in
                    let depth = i + 1
                    WalletCard(
                        entry: entry, isActive: false, depth: depth,
                        onTap:     { withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { wallet.activate(id: entry.id) } },
                        onDismiss: { withAnimation(.spring()) { wallet.remove(id: entry.id) } },
                        onTrack:   { onTrack(entry) },
                        onAccept:  { onAccept(entry) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: activeId)
        )
    }
}

// MARK: - WalletCard

struct WalletCard: View {
    let entry:     WalletEntry
    let isActive:  Bool
    let depth:     Int
    let onTap:     () -> Void
    let onDismiss: () -> Void
    let onTrack:   () -> Void
    let onAccept:  () -> Void

    @State private var dragY: CGFloat = 0
    @State private var hiding = false

    private var bg: Color {
        Color(red: 0.13 + Double(depth)*0.025,
              green: 0.13 + Double(depth)*0.025,
              blue:  0.20 + Double(depth)*0.025)
    }

    var body: some View {
        content
            .offset(y: dragY)
            .opacity(hiding ? 0 : 1)
            .gesture(dismissGesture)
            .onTapGesture { if !isActive { onTap() } }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                if entry.isComplete && v.translation.height < 0 { dragY = v.translation.height }
            }
            .onEnded { v in
                if entry.isComplete && v.translation.height < -60 {
                    withAnimation(.spring()) { hiding = true; dragY = -600 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onDismiss() }
                } else {
                    withAnimation(.spring()) { dragY = 0 }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            // Company banner
            if !entry.companyName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill").font(.system(size: 11)).foregroundColor(.purple)
                    Text(entry.companyName).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    pill(entry.status)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.purple.opacity(0.15))
            }

            if isActive {
                expandedBody
            } else {
                collapsedBody
            }
        }
        .background(RoundedRectangle(cornerRadius: CORNER).fill(bg)
            .shadow(color: .black.opacity(isActive ? 0.45 : 0.2),
                    radius: isActive ? 20 : 6, x: 0, y: isActive ? 8 : 2))
        .overlay(RoundedRectangle(cornerRadius: CORNER)
            .stroke(Color.white.opacity(isActive ? 0.13 : 0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CORNER))
    }

    // MARK: Expanded (active card full detail)
    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Load number
            HStack {
                Label(entry.loadNumber, systemImage: "shippingbox.fill")
                    .font(.headline).fontWeight(.bold).foregroundColor(.white)
                Spacer()
                if entry.companyName.isEmpty { pill(entry.status) }
            }
            .padding(.horizontal, 16).padding(.top, 14)
            .padding(.bottom, entry.description.isEmpty ? 10 : 4)

            if !entry.description.isEmpty {
                Text(entry.description).font(.subheadline).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }

            div
            addrRow("circle.fill",        .green,  "PICKUP",   entry.pickupAddress)
            connector
            addrRow("mappin.circle.fill",  .red,    "DELIVERY", entry.deliveryAddress)

            // Dates + weight
            let hasDates = !entry.pickupDate.isEmpty || !entry.deliveryDate.isEmpty || !entry.weight.isEmpty
            if hasDates {
                div
                if !entry.pickupDate.isEmpty   { infoRow("calendar",             .green,  "PICKUP DATE",   entry.pickupDate) }
                if !entry.deliveryDate.isEmpty { infoRow("calendar.badge.clock", .orange, "EST. DELIVERY", entry.deliveryDate) }
                if !entry.weight.isEmpty       { infoRow("scalemass.fill",       .blue,   "WEIGHT",        entry.weight) }
            }

            // Notes
            if !entry.notes.isEmpty {
                div
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "note.text").font(.system(size: 13)).foregroundColor(.yellow.opacity(0.8))
                        .frame(width: 18).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NOTES").font(.system(size: 10, weight: .bold)).foregroundColor(.yellow.opacity(0.7)).kerning(0.8)
                        Text(entry.notes).font(.subheadline).foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            div
            actionButton.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
        }
    }

    // MARK: Collapsed peek
    @ViewBuilder
    private var collapsedBody: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").foregroundColor(.secondary).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.loadNumber).font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                Text([entry.pickupAddress.split(separator:",").first.map(String.init),
                      entry.deliveryAddress.split(separator:",").first.map(String.init)]
                        .compactMap{$0}.joined(separator:" → "))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if entry.companyName.isEmpty { pill(entry.status) }
            Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .contentShape(Rectangle())
    }

    // MARK: Action button
    @ViewBuilder
    private var actionButton: some View {
        if entry.isComplete {
            HStack {
                Image(systemName: entry.status == "Delivered" ? "checkmark.seal.fill" : "xmark.circle.fill")
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Text(entry.status).font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Spacer()
                Label("Swipe up to remove", systemImage: "arrow.up").font(.caption).foregroundColor(.secondary)
            }
        } else if entry.status == "Assigned" {
            Button(action: onAccept) {
                Label("Accept Load", systemImage: "checkmark.circle.fill")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.purple).foregroundColor(.white).cornerRadius(12)
            }
        } else {
            Button(action: onTrack) {
                let it = entry.status == "In Transit"
                Label(it ? "Stop Tracking" : "Start Tracking", systemImage: it ? "pause.fill" : "play.fill")
                    .fontWeight(.bold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(it ? Color.orange : Color.green).foregroundColor(.white).cornerRadius(12)
            }
        }
    }

    // MARK: Helper views
    private var div: some View {
        Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)
    }
    private var connector: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1.5, height: 12).padding(.leading, 34)
    }
    private func addrRow(_ icon: String, _ color: Color, _ label: String, _ val: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 13)).frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).kerning(0.8)
                Text(val).font(.subheadline).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func infoRow(_ icon: String, _ color: Color, _ label: String, _ val: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(color).frame(width: 18)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).kerning(0.5)
            Spacer()
            Text(val).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func pill(_ status: String) -> some View {
        let c = statusColor(status)
        return Text(status).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(c.opacity(0.2)).foregroundColor(c)
            .overlay(Capsule().stroke(c.opacity(0.4), lineWidth: 1)).clipShape(Capsule())
    }
    private func statusColor(_ s: String) -> Color {
        switch s {
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
    let w = LoadWallet.shared
    w.add(entry: WalletEntry(id:"1",token:"t1",loadNumber:"CMP-001",description:"Electronics",pickupAddress:"123 Warehouse Blvd, Chicago, IL",deliveryAddress:"456 Dist Ave, Dallas, TX",pickupDate:"Mar 26 at 8:00 AM",deliveryDate:"Mar 27 at 5:00 PM",status:"Accepted",companyName:"OTTIO LLC",notes:"Handle with care",weight:"38000 lbs",addedAt:.now))
    w.add(entry: WalletEntry(id:"2",token:"t2",loadNumber:"CMP-002",description:"Auto Parts",pickupAddress:"789 Parts St, Detroit, MI",deliveryAddress:"321 Depot Rd, Nashville, TN",pickupDate:"Mar 27 at 9:00 AM",deliveryDate:"Mar 28 at 3:00 PM",status:"Assigned",companyName:"Acme Freight",notes:"",weight:"22000 lbs",addedAt:.now))
    w.add(entry: WalletEntry(id:"3",token:"t3",loadNumber:"CMP-003",description:"Frozen Foods",pickupAddress:"555 Cold Ave, Minneapolis, MN",deliveryAddress:"900 Fresh Blvd, Kansas City, MO",pickupDate:"Mar 28 at 7:00 AM",deliveryDate:"Mar 29 at 2:00 PM",status:"Assigned",companyName:"FreshMart",notes:"Keep cold",weight:"41000 lbs",addedAt:.now))
    return ZStack {
        Color(red:0.059,green:0.059,blue:0.102).ignoresSafeArea()
        ScrollView { WalletCardStack(wallet: w, onTrack:{_ in}, onAccept:{_ in}).padding(.top, 20) }
    }
}
