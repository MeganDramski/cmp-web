import SwiftUI

// MARK: - Routelo Logo (Option E — GPS Signal Ring)
struct RouteloLogo: View {
    var showWordmark: Bool = true
    var size: CGFloat = 120

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.14) {
            RouteloSignalIcon(size: size)
            if showWordmark {
                RouteloWordmark(size: size)
            }
        }
    }
}

// MARK: - GPS Signal Ring Icon
struct RouteloSignalIcon: View {
    var size: CGFloat = 120

    private var iconSize: CGFloat { size * 0.62 }
    private var center: CGFloat   { iconSize / 2 }

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .strokeBorder(Color.RouteloRingPurple, lineWidth: size * 0.018)
                .opacity(0.25)
                .frame(width: iconSize, height: iconSize)

            // Mid ring
            Circle()
                .strokeBorder(Color.RouteloRingPurple, lineWidth: size * 0.018)
                .opacity(0.45)
                .frame(width: iconSize * 0.76, height: iconSize * 0.76)

            // Inner ring
            Circle()
                .strokeBorder(Color.RouteloRingPurple, lineWidth: size * 0.022)
                .opacity(0.7)
                .frame(width: iconSize * 0.52, height: iconSize * 0.52)

            // Filled center dot
            Circle()
                .fill(Color.RouteloPurple)
                .frame(width: iconSize * 0.24, height: iconSize * 0.24)

            // White inner dot
            Circle()
                .fill(Color.white)
                .frame(width: iconSize * 0.10, height: iconSize * 0.10)
        }
        .frame(width: iconSize, height: iconSize)
    }
}

// MARK: - Wordmark
struct RouteloWordmark: View {
    var size: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.025) {
            Text("Routelo")
                .font(.system(size: size * 0.26, weight: .semibold, design: .default))
                .foregroundColor(.primary)
                .kerning(-0.5)

            Text("LIVE TRACKING")
                .font(.system(size: size * 0.09, weight: .regular, design: .default))
                .foregroundColor(.secondary)
                .kerning(2.2)
        }
    }
}

// MARK: - Animated Variant (pulsing rings)
struct RouteloAnimatedIcon: View {
    var size: CGFloat = 120
    @State private var pulse = false

    private var iconSize: CGFloat { size * 0.62 }

    var body: some View {
        ZStack {
            // Animated outer pulse
            Circle()
                .strokeBorder(Color.RouteloRingPurple, lineWidth: size * 0.015)
                .opacity(pulse ? 0.0 : 0.3)
                .scaleEffect(pulse ? 1.2 : 1.0)
                .frame(width: iconSize, height: iconSize)
                .animation(
                    .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                    value: pulse
                )

            // Static rings
            RouteloSignalIcon(size: size)
        }
        .frame(width: iconSize * 1.2, height: iconSize * 1.2)
        .onAppear { pulse = true }
    }
}

// MARK: - Color Extension
extension Color {
    static let RouteloPurple     = Color(red: 0.325, green: 0.290, blue: 0.718) // #534AB7
    static let RouteloRingPurple = Color(red: 0.498, green: 0.467, blue: 0.867) // #7F77DD
}

// MARK: - Preview
#Preview {
    VStack(spacing: 36) {

        // Full logo — default
        RouteloLogo(size: 120)

        // Full logo — medium
        RouteloLogo(size: 80)

        // Icon only
        RouteloLogo(showWordmark: false, size: 90)

        // Animated pulsing icon
        RouteloAnimatedIcon(size: 100)

        // On card background
        RouteloLogo(size: 90)
            .padding(24)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 4)

        // Dark background
        RouteloLogo(size: 90)
            .padding(24)
            .background(Color(red: 0.1, green: 0.08, blue: 0.18))
            .cornerRadius(20)
    }
    .padding(32)
}
