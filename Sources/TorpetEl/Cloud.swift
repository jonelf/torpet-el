import Foundation

// The Lambda in cloud/ polls Tuya every five minutes, keeps the readings and decides on alarms.
// The app only reads from it, and saves the alarm settings there. API: cloud/README.md.

// MARK: - Model

struct Plug: Identifiable, Sendable {
    let id: String
    let name: String
    let product: String?
    let online: Bool
    let isOn: Bool?
    /// Watts, volts and amperes, or nil if the plug doesn't meter.
    let power: Double?
    let voltage: Double?
    let current: Double?

    var hasMeter: Bool { power != nil }

    func with(isOn: Bool) -> Plug {
        Plug(id: id, name: name, product: product, online: online, isOn: isOn, power: power, voltage: voltage, current: current)
    }
}

/// One reading of a plug.
struct Sample: Sendable {
    let date: Date
    let online: Bool
    let power: Double?
}

struct CloudSnapshot: Decodable, Sendable {
    struct Status: Decodable, Sendable {
        let idleSince, lastActive, offlineSince, lastReading: Double?
        let fresh, idleAlarm, offlineAlarm: Bool?
    }

    struct CloudPlug: Decodable, Sendable {
        let id: String
        let name: String?
        let product: String?
        let online: Bool?
        let isOn: Bool?
        let power, voltage, current: Double?
        let watch: WatchConfig?
        let status: Status?

        var plug: Plug {
            Plug(id: id, name: name ?? id, product: product, online: online ?? false, isOn: isOn,
                 power: power, voltage: voltage, current: current)
        }

        var alarmStatus: AlarmStatus {
            let d = { (s: Double?) in s.map { Date(timeIntervalSince1970: $0) } }
            return AlarmStatus(idleSince: d(status?.idleSince), lastActive: d(status?.lastActive),
                               offlineSince: d(status?.offlineSince), fresh: status?.fresh ?? false,
                               idleAlarm: status?.idleAlarm ?? false, offlineAlarm: status?.offlineAlarm ?? false)
        }
    }

    /// When the cloud last fetched from Tuya.
    let fetchedAt: Double?
    let tuyaError: String?
    let tuyaFailingSince: Double?
    let plugs: [CloudPlug]
}

// MARK: - Settings

struct CloudConfig: Codable, Sendable {
    var url: String
    var apiKey: String

    enum CodingKeys: String, CodingKey { case url, apiKey = "api_key" }
}

/// URL and key in ~/Library/Application Support/TorpetEl/cloud.json, readable only by the user.
enum CloudStore {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorpetEl")
    }
    static var url: URL { dir.appendingPathComponent("cloud.json") }

    static func load() -> CloudConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CloudConfig.self, from: data)
    }

    static func save(_ c: CloudConfig) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(c).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Client

enum CloudError: LocalizedError {
    case notConfigured, badURL, unauthorized, http(Int), server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L.t("Molnets adress och nyckel saknas.", "The cloud URL and key are missing.")
        case .badURL: L.t("Molnets adress är ogiltig.", "The cloud URL is invalid.")
        case .unauthorized: L.t("Molnet godtog inte API-nyckeln.", "The cloud rejected the API key.")
        case .http(let code): L.t("Molnet svarade HTTP \(code).", "The cloud responded HTTP \(code).")
        case .server(let msg): msg
        }
    }
}

actor CloudClient {
    private var config: CloudConfig? = CloudStore.load()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    var isConfigured: Bool { config != nil }
    var current: CloudConfig? { config }

    func configure(_ c: CloudConfig) throws {
        guard URL(string: c.url)?.scheme == "https" else { throw CloudError.badURL }
        try CloudStore.save(c)
        config = c
    }

    func status() async throws -> CloudSnapshot {
        try JSONDecoder().decode(CloudSnapshot.self, from: try await send("GET", "status"))
    }

    /// Readings from `since` on, in time order.
    func samples(device: String, since: Date) async throws -> [Sample] {
        struct R: Decodable {
            struct S: Decodable { let t: Double; let online: Bool?; let power: Double? }
            let samples: [S]
        }
        let data = try await send("GET", "samples", query: ["device": device, "since": String(Int(since.timeIntervalSince1970))])
        return try JSONDecoder().decode(R.self, from: data).samples.map {
            Sample(date: Date(timeIntervalSince1970: $0.t), online: $0.online ?? false, power: $0.power)
        }
    }

    func saveWatch(_ id: String, _ w: WatchConfig) async throws {
        _ = try await send("PUT", "watch/\(id)", body: try JSONEncoder().encode(w))
    }

    /// Slår på eller av pluggen via Tuya.
    func setSwitch(_ id: String, on: Bool) async throws {
        _ = try await send("POST", "switch/\(id)", body: try JSONEncoder().encode(["on": on]))
    }

    /// Asks the cloud to send a test alarm through ntfy.
    func test() async throws {
        _ = try await send("POST", "test")
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        guard let c = config else { throw CloudError.notConfigured }
        guard var comps = URL(string: c.url).flatMap({ URLComponents(url: $0.appending(path: path), resolvingAgainstBaseURL: false) })
        else { throw CloudError.badURL }
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw CloudError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(c.apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw CloudError.unauthorized }
        guard (200..<300).contains(code) else {
            struct E: Decodable { let error: String }
            if let e = try? JSONDecoder().decode(E.self, from: data) { throw CloudError.server(e.error) }
            throw CloudError.http(code)
        }
        return data
    }
}
