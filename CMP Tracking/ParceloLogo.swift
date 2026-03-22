import SwiftUI

// MARK: - Parcelo Logo (Option A — Pin + Wordmark)
struct ParceloLogo: View {
    var showWordmark: Bool = true
    var size: CGFloat = 120

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.12) {
            ParceloPinIcon(size: size)
            if showWordmark {
                ParceloWordmark(size: size)
            }
        }
    }
}

// MARK: - Pin Icon
struct ParceloPinIcon: View {
    var size: CGFloat = 120

    private var pinWidth: CGFloat  { size * 0.45 }
    private var circleR: CGFloat   { pinWidth * 0.5 }
    private var innerR: CGFloat    { circleR * 0.38 }
    private var tailH: CGFloat     { pinWidth * 0.48 }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Circle head
                ZStack {
                    Circle()
                        .fill(Color.parceloBlue)
                        .frame(width: circleR * 2, height: circleR * 2)
                    Circle()
                        .fill(Color.white)
                        .frame(width: innerR * 2, height: innerR * 2)
                }

                // Pin tail
                PinTailShape()
                    .fill(Color.parceloBlue)
                    .frame(width: pinWidth * 0.55, height: tailH)
            }

            // Route dashes + destination dot (right of pin)
            HStack(spacing: size * 0.035) {
                ForEach(0..<3) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.parceloBlue)
                        .frame(width: size * 0.04, height: size * 0.025)
                }
                Circle()
                    .strokeBorder(Color.parceloBlue, lineWidth: size * 0.022)
                    .frame(width: size * 0.1, height: size * 0.1)
            }
            .offset(x: pinWidth * 0.72, y: circleR * 0.9)
        }
        .frame(width: pinWidth + size * 0.3, height: circleR * 2 + tailH)
    }
}

// MARK: - Pin Tail Shape
struct PinTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midX
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: mid + rect.width * 0.22, y: rect.height * 0.7))
        path.addLine(to: CGPoint(x: mid, y: rect.height))
        path.addLine(to: CGPoint(x: mid - rect.width * 0.22, y: rect.height * 0.7))
        path.closeSubpath()
        return path
    }
}

// MARK: - Wordmark
struct ParceloWordmark: View {
    var size: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.025) {
            Text("Parcelo")
                .font(.system(size: size * 0.26, weight: .semibold, design: .default))
                .foregroundColor(.primary)
                .kerning(-0.5)

            Text("LOGISTICS")
                .font(.system(size: size * 0.09, weight: .regular, design: .default))
                .foregroundColor(.secondary)
                .kerning(2.5)
        }
    }
}

// MARK: - Color Extension
extension Color {
    static let parceloBlue = Color(red: 0.216, green: 0.541, blue: 0.867) // #378ADD
}

// MARK: - Preview
#Preview {
    VStack(spacing: 40) {
        // Full logo with wordmark
        ParceloLogo(size: 120)

        // Icon only (for app icon / nav bar)
        ParceloLogo(showWordmark: false, size: 80)

        // Small inline version
        ParceloLogo(size: 60)

        // Dark background demo
        ParceloLogo(size: 100)
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
    }
    .padding(32)
}
