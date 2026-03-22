import SwiftUI

// MARK: - CMP Logistics Logo (Option D — Minimal Lettermark)
struct ParceloLogoD: View {
    var showWordmark: Bool = true
    var size: CGFloat = 120

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.14) {
            ParceloLettermark(size: size)
            if showWordmark {
                ParceloWordmarkD(size: size)
            }
        }
    }
}

// MARK: - Lettermark Icon (Rounded Square + P + Accent Dot)
struct ParceloLettermark: View {
    var size: CGFloat = 120

    private var boxSize: CGFloat   { size * 0.58 }
    private var cornerR: CGFloat   { boxSize * 0.24 }
    private var dotSize: CGFloat   { boxSize * 0.18 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Rounded square background
            RoundedRectangle(cornerRadius: cornerR)
                .fill(Color.parceloPurple)
                .frame(width: boxSize, height: boxSize)

            // Bold "C" letter
            Text("C")
                .font(.system(size: boxSize * 0.58, weight: .bold, design: .default))
                .foregroundColor(.white)
                .frame(width: boxSize, height: boxSize)

            // Accent dot (top-right corner)
            Circle()
                .fill(Color.parceloPurpleLight)
                .frame(width: dotSize, height: dotSize)
                .offset(x: dotSize * 0.1, y: -(dotSize * 0.1))
        }
        .frame(width: boxSize + dotSize * 0.5, height: boxSize + dotSize * 0.5)
    }
}

// MARK: - Wordmark
struct ParceloWordmarkD: View {
    var size: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.025) {
            Text("CMP Logistics")
                .font(.system(size: size * 0.26, weight: .semibold, design: .default))
                .foregroundColor(.primary)
                .kerning(-0.5)

            Text("FREIGHT MANAGEMENT")
                .font(.system(size: size * 0.083, weight: .regular, design: .default))
                .foregroundColor(.secondary)
                .kerning(1.8)
        }
    }
}

// MARK: - Color Extension
extension Color {
    static let parceloPurple      = Color(red: 0.325, green: 0.231, blue: 0.718) // #533AB7
    static let parceloPurpleLight = Color(red: 0.686, green: 0.663, blue: 0.925) // #AFA9EC
}

// MARK: - App Icon Variant (icon only, no wordmark)
struct ParceloAppIcon: View {
    var size: CGFloat = 120

    var body: some View {
        ParceloLogoD(showWordmark: false, size: size)
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 40) {

        // Full logo — large
        ParceloLogoD(size: 120)

        // Full logo — medium
        ParceloLogoD(size: 80)

        // Icon only — app icon style
        ParceloAppIcon(size: 100)

        // On a card background
        ParceloLogoD(size: 90)
            .padding(24)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 4)

        // Dark background
        ParceloLogoD(size: 90)
            .padding(24)
            .background(Color(red: 0.1, green: 0.08, blue: 0.18))
            .cornerRadius(20)
    }
    .padding(32)
}
