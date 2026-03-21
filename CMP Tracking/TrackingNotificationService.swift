//
//  TrackingNotificationService.swift
//  CMP Tracking
//
//  Handles sending the tracking link directly to the customer (email + SMS)
//  and dispatcher (email) using the device's built-in Mail and Messages apps.
//
//  On simulator: shows a test panel with the URL, email preview, and SMS preview.
//

import SwiftUI
import MessageUI
import UserNotifications

// MARK: - Arrival Notification Service

/// Fires a local push notification when the driver arrives at the destination.
/// Works whether the app is in the foreground or background.
enum ArrivalNotificationService {

    static func fireArrivalNotification(loadNumber: String, address: String) {
        let content = UNMutableNotificationContent()
        content.title = "📍 You Have Arrived!"
        content.body  = "Load \(loadNumber) has reached its destination: \(address)"
        content.sound = .default

        // Fire immediately (trigger = nil means "right now")
        let request = UNNotificationRequest(
            identifier: "arrival-\(loadNumber)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Arrival notification error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Pickup Reminder Notification Service

/// Schedules (and cancels) local notifications that remind the driver to start driving.
///
/// Two notifications are scheduled for each assigned load:
///  • **30-minute warning** — fires 30 min before `pickupDate`
///  • **Pickup time alert**  — fires exactly at `pickupDate`
///
/// Tapping either notification deep-links the driver straight to DriverView
/// via the `cmptracking://driver` URL scheme.
enum PickupReminderService {

    // Stable identifiers so we can cancel them later
    private static func earlyID(loadId: String)  -> String { "pickup-early-\(loadId)"  }
    private static func onTimeID(loadId: String) -> String { "pickup-ontime-\(loadId)" }

    /// Schedule (or re-schedule) pickup reminders for a load.
    /// Call this whenever a load is assigned or its pickup time changes.
    static func schedule(load: Load) {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            // Cancel any existing reminders for this load first
            cancel(loadId: load.id)

            let now = Date()

            // ── 30-minute early warning ──────────────────────────────────
            let earlyFireDate = load.pickupDate.addingTimeInterval(-30 * 60)
            if earlyFireDate > now {
                let content = UNMutableNotificationContent()
                content.title = "🚛 Pickup in 30 Minutes"
                content.body  = "Load \(load.loadNumber): head to \(load.pickupAddress)"
                content.sound = .default
                content.userInfo = ["loadId": load.id, "action": "openDriver"]

                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: earlyFireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(identifier: earlyID(loadId: load.id),
                                                    content: content,
                                                    trigger: trigger)
                center.add(request) { err in
                    if let err { print("⚠️ Pickup early reminder error: \(err)") }
                }
            }

            // ── On-time pickup alert ─────────────────────────────────────
            if load.pickupDate > now {
                let content = UNMutableNotificationContent()
                content.title = "🚛 Time to Start Driving!"
                content.body  = "Load \(load.loadNumber) pickup: \(load.pickupAddress)"
                content.sound = .defaultCritical
                content.userInfo = ["loadId": load.id, "action": "openDriver"]

                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: load.pickupDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(identifier: onTimeID(loadId: load.id),
                                                    content: content,
                                                    trigger: trigger)
                center.add(request) { err in
                    if let err { print("⚠️ Pickup on-time reminder error: \(err)") }
                }
            }
        }
    }

    /// Cancel all pending pickup reminders for a load (call on unassign / deliver / cancel).
    static func cancel(loadId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [earlyID(loadId: loadId), onTimeID(loadId: loadId)]
        )
    }
}

// MARK: - Email Composer

struct MailComposer: UIViewControllerRepresentable {
    let to: [String]
    let subject: String
    let body: String
    let onFinish: (MFMailComposeResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(to)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: true)
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

// MARK: - SMS Composer

struct SMSComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: (MessageComposeResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.recipients = recipients
        vc.body = body
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

// MARK: - Notification State

enum NotificationStep {
    case idle, sendingEmail, sendingSMS, done
}

// MARK: - Send Tracking View

struct SendTrackingView: View {
    let load: Load
    let dispatcherEmail: String
    let onSent: (String) -> Void

    @State private var step: NotificationStep = .idle
    @State private var canSendMail        = MFMailComposeViewController.canSendMail()
    @State private var canSendSMS         = MFMessageComposeViewController.canSendText()
    @State private var showMailComposer   = false
    @State private var showSMSComposer    = false
    @State private var showSimulatorPanel = false

    // MARK: Computed content

    private var emailBody: String {
        """
        <html><body>
        <p>Hello <strong>\(load.customerName)</strong>,</p>
        <p>Your shipment <strong>\(load.loadNumber)</strong> is now on its way!</p>
        <p>Track your delivery in real time by clicking the link below:</p>
        <p style="margin:20px 0;">
          <a href="\(load.trackingURL)" style="background:#007AFF;color:white;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;">
            📍 Track My Shipment
          </a>
        </p>
        <p style="color:#666;font-size:12px;">
          Pickup: \(load.pickupAddress)<br>
          Delivery: \(load.deliveryAddress)<br>
          Est. Delivery: \(load.deliveryDate.formatted(date: .abbreviated, time: .shortened))
        </p>
        <p style="color:#999;font-size:11px;">
          This link is private and unique to your shipment.<br>
          — CMP Logistics
        </p>
        </body></html>
        """
    }

    private var emailTo: [String] {
        var recipients = [String]()
        if !load.customerEmail.isEmpty { recipients.append(load.customerEmail) }
        if !dispatcherEmail.isEmpty    { recipients.append(dispatcherEmail) }
        return recipients
    }

    private var smsBody: String {
        "📦 CMP Logistics: Your shipment \(load.loadNumber) is on its way! Track live: \(load.trackingURL)"
    }

    // MARK: Body

    var body: some View {
        Button(action: startSending) {
            HStack {
                Image(systemName: "paperplane.fill")
                Text("Send Tracking Link")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .sheet(isPresented: $showMailComposer) {
            MailComposer(
                to: emailTo,
                subject: "Your CMP Logistics Shipment \(load.loadNumber) Is On Its Way!",
                body: emailBody
            ) { result in
                showMailComposer = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !load.customerPhone.isEmpty && canSendSMS {
                        showSMSComposer = true
                    } else {
                        finish(emailResult: result, smsSent: false)
                    }
                }
            }
        }
        .sheet(isPresented: $showSMSComposer) {
            SMSComposer(recipients: [load.customerPhone], body: smsBody) { _ in
                showSMSComposer = false
                finish(emailResult: .sent, smsSent: true)
            }
        }
        .sheet(isPresented: $showSimulatorPanel) {
            SimulatorTrackingTestView(load: load, emailBody: emailBody, smsBody: smsBody)
        }
    }

    // MARK: Actions

    private func startSending() {
        #if targetEnvironment(simulator)
        // Simulator can never send mail or SMS — always go straight to the test panel
        showSimulatorPanel = true
        return
        #else
        if canSendMail && !emailTo.isEmpty {
            showMailComposer = true
        } else if !load.customerPhone.isEmpty && canSendSMS {
            showSMSComposer = true
        } else {
            // No mail/SMS configured on device → show test panel
            showSimulatorPanel = true
        }
        #endif
    }

    private func finish(emailResult: MFMailComposeResult, smsSent: Bool) {
        var parts = [String]()
        if emailResult == .sent { parts.append("email to \(load.customerEmail)") }
        if smsSent              { parts.append("SMS to \(load.customerPhone)") }
        if parts.isEmpty {
            UIPasteboard.general.string = load.trackingURL
            onSent("📋 Tracking link copied to clipboard")
        } else {
            onSent("✅ Tracking link sent via \(parts.joined(separator: " & "))")
        }
    }
}

// MARK: - Simulator Tracking Test Panel

struct SimulatorTrackingTestView: View {
    let load: Load
    let emailBody: String
    let smsBody: String

    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    @State private var selectedTab = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Orange banner
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer")
                        Text("Simulator Mode – Email & SMS unavailable")
                            .font(.caption).fontWeight(.semibold)
                    }
                    Text("On a real iPhone, tapping Send will automatically open Mail → then Messages to send to the customer.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .opacity(0.9)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.orange)

                // Real device summary
                VStack(alignment: .leading, spacing: 6) {
                    Label("Will be sent to:", systemImage: "paperplane.fill")
                        .font(.subheadline).fontWeight(.semibold)
                    HStack {
                        Image(systemName: "envelope.fill").foregroundColor(.blue)
                        Text(load.customerEmail.isEmpty ? "No email on file" : load.customerEmail)
                            .font(.caption)
                    }
                    HStack {
                        Image(systemName: "message.fill").foregroundColor(.green)
                        Text(load.customerPhone.isEmpty ? "No phone on file" : load.customerPhone)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground))

                Picker("View", selection: $selectedTab) {
                    Text("🔗 Link").tag(0)
                    Text("📧 Email").tag(1)
                    Text("💬 SMS").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    VStack(spacing: 20) {
                        switch selectedTab {
                        case 1:  emailTab
                        case 2:  smsTab
                        default: linkTab
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Test Tracking Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @State private var showTrackingPreview = false

    // MARK: Link Tab

    private var linkTab: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Tracking URL", systemImage: "link").font(.headline)
                Text(load.trackingURL)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
            }

            // Preview the in-app customer tracking page
            Button {
                showTrackingPreview = true
            } label: {
                Label("Preview Customer Tracking Page", systemImage: "iphone")
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.blue).foregroundColor(.white).cornerRadius(12)
            }
            .sheet(isPresented: $showTrackingPreview) {
                CustomerTrackingView(trackingToken: load.trackingToken)
            }

            Button {
                UIPasteboard.general.string = load.trackingURL
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied!" : "Copy Link",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity).padding()
                    .background(copied ? Color.green : Color(.secondarySystemBackground))
                    .foregroundColor(copied ? .white : .primary)
                    .cornerRadius(12)
            }

            infoCard
        }
    }

    // MARK: Email Tab

    private var emailTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Email Preview", systemImage: "envelope.fill").font(.headline)

            VStack(spacing: 0) {
                LabeledContent("To",
                    value: load.customerEmail.isEmpty ? "(no email)" : load.customerEmail)
                    .padding(.vertical, 6)
                Divider()
                LabeledContent("Subject",
                    value: "Your CMP Logistics Shipment \(load.loadNumber) Is On Its Way!")
                    .padding(.vertical, 6)
            }
            .padding(.horizontal)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)

            Text("Body (plain text preview)").font(.caption).foregroundColor(.secondary)

            Text(emailBody
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

            Text("💡 On a real device this email is sent automatically via the Mail app.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: SMS Tab

    private var smsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SMS Preview", systemImage: "message.fill").font(.headline)

            LabeledContent("To", value: load.customerPhone.isEmpty ? "(no phone)" : load.customerPhone)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)

            Text("Message").font(.caption).foregroundColor(.secondary)

            HStack {
                Text(smsBody)
                    .font(.subheadline)
                    .padding(12)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(16)
                Spacer()
            }

            Text("💡 On a real device this SMS is sent automatically via the Messages app.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: Info Card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Load Details", systemImage: "shippingbox").font(.headline)
            LabeledContent("Load #",   value: load.loadNumber)
            LabeledContent("Customer", value: load.customerName)
            LabeledContent("Token",    value: load.trackingToken)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
