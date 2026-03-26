//
//  AWSManager.swift
//  CMP Tracking
//
//  Single entry point for all AWS API Gateway calls.
//  After deploying the SAM backend, set AWSConfig.baseURL to your
//  API Gateway invoke URL and this class handles the rest.
//

import Foundation

// MARK: - AWS API Errors

enum AWSError: LocalizedError {
    case invalidURL
    case noData
    case serverError(String)
    case httpError(Int, String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "Invalid URL."
        case .noData:                return "No data received from server."
        case .serverError(let msg):  return msg
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .notConfigured:         return "AWS backend URL not configured. Open AWSConfig.swift and set baseURL."
        }
    }
}

// MARK: - AWS Manager

class AWSManager {

    static let shared = AWSManager()
    private init() {}

    // JWT token stored after login
    private(set) var jwtToken: String? {
        get { UserDefaults.standard.string(forKey: "cmp.aws.jwt") }
        set { UserDefaults.standard.set(newValue, forKey: "cmp.aws.jwt") }
    }

    var isConfigured: Bool {
        !AWSConfig.baseURL.contains("REPLACE_WITH")
    }

    // MARK: - Encoders / Decoders

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

    // MARK: - Auth: Register

    /// Creates a new user account on AWS.
    func register(name: String,
                  email: String,
                  phone: String,
                  password: String,
                  role: String,
                  tenantId: String? = nil,
                  completion: @escaping (Result<AWSUser, Error>) -> Void) {
        guard isConfigured else {
            completion(.failure(AWSError.notConfigured)); return
        }
        var body: [String: Any] = [
            "name": name, "email": email, "phone": phone,
            "password": password, "role": role
        ]
        if let tenantId = tenantId, !tenantId.isEmpty {
            body["tenantId"] = tenantId
        }
        request(path: "/users/register", method: "POST", body: body, auth: false) { result in
            self.decode(result, key: "user", completion: completion)
        }
    }

    // MARK: - Auth: Login

    /// Signs in and stores the JWT token for subsequent requests.
    func login(email: String,
               password: String,
               completion: @escaping (Result<AWSLoginResponse, Error>) -> Void) {
        guard isConfigured else {
            completion(.failure(AWSError.notConfigured)); return
        }
        let body: [String: Any] = ["email": email, "password": password]
        request(path: "/users/login", method: "POST", body: body, auth: false) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(AWSLoginResponse.self, from: data)
                    self?.jwtToken = response?.token
                    if let response = response {
                        completion(.success(response))
                    } else {
                        completion(.failure(AWSError.noData))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Auth: Sign Out

    func signOut() {
        jwtToken = nil
        UserDefaults.standard.removeObject(forKey: "cmp.aws.jwt")
    }

    // MARK: - Loads: Fetch All

    func fetchLoads(completion: @escaping (Result<[Load], Error>) -> Void) {
        request(path: "/loads", method: "GET") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let loads = try self.decoder.decode([Load].self, from: data)
                    completion(.success(loads))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Loads: Create

    func createLoad(_ load: Load, completion: @escaping (Result<Load, Error>) -> Void) {
        guard let body = try? encoder.encode(load),
              let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            completion(.failure(AWSError.noData)); return
        }
        request(path: "/loads", method: "POST", body: dict) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let created = try self.decoder.decode(Load.self, from: data)
                    completion(.success(created))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Loads: Update Status (authenticated — dispatcher use)

    func updateLoadStatus(loadId: String,
                          status: LoadStatus,
                          completion: ((Error?) -> Void)? = nil) {
        let body: [String: Any] = ["status": status.rawValue]
        request(path: "/loads/\(loadId)/status", method: "PATCH", body: body) { result in
            switch result {
            case .success: completion?(nil)
            case .failure(let err): completion?(err)
            }
        }
    }

    // MARK: - Loads: Update Status by Token (PUBLIC — no auth, driver use)

    /// Called by the driver app when they tap Start/Stop Tracking.
    /// Uses the public `/track/{token}/status` endpoint so no JWT is needed.
    func updateStatusByToken(token: String,
                             loadId: String,
                             status: LoadStatus,
                             completion: ((Error?) -> Void)? = nil) {
        guard let url = URL(string: AWSConfig.baseURL + "/track/\(token)/status") else {
            completion?(AWSError.invalidURL); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = ["status": status.rawValue, "loadId": loadId]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("📡 updateStatusByToken → PATCH \(url.absoluteString)")
        print("📡   token=\(token)  loadId=\(loadId)  status=\(status.rawValue)")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let http = response as? HTTPURLResponse {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                print("📡 updateStatusByToken ← HTTP \(http.statusCode): \(body)")
            }
            if let error = error {
                print("📡 updateStatusByToken ✗ error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion?(error) }
        }.resume()
    }

    // MARK: - Locations: Post GPS Fix

    func postLocation(_ update: LocationUpdate, completion: ((Error?) -> Void)? = nil) {
        guard let body = try? encoder.encode(update),
              let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            completion?(AWSError.noData); return
        }
        request(path: "/locations", method: "POST", body: dict) { result in
            switch result {
            case .success: completion?(nil)
            case .failure(let err): completion?(err)
            }
        }
    }

    // MARK: - Locations: Get Latest for Load

    func fetchLatestLocation(loadId: String,
                             completion: @escaping (Result<LocationUpdate, Error>) -> Void) {
        request(path: "/loads/\(loadId)/location", method: "GET") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let loc = try self.decoder.decode(LocationUpdate.self, from: data)
                    completion(.success(loc))
                } catch { completion(.failure(error)) }
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    // MARK: - Public: Track by Token (no auth)

    func fetchLoadByToken(_ token: String,
                          completion: @escaping (Result<Load, Error>) -> Void) {
        request(path: "/track/\(token)", method: "GET", auth: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let load = try self.decoder.decode(Load.self, from: data)
                    completion(.success(load))
                } catch { completion(.failure(error)) }
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    // MARK: - Send Driver Tracking Link (SMS via backend)

    /// Sends an SMS to the driver with the browser-based tracking link.
    /// The backend also emails the dispatcher and, optionally, the customer.
    func sendDriverTrackingLink(loadId: String,
                                driverPhone: String,
                                dispatcherEmail: String,
                                notifyCustomer: Bool,
                                completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = [
            "driverPhone":     driverPhone,
            "dispatcherEmail": dispatcherEmail,
            "notifyCustomer":  notifyCustomer,
        ]
        request(path: "/loads/\(loadId)/send-driver-link", method: "POST", body: body) { result in
            switch result {
            case .success: completion(.success(()))
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    // MARK: - Private: Core Request

    private func request(path: String,
                         method: String,
                         body: [String: Any]? = nil,
                         auth: Bool = true,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: AWSConfig.baseURL + path) else {
            completion(.failure(AWSError.invalidURL)); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        if auth, let token = jwtToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error)); return
                }
                guard let data = data else {
                    completion(.failure(AWSError.noData)); return
                }
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    // Try to extract error message from body
                    let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                        .flatMap { $0["error"] as? String }
                        ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    completion(.failure(AWSError.httpError(http.statusCode, msg))); return
                }
                completion(.success(data))
            }
        }.resume()
    }

    // MARK: - Helper: decode a keyed object

    private func decode<T: Decodable>(_ result: Result<Data, Error>,
                                      key: String? = nil,
                                      completion: @escaping (Result<T, Error>) -> Void) {
        switch result {
        case .failure(let err):
            completion(.failure(err))
        case .success(let data):
            do {
                if let key = key,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let nested = json[key],
                   let nestedData = try? JSONSerialization.data(withJSONObject: nested) {
                    let obj = try decoder.decode(T.self, from: nestedData)
                    completion(.success(obj))
                } else {
                    let obj = try decoder.decode(T.self, from: data)
                    completion(.success(obj))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}

// MARK: - AWS Response Models

struct AWSLoginResponse: Codable {
    let token: String
    let user: AWSUser
}

struct AWSUser: Codable {
    let email: String
    let name: String
    let phone: String
    let role: String
    let createdAt: String?
}
