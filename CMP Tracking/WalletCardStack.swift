// WalletCardStack.swift
// Simple multi-load card list.
// The active load is shown fully expanded at the top.
// All other loads appear as compact tap-to-expand rows below it.

import SwiftUI

private let CORNER: CGFloat = 18

// MARK: - WalletCardStack

struct WalletCardStack: View {
    @ObservedObject var wallet: LoadWallet
    var onTrack:  (WalletEntry) -> Void
    var onAccept: (WalletEntry) -> Void

    var body: some View {
        let cards   = wallet.cards
        let activeId = wallet.activeId ?? cards.first?.id

        VStack(spacing: 10) {
            ForEach(cards) { entry in
                let isActive = entry.id == activeId
                LoadCard(
                    entry:    entry,
                    isActive: isActive,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            wallet.activate(id: entry.id)
                        }
                    },
                    onTrack:   { onTrack(entry) },
                    onAccept:  { onAccept(entry) },
                    onDismiss: { wallet.remove(id: entry.id) }
                )
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - LoadCard

private struct LoadCard: View {
    let entry:     WalletEntry
    let isActive:  Bool
    let onTap:     () -> Void
    let onTrack:   () -> Void
    let onAccept:  () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isActive {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CORNER)
                .fill(isActive
                      ? Color(red: 0.12, green: 0.12, blue: 0.20)
                      : Color(red: 0.15, green: 0.15, blue: 0.23))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CORNER)
                .stroke(isActive
                        ? Color.white.opacity(0.14)
                        : Color.white.opacity(0.06),
                        lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CORNER))
        .shadow(color: .black.opacity(isActive ? 0.4 : 0.15),
                radius: isActive ? 16 : 4, x: 0, y: isActive ? 6 : 2)
        .onTapGesture { if !isActive { onTap() } }
    }

    // MARK: Collapsed row
    private var collapsedContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.loadNumber)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.white)
                Text(shortRoute)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusPill(entry.status)

            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: Expanded card
    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Company banner
            if !entry.companyName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)
                    Text(entry.companyName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    statusPill(entry.status)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.purple.opacity(0.15))
            }

            // Load number + status (when no company banner)
            HStack {
                Label(entry.loadNumber, systemImage: "shippingbox.fill")
                    .font(.headline).fontWeight(.bold).foregroundColor(.white)
                Spacer()
                if entry.companyName.isEmpty { statusPill(entry.status) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, entry.description.isEmpty ? 10 : 4)

            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.subheadline).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }

            divider
            addrRow("circle.fill",       .green, "PICKUP",   entry.pickupAddress)
            connector
            addrRow("mappin.circle.fill", .red,   "DELIVERY", entry.deliveryAddress)

            if !entry.pickupDate.isEmpty || !entry.deliveryDate.isEmpty || !entry.weight.isEmpty {
                divider
                if !entry.pickupDate.isEmpty   { infoRow("calendar",             .green,  "PICKUP DATE",   entry.pickupDate) }
                if !entry.deliveryDate.isEmpty { infoRow("calendar.badge.clock", .orange, "EST. DELIVERY", entry.deliveryDate) }
                if !entry.weight.isEmpty       { infoRow("scalemass.fill",       .blue,   "WEIGHT",        entry.weight) }
            }

            if !entry.notes.isEmpty {
                divider
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.system(size: 13)).foregroundColor(.yellow.opacity(0.8))
                        .frame(width: 18).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NOTES")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.yellow.opacity(0.7)).kerning(0.8)
                        Text(entry.notes)
                            .font(.subheadline).foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            divider
            actionButton
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
    }

    // MARK: Action button
    @ViewBuilder
    private var actionButton: some View {
        if entry.isComplete {
            HStack {
                Image(systemName: entry.status == "Delivered" ? "checkmark.seal.fill" : "xmark.circle.fill")
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Text(entry.status)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(entry.status == "Delivered" ? .green : .red)
                Spacer()
                Button(action: onDismiss) {
                    Label("Remove", systemImage: "trash")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        } else if entry.status == "Assigned" {
            Button(action: onAccept) {
                Label("Accept Load", systemImage: "checkmark.circle.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onTrack) {
                let inTransit = entry.status == "In Transit"
                Label(
                    inTransit ? "Stop Tracking" : "Start Tracking",
                    systemImage: inTransit ? "pause.fill" : "play.fill"
                )
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(inTransit ? Color.orange : Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Helpers
    private var shortRoute: String {
        let p = entry.pickupAddress.split(separator: ",").first.map(String.init) ?? entry.pickupAddress
        let d = entry.deliveryAddress.split(separator: ",").first.map(String.init) ?? entry.deliveryAddress
        return "\(p) \u{2192} \(d)"
    }

    private var divider: some View {
        Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 16)
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1.5, height: 12)
            .padding(.leading, 34)
    }

    private func addrRow(_ icon: String, _ color: Color, _ label: String, _ val: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color).font(.system(size: 13))
                .frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary).kerning(0.8)
                Text(val)
                    .font(.subheadline).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func infoRow(_ icon: String, _ color: Color, _ label: String, _ val: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13)).foregroundColor(color).frame(width: 18)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary).kerning(0.5)
            Spacer()
            Text(val)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func statusPill(_ status: String) -> some View {
        let c = statusColor(status)
        return Text(status)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(c.opacity(0.2))
            .foregroundColor(c)
            .overlay(Capsule().stroke(c.opacity(0.4), lineWidth: 1))
            .clipShape(Capsule())
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
    w.add(entry: WalletEntry(id:"1",token:"t1",loadNumber:"CMP-001",description:"Electronics",
        pickupAddress:"123 Warehouse Blvd, Chicago, IL",deliveryAddress:"456 Dist Ave, Dallas, TX",
        pickupDate:"Mar 26 at 8:00 AM",deliveryDate:"Mar 27 at 5:00 PM",
        status:"In Transit",companyName:"OTTIO LLC",notes:"Handle with care",weight:"38000 lbs",addedAt:.now))
    w.add(entry: WalletEntry(id:"2",token:"t2",loadNumber:"CMP-002",description:"Auto Parts",
        pickupAddress:"789 Parts St, Detroit, MI",deliveryAddress:"321 Depot Rd, Nashville, TN",
        pickupDate:"Mar 27 at 9:00 AM",deliveryDate:"Mar 28 at 3:00 PM",
        status:"Assigned",companyName:"Acme Freight",notes:"",weight:"22000 lbs",addedAt:.now))
    w.add(entry: WalletEntry(id:"3",token:"t3",loadNumber:"CMP-003",description:"Frozen Foods",
        pickupAddress:"555 Cold Ave, Minneapolis, MN",deliveryAddress:"900 Fresh Blvd, Kansas City, MO",
        pickupDate:"Mar 28 at 7:00 AM",deliveryDate:"Mar 29 at 2:00 PM",
        status:"Accepted",companyName:"FreshMart",notes:"Keep cold",weight:"41000 lbs",addedAt:.now))
    return ZStack {
        Color(red:0.059,green:0.059,blue:0.102).ignoresSafeArea()
        ScrollView {
            WalletCardStack(wallet: w, onTrack:{_ in}, onAccept:{_ in})
                .padding(.top, 20)
        }
    }
}
