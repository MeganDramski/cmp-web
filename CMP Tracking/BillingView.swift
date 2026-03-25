//
//  BillingView.swift
//  CMP Tracking
//
//  Dispatcher billing screen.
//  • Shows current plan status
//  • Lets the dispatcher upgrade to Pro or Enterprise
//  • Calls POST /billing/checkout → gets a Stripe Checkout URL
//  • Opens the URL in an in-app SafariSheet
//  • Handles ?billing=success / ?billing=cancelled deep-link back
//

import SwiftUI
import SafariServices

// MARK: - Plan model

private struct Plan: Identifiable {
    let id: String          // "pro" | "enterprise"
    let name: String
    let price: String
    let period: String
    let color: Color
    let icon: String
    let features: [String]
}

private let plans: [Plan] = [
    Plan(
        id: "pro",
        name: "Pro",
        price: "$49",
        period: "/ month",
        color: .blue,
        icon: "bolt.fill",
        features: [
            "Unlimited loads",
            "Unlimited dispatchers",
            "Real-time GPS tracking",
            "Email + SMS notifications",
            "Priority support"
        ]
    ),
    Plan(
        id: "enterprise",
        name: "Enterprise",
        price: "$149",
        period: "/ month",
        color: Color(red: 0.58, green: 0.33, blue: 0.97),
        icon: "building.2.fill",
        features: [
            "Everything in Pro",
            "Dedicated account manager",
            "Custom integrations",
            "SLA guarantee",
            "White-label options"
        ]
    )
]

// MARK: - BillingView

struct BillingView: View {
    @EnvironmentObject var appState: AppState

    @State private var isLoading: [String: Bool] = [:]   // keyed by plan id
    @State private var errorMsg: String? = nil
    @State private var checkoutURL: URL? = nil
    @State private var showSafari = false
    @State private var billingResult: BillingResult? = nil

    enum BillingResult { case success, cancelled }

    // Current plan from JWT stored in UserDefaults (set at login)
    private var currentPlan: String {
        guard let token = UserDefaults.standard.string(forKey: "cmp.aws.jwt"),
              let payload = decodeJWTPayload(token) else { return "inactive" }
        return payload["plan"] as? String ?? "inactive"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // ── Current plan banner ───────────────────────────────────
                currentPlanBanner

                // ── Result banners ────────────────────────────────────────
                if let result = billingResult {
                    resultBanner(result)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // ── Error ─────────────────────────────────────────────────
                if let msg = errorMsg {
                    Text(msg)
                        .font(.caption).foregroundColor(.red)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08)).cornerRadius(10)
                        .padding(.horizontal)
                }

                // ── Plan cards ────────────────────────────────────────────
                Text("Choose a plan")
                    .font(.title3).fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                ForEach(plans) { plan in
                    PlanCard(
                        plan: plan,
                        isCurrent: currentPlan == plan.id,
                        isLoading: isLoading[plan.id] ?? false
                    ) {
                        startCheckout(plan: plan.id)
                    }
                }

                // ── Fine print ────────────────────────────────────────────
                VStack(spacing: 4) {
                    Text("Payments are processed securely by Stripe.")
                    Text("Cancel anytime — no long-term contracts.")
                    Text("Test mode: use card 4242 4242 4242 4242.")
                }
                .font(.caption2).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal).padding(.bottom, 32)
            }
            .padding(.top, 16)
        }
        .navigationTitle("Billing")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSafari) {
            if let url = checkoutURL {
                SafariSheet(url: url) { callbackURL in
                    handleCallback(callbackURL)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .billingCallback)) { note in
            if let url = note.object as? URL { handleCallback(url) }
        }
    }

    // MARK: Sub-views

    private var currentPlanBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: planIcon(currentPlan))
                .font(.title2)
                .foregroundColor(planColor(currentPlan))
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Plan")
                    .font(.caption).foregroundColor(.secondary)
                Text(planDisplayName(currentPlan))
                    .font(.headline).fontWeight(.bold)
                    .foregroundColor(planColor(currentPlan))
            }
            Spacer()
            if currentPlan == "inactive" {
                Text("Upgrade to dispatch")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
            }
        }
        .padding(16)
        .background(planColor(currentPlan).opacity(0.08))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(planColor(currentPlan).opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }

    private func resultBanner(_ result: BillingResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result == .success ? .green : .orange)
            Text(result == .success
                 ? "🎉 Subscription activated! Your plan is now active."
                 : "Checkout cancelled — no charge was made.")
                .font(.subheadline)
            Spacer()
            Button(action: { withAnimation { billingResult = nil } }) {
                Image(systemName: "xmark").foregroundColor(.secondary).font(.caption)
            }
        }
        .padding(12)
        .background(result == .success ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: Actions

    private func startCheckout(plan: String) {
        errorMsg = nil
        billingResult = nil
        isLoading[plan] = true

        guard let token = UserDefaults.standard.string(forKey: "cmp.aws.jwt"),
              let url = URL(string: "\(AWSConfig.baseURL)/billing/checkout") else {
            errorMsg = "Not signed in."; isLoading[plan] = false; return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["plan": plan])

        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                isLoading[plan] = false
                if let error = error { errorMsg = error.localizedDescription; return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMsg = "Failed to start checkout."; return
                }
                if let e = json["error"] as? String { errorMsg = e; return }
                guard let urlStr = json["url"] as? String, let dest = URL(string: urlStr) else {
                    errorMsg = "Invalid checkout URL."; return
                }
                checkoutURL = dest
                showSafari = true
            }
        }.resume()
    }

    private func handleCallback(_ url: URL) {
        showSafari = false
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "billing" })?.value
        withAnimation {
            billingResult = query == "success" ? .success : .cancelled
        }
        if query == "success" {
            // Auto-hide success banner after 6s
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                withAnimation { billingResult = nil }
            }
        }
    }

    // MARK: Helpers

    private func planDisplayName(_ plan: String) -> String {
        switch plan {
        case "pro":         return "Pro"
        case "enterprise":  return "Enterprise"
        case "inactive":    return "No active plan"
        default:            return plan.capitalized
        }
    }

    private func planIcon(_ plan: String) -> String {
        switch plan {
        case "pro":         return "bolt.fill"
        case "enterprise":  return "building.2.fill"
        default:            return "exclamationmark.triangle.fill"
        }
    }

    private func planColor(_ plan: String) -> Color {
        switch plan {
        case "pro":         return .blue
        case "enterprise":  return Color(red: 0.58, green: 0.33, blue: 0.97)
        default:            return .orange
        }
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1]
        let rem = base64.count % 4
        if rem > 0 { base64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}

// MARK: - Plan Card

private struct PlanCard: View {
    let plan: Plan
    let isCurrent: Bool
    let isLoading: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: plan.icon)
                            .foregroundColor(plan.color)
                            .font(.title3)
                        Text(plan.name)
                            .font(.title3).fontWeight(.bold)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(plan.price)
                            .font(.system(size: 32, weight: .black))
                            .foregroundColor(plan.color)
                        Text(plan.period)
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Text("Current")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(plan.color.opacity(0.15))
                        .foregroundColor(plan.color)
                        .cornerRadius(20)
                }
            }

            Divider()

            // Features
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.features, id: \.self) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(plan.color)
                            .font(.subheadline)
                        Text(feature)
                            .font(.subheadline)
                    }
                }
            }

            // CTA button
            Button(action: onSelect) {
                if isLoading {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(plan.color).cornerRadius(12)
                } else if isCurrent {
                    Label("Current Plan", systemImage: "checkmark")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(plan.color.opacity(0.15))
                        .foregroundColor(plan.color)
                        .cornerRadius(12)
                } else {
                    Text("Upgrade to \(plan.name)")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(plan.color).foregroundColor(.white).cornerRadius(12)
                }
            }
            .disabled(isCurrent || isLoading)
        }
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isCurrent ? plan.color.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        .padding(.horizontal)
    }
}

// MARK: - Safari Sheet

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    let onCallback: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.delegate = context.coordinator
        vc.preferredControlTintColor = UIColor.systemBlue
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}

    class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onCallback: (URL) -> Void
        init(onCallback: @escaping (URL) -> Void) { self.onCallback = onCallback }

        func safariViewController(_ controller: SFSafariViewController,
                                   initialLoadDidRedirectTo URL: URL) {
            let host = URL.host ?? ""
            if host.contains("amplifyapp") || host.contains("execute-api") {
                controller.dismiss(animated: true)
                onCallback(URL)
            }
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let billingCallback = Notification.Name("billingCallback")
}

#Preview {
    NavigationView {
        BillingView()
            .environmentObject(AppState.shared)
    }
}
