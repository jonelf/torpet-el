import Foundation
import UserNotifications

/// Bevakning av en plugg: larm om den slutar dra ström eller går offline.
/// Sparas i molnet, som också avgör när det larmar (cloud/lambda/index.mjs).
struct WatchConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Under så här många watt räknas pluggen som strömlös.
    var minWatts: Double = 10
    /// Så länge den får vara strömlös innan det larmar. En frys kompressor står still en stund mellan varven.
    var hours: Double = 3
    var offlineAlarm: Bool = true
    var offlineMinutes: Double = 30

    /// Pluggar som heter något med frys bevakas från början.
    static func `default`(for name: String) -> WatchConfig {
        let n = name.lowercased()
        return WatchConfig(enabled: n.contains("frys") || n.contains("freez"))
    }
}

/// Larmläget för en plugg, som molnet räknat fram.
struct AlarmStatus: Equatable, Sendable {
    /// Början på en obruten, observerad period under gränsen.
    var idleSince: Date?
    /// Senaste mätningen över gränsen.
    var lastActive: Date?
    /// Första mätningen i den pågående offline-perioden.
    var offlineSince: Date?
    /// Senaste mätningen är så ny att vi vet hur det står till just nu.
    var fresh = false
    var idleAlarm = false
    var offlineAlarm = false
}

enum Alarm {
    /// Längre glapp än så mellan mätningar bryter en period, och delar linjen i diagrammet.
    static let maxGap: TimeInterval = 20 * 60
}

// MARK: - Notiser

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Notiser kräver en app med bundle-ID, så inte när den körs med swift run.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() async -> Bool? {
        guard available else { return nil }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        return (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func send(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Visa notisen även när appen är aktiv, vilket en menyradsapp ofta är.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
