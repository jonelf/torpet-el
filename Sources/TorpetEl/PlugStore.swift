import Foundation
import ServiceManagement
import SwiftUI

enum ChartSpan: String, CaseIterable, Identifiable, Sendable {
    case sixHours, day, week
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixHours: L.t("6 tim", "6 h")
        case .day: L.t("Dygn", "Day")
        case .week: L.t("Vecka", "Week")
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .sixHours: 6 * 3600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }
}

struct ChartPoint: Identifiable, Sendable {
    let plugID: String
    let plugName: String
    let date: Date
    let power: Double
    /// Ny del efter ett glapp, så linjen inte dras över tid utan mätningar.
    let segment: Int
    var id: String { "\(plugID)|\(date.timeIntervalSince1970)" }
    /// En linje per plugg och del.
    var series: String { "\(plugID)|\(segment)" }
}

@MainActor
final class PlugStore: ObservableObject {
    @Published var plugs: [Plug] = []
    /// När molnet senast hämtade från Tuya.
    @Published var fetchedAt: Date?
    @Published var error: String?
    @Published var isLoading = false
    @Published var needsSetup = false
    @Published var showSettings = false
    @Published var notificationsAllowed: Bool?
    @Published var language: AppLanguage = L.lang {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: L.key) }
    }
    @Published var status: [String: AlarmStatus] = [:]
    @Published private(set) var watch: [String: WatchConfig] = [:]
    @Published var chartPlugID: String? { didSet { if chartPlugID != oldValue { Task { await loadChart() } } } }
    @Published var chartSpan: ChartSpan = .day { didSet { if chartSpan != oldValue { Task { await loadChart() } } } }
    @Published private(set) var chartSamples: [String: [Sample]] = [:]
    @Published private(set) var chartLoading = false
    /// Pluggar som håller på att slås på eller av.
    @Published private(set) var switching: Set<String> = []

    let client = CloudClient()
    /// Larm som redan visats som notis, så de inte upprepas efter omstart.
    private var notified = Set(UserDefaults.standard.stringArray(forKey: "notified") ?? [])
    /// Ändrade larminställningar som väntar på att sparas i molnet, per plugg.
    private var pendingSaves: [String: Task<Void, Never>] = [:]
    /// Från vilken tid diagrammets mätningar är hämtade, per plugg.
    private var chartFrom: [String: Date] = [:]
    private var started = false

    /// Molnet hämtar från Tuya var femte minut. Appen frågar molnet lite oftare, så den ligger högst ett par minuter efter.
    let interval: TimeInterval = 2 * 60
    /// Så gamla får molnets mätningar bli innan appen varnar.
    private static let stale: TimeInterval = 20 * 60

    func start() {
        guard !started else { return }
        started = true
        Task {
            notificationsAllowed = await Notifier.shared.setup()
            needsSetup = !(await client.isConfigured)
            showSettings = needsSetup
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Hämtar om data är äldre än `ifOlderThan` sekunder.
    func refresh(ifOlderThan age: TimeInterval = 0) async {
        if let f = lastRefresh, Date().timeIntervalSince(f) < age { return }
        guard await client.isConfigured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await client.status()
            lastRefresh = Date()
            plugs = snap.plugs.map(\.plug).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var w: [String: WatchConfig] = [:]
            for p in snap.plugs {
                // En ändring som inte hunnit sparas ska inte skrivas över av molnets äldre värde.
                w[p.id] = pendingSaves[p.id] != nil ? watch[p.id] : (p.watch ?? .default(for: p.plug.name))
            }
            watch = w
            status = Dictionary(uniqueKeysWithValues: snap.plugs.map { ($0.id, $0.alarmStatus) })
            fetchedAt = snap.fetchedAt.map { Date(timeIntervalSince1970: $0) }
            error = cloudProblem(snap)

            if chartPlugID == nil || (!chartShowsAll && !plugs.contains(where: { $0.id == chartPlugID })) {
                // Alla pluggar i samma diagram som standard, om det finns fler än en att jämföra.
                let metered = plugs.filter(\.hasMeter)
                chartPlugID = metered.count > 1 ? Self.allPlugs : metered.first?.id
            }
            notifyTransitions()
            await loadChart()
        } catch CloudError.notConfigured {
            needsSetup = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var lastRefresh: Date?

    /// Tuya-fel som molnet rapporterar, eller att molnet inte hämtat på länge.
    private func cloudProblem(_ snap: CloudSnapshot) -> String? {
        if let e = snap.tuyaError {
            let since = snap.tuyaFailingSince.map { L.t(" sedan ", " since ") + Fmt.time(Date(timeIntervalSince1970: $0)) } ?? ""
            return L.t("Molnet får inget svar från Tuya", "The cloud gets no answer from Tuya") + since + ": " + e
        }
        if let f = fetchedAt, Date().timeIntervalSince(f) > Self.stale {
            return L.t("Molnet har inte hämtat något sedan ", "The cloud hasn't fetched anything since ") + Fmt.time(f) + "."
        }
        return nil
    }

    // MARK: Larm

    func config(for plug: Plug) -> WatchConfig { watch[plug.id] ?? .default(for: plug.name) }

    func configBinding(for plug: Plug) -> Binding<WatchConfig> {
        Binding(get: { self.config(for: plug) }, set: { self.setConfig($0, for: plug.id) })
    }

    // MARK: På och av

    func setSwitch(_ plug: Plug, on: Bool) async {
        switching.insert(plug.id)
        defer { switching.remove(plug.id) }
        do {
            try await client.setSwitch(plug.id, on: on)
            if let i = plugs.firstIndex(where: { $0.id == plug.id }) { plugs[i] = plugs[i].with(isOn: on) }
        } catch {
            self.error = (on ? L.t("Kunde inte slå på ", "Couldn't switch on ") : L.t("Kunde inte slå av ", "Couldn't switch off "))
                + plug.name + ": " + error.localizedDescription
        }
    }

    /// Visar ändringen direkt och sparar den i molnet när man slutat klicka en stund.
    private func setConfig(_ c: WatchConfig, for id: String) {
        watch[id] = c
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                try await client.saveWatch(id, c)
            } catch {
                self.error = L.t("Kunde inte spara larminställningen: ", "Couldn't save the alarm setting: ") + error.localizedDescription
            }
            if !Task.isCancelled { pendingSaves[id] = nil }
        }
    }

    /// Molnet larmar till telefonen via ntfy. Appen visar samma larm som notiser på Macen.
    private func notifyTransitions() {
        for p in plugs {
            guard let s = status[p.id] else { continue }
            let cfg = config(for: p)
            transition("\(p.id)|idle", active: s.idleAlarm,
                       alarm: (L.t("\(p.name): ingen ström", "\(p.name): no power"),
                               L.t("Har inte dragit över \(Fmt.watts(cfg.minWatts)) sedan \(Fmt.time(s.idleSince ?? Date())). Kontrollera frysen.",
                                   "Hasn't drawn more than \(Fmt.watts(cfg.minWatts)) since \(Fmt.time(s.idleSince ?? Date())). Check the freezer.")),
                       recovered: (L.t("\(p.name) drar ström igen", "\(p.name) is drawing power again"),
                                   L.t("Just nu \(Fmt.watts(p.power)).", "Currently \(Fmt.watts(p.power)).")))
            transition("\(p.id)|offline", active: s.offlineAlarm,
                       alarm: (L.t("\(p.name) är offline", "\(p.name) is offline"),
                               L.t("Ingen kontakt sedan \(Fmt.time(s.offlineSince ?? Date())). Strömavbrott, utlöst säkring eller nätverket på torpet?",
                                   "No contact since \(Fmt.time(s.offlineSince ?? Date())). Power cut, tripped fuse or the network at the cottage?")),
                       recovered: (L.t("\(p.name) är online igen", "\(p.name) is back online"), ""))
        }
        UserDefaults.standard.set(Array(notified), forKey: "notified")
    }

    private func transition(_ key: String, active: Bool, alarm: (String, String), recovered: (String, String)) {
        if active && !notified.contains(key) {
            notified.insert(key)
            Notifier.shared.send(title: alarm.0, body: alarm.1)
        } else if !active && notified.contains(key) {
            notified.remove(key)
            Notifier.shared.send(title: recovered.0, body: recovered.1)
        }
    }

    var anyAlarm: Bool { status.values.contains { $0.idleAlarm || $0.offlineAlarm } }

    // MARK: Diagram

    /// Värde för `chartPlugID` som visar alla pluggar med elmätare i samma diagram.
    static let allPlugs = "*all*"

    var chartShowsAll: Bool { chartPlugID == Self.allPlugs }

    /// Pluggarna som diagrammet visar just nu.
    var chartPlugIDs: [String] {
        guard let id = chartPlugID else { return [] }
        return id == Self.allPlugs ? plugs.filter(\.hasMeter).map(\.id) : [id]
    }

    /// Larmgränsen för diagrammet. Bara när en plugg visas, eftersom pluggarna kan ha olika gränser.
    var chartConfig: WatchConfig? {
        guard !chartShowsAll, let id = chartPlugID, let p = plugs.first(where: { $0.id == id }) else { return nil }
        return config(for: p)
    }

    func loadChart() async {
        let ids = chartPlugIDs
        guard !ids.isEmpty else { return }
        chartLoading = true
        defer { chartLoading = false }
        for id in ids { await loadChart(id) }
    }

    /// Hämtar bara det som saknas: nya mätningar sedan förra gången, eller äldre om tidsspannet blivit längre.
    private func loadChart(_ id: String) async {
        let from = Date().addingTimeInterval(-chartSpan.seconds)
        let have = chartSamples[id] ?? []
        // Redan hämtat från `from` eller tidigare: bara det nya behövs.
        let last = chartFrom[id].flatMap { $0 <= from ? have.last : nil }
        do {
            if let last {
                let weekAgo = Date().addingTimeInterval(-ChartSpan.week.seconds)
                chartSamples[id] = (have + (try await client.samples(device: id, since: last.date.addingTimeInterval(1))))
                    .filter { $0.date >= weekAgo }
            } else {
                chartSamples[id] = try await client.samples(device: id, since: from)
                chartFrom[id] = from
            }
        } catch {
            // Diagrammet är inte viktigt nog för ett felmeddelande; det försöker igen vid nästa hämtning.
        }
    }

    func chartPoints(now: Date = Date()) -> [ChartPoint] {
        chartPlugIDs.flatMap { chartPoints(for: $0, now: now) }
    }

    private func chartPoints(for id: String, now: Date) -> [ChartPoint] {
        let name = plugs.first { $0.id == id }?.name ?? id
        let from = now.addingTimeInterval(-chartSpan.seconds)
        var out: [ChartPoint] = []
        var segment = 0
        var prev: Date?
        for s in chartSamples[id] ?? [] where s.date >= from {
            guard s.online, let w = s.power else { prev = nil; continue }
            if !out.isEmpty && (prev == nil || s.date.timeIntervalSince(prev!) > Alarm.maxGap) { segment += 1 }
            out.append(ChartPoint(plugID: id, plugName: name, date: s.date, power: w, segment: segment))
            prev = s.date
        }
        return out
    }

    // MARK: Menyraden

    var menuTitle: String {
        if plugs.isEmpty { return needsSetup ? "Torpet –" : "Torpet …" }
        let alarmed = plugs.filter { status[$0.id]?.idleAlarm == true || status[$0.id]?.offlineAlarm == true }
        if !alarmed.isEmpty { return alarmed.map(\.name).joined(separator: ", ") }
        let watched = plugs.filter { config(for: $0).enabled && $0.hasMeter }
        if !watched.isEmpty { return watched.map { Fmt.watts($0.online ? $0.power : nil) }.joined(separator: "  ") }
        return Fmt.watts(plugs.filter(\.online).compactMap(\.power).reduce(0, +))
    }

    // MARK: Inställningar

    /// Ett tomt `apiKey` behåller den sparade nyckeln.
    func saveCloud(url: String, apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = await client.current?.apiKey ?? ""
        let c = CloudConfig(url: url.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key.isEmpty ? old : key)
        do {
            try await client.configure(c)
            needsSetup = false
            showSettings = false
            lastRefresh = nil
            await refresh()
            if error != nil { showSettings = true }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Testnotis här på Macen, och via molnet till ntfy på telefonen.
    func testNotification() async {
        Notifier.shared.send(title: "Torpet El", body: L.t("Så här ser ett larm ut.", "This is what an alarm looks like."))
        do {
            try await client.test()
        } catch {
            self.error = L.t("Testlarmet till telefonen gick inte iväg: ", "The test alarm to the phone failed: ") + error.localizedDescription
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self.error = L.t("Kunde inte ändra start vid inloggning: ", "Couldn't change launch at login: ") + error.localizedDescription
            }
            objectWillChange.send()
        }
    }
}
