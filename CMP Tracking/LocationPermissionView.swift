//
//  LocationPermissionView.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//
//  Shown BEFORE the iOS system permission dialog.
//  Explains WHY "Always Allow" is needed so the driver picks the right option.
//

import SwiftUI
import CoreLocation

struct LocationPermissionView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // ── Icon ─────────────────────────────────────────────────────────
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: "location.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
            }
            .padding(.bottom, 28)

            // ── Title ─────────────────────────────────────────────────────────
            Text("Allow Location\nAccess")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            // ── Explanation ───────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    color: .blue,
                    title: "Real-time tracking",
                    detail: "Your GPS is sent to dispatch every 5 seconds during your trip."
                )
                PermissionRow(
                    icon: "iphone.slash",
                    color: .orange,
                    title: "Works when screen is off",
                    detail: "Location continues in the background so you don't need to keep the app open."
                )
                PermissionRow(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "Private & secure",
                    detail: "Location is only shared while you are actively on a trip."
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)

            // ── Critical instruction ──────────────────────────────────────────
            VStack(spacing: 8) {
                Text("On the next screen, tap:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                    Text("\"Always Allow\"")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                }

                Text("Not \"Allow Once\" or \"Allow While Using App\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(Color.green.opacity(0.08))
            .cornerRadius(16)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)

            // ── Continue Button ───────────────────────────────────────────────
            Button(action: onContinue) {
                HStack {
                    Text("Continue")
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // ── Settings shortcut if already denied ───────────────────────────
            Button(action: openSettings) {
                Text("Already denied? Open Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .underline()
            }
            .padding(.bottom, 32)

            Spacer()
        }
        .navigationBarHidden(true)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    LocationPermissionView(onContinue: {})
}
