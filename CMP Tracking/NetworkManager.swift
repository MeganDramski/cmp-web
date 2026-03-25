//
//  NetworkManager.swift
//  CMP Tracking
//
//  Created by Megan Dramski on 3/18/26.
//
//  HOW TO CONFIGURE:
//  1. Replace `baseURL` with your server's REST API base URL.
//  2. Replace `wsURL` with your server's WebSocket endpoint.
//  3. The driver app POSTs LocationUpdates to REST and also streams via WebSocket.
//  4. The dispatcher/customer app subscribes to a load's WebSocket channel to receive live updates.
//

import Foundation
import Combine

// MARK: - Network Manager

class NetworkManager: NSObject, ObservableObject {

    // ─── BASE URL pulled from AWSConfig.swift ───────────────────────────────────
    // After deploying the SAM backend, set AWSConfig.baseURL to your API Gateway URL.
    static var baseURL: String { AWSConfig.baseURL }
    static let wsBaseURL = "wss://REPLACE_WITH_YOUR_WS_URL/ws"   // WebSocket (future)
    // ────────────────────────────────────────────────────────────────────────────

    static let shared = NetworkManager()

    // MARK: - Published state (for subscribers/dispatcher view)
    @Published var liveLocation: LocationUpdate?
    @Published var wsConnected: Bool = false
    @Published var wsError: String?

    // MARK: - Private WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var pingTimer: Timer?
    private var currentLoadId: String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - REST: Notify dispatcher when driver accepts a load

    func notifyDispatcherLoadAccepted(load: Load, driverName: String,
                                      completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(NetworkManager.baseURL)/api/loads/\(load.id)/accept") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let payload: [String: String] = [
            "loadId":          load.id,
            "loadNumber":      load.loadNumber,
            "driverName":      driverName,
            "driverEmail":     load.assignedDriverEmail ?? "",
            "dispatcherEmail": load.dispatcherEmail ?? ""
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("⚠️ notifyDispatcherLoadAccepted: server unreachable (\(error.localizedDescription)). Treating as success.")
                }
                completion(.success(()))
            }
        }.resume()
    }

    // MARK: - REST: Notify customer & dispatcher when tracking starts
    //
    // Your server receives this and should:
    //  1. Send the customer an email/SMS with the tracking link
    //  2. Send the dispatcher an in-app push notification
    //
    // Payload: { loadId, trackingToken, trackingURL, driverName, customerEmail, dispatcherEmail }
    //
    func notifyTrackingStarted(load: Load, driverName: String,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(NetworkManager.baseURL)/api/loads/\(load.id)/notify-tracking-started") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let payload: [String: String] = [
            "loadId":          load.id,
            "loadNumber":      load.loadNumber,
            "trackingToken":   load.trackingToken,
            "trackingURL":     load.customerTrackingURL,   // web link — customers don't have the app
            "driverName":      driverName,
            "customerName":    load.customerName,
            "customerEmail":   load.customerEmail,
            "customerPhone":   load.customerPhone   // server uses this to send SMS
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    // ── DEMO FALLBACK ─────────────────────────────────────────
                    // When there's no real server yet, treat network errors as
                    // success so the driver still sees the confirmation banner
                    // and the share sheet still opens.
                    print("⚠️ notifyTrackingStarted: server unreachable (\(error.localizedDescription)). Using local share fallback.")
                    completion(.success(()))
                    return
                }
                completion(.success(()))
            }
        }.resume()
    }

    // MARK: - REST: Send location update (driver → server)

    func sendLocationUpdate(_ update: LocationUpdate, completion: ((Error?) -> Void)? = nil) {
        // Prefer the AWSManager wrapper which handles auth automatically
        AWSManager.shared.postLocation(update, completion: completion)
    }

    // MARK: - REST: Fetch loads (dispatcher)

    func fetchLoads(completion: @escaping ([Load]?, Error?) -> Void) {
        AWSManager.shared.fetchLoads { result in
            switch result {
            case .success(let loads): completion(loads, nil)
            case .failure(let err):   completion(nil, err)
            }
        }
    }

    // MARK: - REST: Update load status

    func updateLoadStatus(loadId: String, status: LoadStatus, completion: ((Error?) -> Void)? = nil) {
        AWSManager.shared.updateLoadStatus(loadId: loadId, status: status, completion: completion)
    }

    // MARK: - REST: Fetch a load by tracking token (customer-facing, no auth needed)

    func fetchLoadByToken(_ token: String, completion: @escaping (Result<Load, Error>) -> Void) {
        if AWSManager.shared.isConfigured {
            AWSManager.shared.fetchLoadByToken(token, completion: completion)
        } else {
            // Local sample-data fallback during development
            if let match = Load.sampleLoads.first(where: { $0.trackingToken == token }) {
                completion(.success(match))
            } else {
                let err = NSError(domain: "CMPTracking", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "No shipment found for this tracking link."])
                completion(.failure(err))
            }
        }
    }

    // MARK: - REST: Fetch latest location for a load (polling fallback)

    func fetchLatestLocation(loadId: String, completion: @escaping (LocationUpdate?, Error?) -> Void) {
        AWSManager.shared.fetchLatestLocation(loadId: loadId) { result in
            switch result {
            case .success(let loc): completion(loc, nil)
            case .failure(let err): completion(nil, err)
            }
        }
    }

    // MARK: - WebSocket: Connect to live channel for a load

    func connectWebSocket(forLoadId loadId: String) {
        disconnectWebSocket()
        currentLoadId = loadId
        guard let url = URL(string: "\(NetworkManager.wsBaseURL)/loads/\(loadId)") else { return }
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        wsConnected = true
        sendSubscribeMessage(loadId: loadId)
        receiveWebSocketMessage()
        startPingTimer()
    }

    func disconnectWebSocket() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.wsConnected = false
        }
    }

    // MARK: - WebSocket: Send location (driver streams via WS)

    func sendLocationOverWebSocket(_ update: LocationUpdate) {
        guard wsConnected else {
            // Fallback to REST
            sendLocationUpdate(update)
            return
        }
        let message = WSMessage(type: .locationUpdate, payload: update, loadId: update.loadId, message: nil)
        guard let data = try? encoder.encode(message),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.wsError = error.localizedDescription
                }
                // Fallback to REST
                self?.sendLocationUpdate(update)
            }
        }
    }

    // MARK: - Private WebSocket Helpers

    private func sendSubscribeMessage(loadId: String) {
        let message = WSMessage(type: .subscribe, payload: nil, loadId: loadId, message: nil)
        guard let data = try? encoder.encode(message),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(jsonString)) { _ in }
    }

    private func receiveWebSocketMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWebSocketText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleWebSocketText(text)
                    }
                @unknown default:
                    break
                }
                // Keep listening
                self.receiveWebSocketMessage()

            case .failure(let error):
                DispatchQueue.main.async {
                    self.wsConnected = false
                    self.wsError = error.localizedDescription
                }
                // Auto-reconnect after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if let loadId = self.currentLoadId {
                        self.connectWebSocket(forLoadId: loadId)
                    }
                }
            }
        }
    }

    private func handleWebSocketText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? decoder.decode(WSMessage.self, from: data) else { return }

        if message.type == .locationUpdate, let location = message.payload {
            DispatchQueue.main.async {
                self.liveLocation = location
            }
        }
    }

    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { _ in }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension NetworkManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.wsConnected = true }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.wsConnected = false }
    }
}
