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

/// What the chart shows: the freezers' power, or the heat pump's temperatures or energy.
enum ChartKind: String, CaseIterable, Identifiable, Sendable {
    case power, temperature, energy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .power: L.t("Effekt", "Power")
        case .temperature: L.t("Temperatur", "Temperature")
        case .energy: L.t("Energi", "Energy")
        }
    }
}

struct TempPoint: Identifiable, Sendable {
    let date: Date
    let room: Double
    let set: Double?
    /// New part after a gap, so the line isn't drawn across time without readings.
    let segment: Int
    var id: Date { date }
}

/// A stretch where the heat pump was on, shaded in the temperature chart.
struct RunBand: Identifiable, Sendable {
    let id: Int
    let start: Date
    let end: Date
    let mode: String?
}

struct EnergyBucket: Identifiable, Sendable {
    /// Whose energy: the heat pump's or a plug's name.
    let source: String
    let date: Date
    let kwh: Double
    var id: String { "\(source)|\(date.timeIntervalSince1970)" }
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
    @Published var chartKind: ChartKind = .power { didSet { if chartKind != oldValue { Task { await loadChart() } } } }
    @Published private(set) var heatPumps: [HeatPump] = []
    @Published private(set) var heatPumpFetchedAt: Date?
    @Published private(set) var heatPumpError: String?
    @Published private(set) var heatWatch: [String: HeatWatch] = [:]
    @Published private(set) var heatPumpNoData = false
    private var pendingHeatSaves: [String: Task<Void, Never>] = [:]
    @Published private(set) var heatSamples: [HeatSample] = []
    @Published private(set) var energyHours: [EnergyHour] = []
    /// kWh used since midnight, for the heat pump card.
    @Published private(set) var energyToday: Double?
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
            heatPumps = snap.heatPumps ?? []
            heatPumpFetchedAt = snap.heatPumpFetchedAt.map { Date(timeIntervalSince1970: $0) }
            heatPumpError = heatPumpProblem(snap)
            heatPumpNoData = snap.heatPumpNoData ?? false
            var hw: [String: HeatWatch] = [:]
            for p in heatPumps {
                // As for the plugs: a change that hasn't been saved yet isn't overwritten by the cloud's older value.
                hw[p.id] = pendingHeatSaves[p.id] != nil ? heatWatch[p.id] : (p.watch ?? .default)
            }
            heatWatch = hw
            if heatPumps.isEmpty {
                chartKind = .power
            } else if !plugs.contains(where: \.hasMeter), chartKind == .power {
                chartKind = .temperature
            }
            await loadEnergyToday()

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

    /// The refresh button: the cloud first fetches from Tuya, then the app reads what it got. If the cloud can't be
    /// asked (an older version without the route, say), the app still shows what the cloud has.
    func refreshNow() async {
        guard await client.isConfigured, !isLoading else { return }
        isLoading = true
        try? await client.fetchNow()
        isLoading = false
        lastRefresh = nil
        await refresh()
    }

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

    private func heatPumpProblem(_ snap: CloudSnapshot) -> String? {
        if let e = snap.heatPumpError {
            let since = snap.heatPumpFailingSince.map { L.t(" sedan ", " since ") + Fmt.time(Date(timeIntervalSince1970: $0)) } ?? ""
            return L.t("Molnet får inget svar från MELCloud", "The cloud gets no answer from MELCloud") + since + ": " + e
        }
        if !heatPumps.isEmpty, let f = heatPumpFetchedAt, Date().timeIntervalSince(f) > Self.stale {
            return L.t("Värmepumpen har inte lästs av sedan ", "The heat pump hasn't been read since ") + Fmt.time(f) + "."
        }
        return nil
    }

    // MARK: Larm

    func config(for plug: Plug) -> WatchConfig { watch[plug.id] ?? .default(for: plug.name) }

    func configBinding(for plug: Plug) -> Binding<WatchConfig> {
        Binding(get: { self.config(for: plug) }, set: { self.setConfig($0, for: plug.id) })
    }

    func heatWatch(for pump: HeatPump) -> HeatWatch { heatWatch[pump.id] ?? pump.watch ?? .default }

    func heatWatchBinding(for pump: HeatPump) -> Binding<HeatWatch> {
        Binding(get: { self.heatWatch(for: pump) }, set: { self.setHeatWatch($0, for: pump.id) })
    }

    private func setHeatWatch(_ w: HeatWatch, for id: String) {
        var w = w
        // The warning is the step before the alarm, so it never sits below it.
        w.warnC = max(w.warnC, w.lowC)
        heatWatch[id] = w
        pendingHeatSaves[id]?.cancel()
        pendingHeatSaves[id] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                try await client.saveHeatWatch(id, w)
            } catch {
                self.error = L.t("Kunde inte spara värmepumpens larm: ", "Couldn't save the heat pump alarms: ") + error.localizedDescription
            }
            if !Task.isCancelled { pendingHeatSaves[id] = nil }
        }
    }

    // MARK: Värmepumpens styrning

    @Published private(set) var heatBusy: Set<String> = []
    /// A target temperature that has been dialled in but not sent yet.
    @Published private(set) var heatTarget: [String: Double] = [:]
    @Published private(set) var frostDraft: [String: HeatPump.Frost] = [:]
    private var pendingTarget: [String: Task<Void, Never>] = [:]
    private var pendingFrost: [String: Task<Void, Never>] = [:]

    func heatTargetValue(_ p: HeatPump) -> Double { heatTarget[p.id] ?? p.set ?? 20 }

    /// Shows the new value at once and sends it when the clicking has stopped for a moment.
    func setHeatTarget(_ p: HeatPump, _ value: Double) {
        heatTarget[p.id] = value
        pendingTarget[p.id]?.cancel()
        pendingTarget[p.id] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await heatChange(p, errorText: L.t("Kunde inte ändra måltemperaturen: ", "Couldn't change the target temperature: ")) {
                try await $0.heatSet(p.id, HeatCommand(setTemperature: value))
            }
            if !Task.isCancelled { heatTarget[p.id] = nil; pendingTarget[p.id] = nil }
        }
    }

    func sendHeat(_ p: HeatPump, _ command: HeatCommand) async {
        await heatChange(p, errorText: L.t("Kunde inte styra värmepumpen: ", "Couldn't control the heat pump: ")) {
            try await $0.heatSet(p.id, command)
        }
    }

    func frostValue(_ p: HeatPump) -> HeatPump.Frost {
        frostDraft[p.id] ?? p.frost ?? HeatPump.Frost(isEnabled: false, min: 10, max: 12)
    }

    /// Frost protection keeps at least 2 °C between its two limits.
    func setFrost(_ p: HeatPump, _ f: HeatPump.Frost, changedMax: Bool = false) {
        var f = f
        if f.max < f.min + 2 { if changedMax { f.min = f.max - 2 } else { f.max = f.min + 2 } }
        frostDraft[p.id] = f
        pendingFrost[p.id]?.cancel()
        pendingFrost[p.id] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await heatChange(p, errorText: L.t("Kunde inte ändra frostskyddet: ", "Couldn't change frost protection: ")) {
                try await $0.heatFrost(p.id, f)
            }
            if !Task.isCancelled { frostDraft[p.id] = nil; pendingFrost[p.id] = nil }
        }
    }

    func setHoliday(_ p: HeatPump, enabled: Bool, start: Date = Date(), end: Date = Date()) async {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Stockholm")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        await heatChange(p, errorText: L.t("Kunde inte ändra semesterläget: ", "Couldn't change holiday mode: ")) {
            try await $0.heatHoliday(p.id, enabled: enabled, start: f.string(from: start), end: f.string(from: end))
        }
    }

    /// Runs a write and puts the unit's new state in place of the old one, keeping the cloud's alarm settings and status.
    private func heatChange(_ p: HeatPump, errorText: String, _ write: (CloudClient) async throws -> HeatPump) async {
        heatBusy.insert(p.id)
        defer { heatBusy.remove(p.id) }
        do {
            var latest = try await write(client)
            if let i = heatPumps.firstIndex(where: { $0.id == p.id }) {
                latest.watch = heatPumps[i].watch
                latest.status = heatPumps[i].status
                heatPumps[i] = latest
            }
        } catch {
            self.error = errorText + error.localizedDescription
        }
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
        for p in heatPumps {
            guard let s = p.status else { continue }
            let room = Fmt.temp(p.room)
            transition("\(p.id)|cold", active: s.coldAlarm == true,
                       alarm: (L.t("\(p.name): kallt på torpet", "\(p.name): cold at the cottage"),
                               L.t("\(room) sedan \(Fmt.time(s.coldSince.map { Date(timeIntervalSince1970: $0) } ?? Date())). Vattenrören kan frysa.",
                                   "\(room) since \(Fmt.time(s.coldSince.map { Date(timeIntervalSince1970: $0) } ?? Date())). The water pipes may freeze.")),
                       recovered: (L.t("\(p.name): varmare igen", "\(p.name): warming up again"), L.t("Just nu \(room).", "Currently \(room).")))
            // The warning has no follow-up: it just gives way to the alarm or to a warm room.
            let coolKey = "\(p.id)|cool"
            if s.coolWarning == true {
                if !notified.contains(coolKey) {
                    notified.insert(coolKey)
                    Notifier.shared.send(title: L.t("\(p.name): svalnar", "\(p.name): getting cool"), body: room)
                }
            } else {
                notified.remove(coolKey)
            }
            transition("\(p.id)|error", active: s.errorAlarm == true,
                       alarm: (L.t("\(p.name): fel", "\(p.name): fault"), p.error ?? L.t("Värmepumpen rapporterar ett fel.", "The heat pump reports a fault.")),
                       recovered: (L.t("\(p.name): felet är borta", "\(p.name): the fault is gone"), ""))
            transition("\(p.id)|offline", active: s.offlineAlarm == true,
                       alarm: (L.t("\(p.name) är offline", "\(p.name) is offline"),
                               L.t("Rumstemperaturen går inte att se. Wi-Fi eller strömmen på torpet?", "The room temperature can't be seen. Wi-Fi or power at the cottage?")),
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

    var anyAlarm: Bool {
        status.values.contains { $0.idleAlarm || $0.offlineAlarm } || heatPumpNoData
            || heatPumps.contains { $0.hasError || $0.status?.coldAlarm == true || $0.status?.offlineAlarm == true }
    }

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

    /// The heat pump the temperature and energy charts show.
    var chartHeat: HeatPump? { heatPumps.first }

    func loadChart() async {
        if chartKind != .power, let hp = chartHeat {
            chartLoading = true
            defer { chartLoading = false }
            let from = Date().addingTimeInterval(-chartSpan.seconds)
            do {
                if chartKind == .temperature {
                    heatSamples = try await client.heatSamples(unit: hp.id, since: from)
                } else {
                    energyHours = try await client.heatEnergy(unit: hp.id, since: from)
                    // The plugs' energy is worked out from their power readings.
                    for p in plugs where p.hasMeter { await loadChart(p.id) }
                }
            } catch {
                // As for the power chart: it tries again at the next refresh.
            }
            return
        }
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

    private func loadEnergyToday() async {
        guard let hp = chartHeat else { energyToday = nil; return }
        let midnight = Calendar.current.startOfDay(for: Date())
        if let hours = try? await client.heatEnergy(unit: hp.id, since: midnight) {
            energyToday = hours.reduce(0) { $0 + $1.kwh }
        }
    }

    /// Room temperature and setpoint as lines, split where the readings have gaps, plus the stretches where the unit ran.
    func heatSeries(now: Date = Date()) -> (points: [TempPoint], bands: [RunBand]) {
        let from = now.addingTimeInterval(-chartSpan.seconds)
        var points: [TempPoint] = []
        var bands: [RunBand] = []
        var segment = 0
        var prev: Date?
        var open: (start: Date, mode: String?)?
        func close(at end: Date) {
            if let o = open { bands.append(RunBand(id: bands.count, start: o.start, end: end, mode: o.mode)) }
            open = nil
        }
        for s in heatSamples where s.date >= from {
            if let p = prev, s.date.timeIntervalSince(p) > Alarm.maxGap {
                close(at: p)
                segment += 1
            }
            prev = s.date
            if let r = s.room { points.append(TempPoint(date: s.date, room: r, set: s.set, segment: segment)) }
            if s.power == true {
                if open == nil { open = (s.date, s.mode) }
            } else {
                close(at: s.date)
            }
        }
        if let p = prev { close(at: p) }
        return (points, bands)
    }

    /// The heat pump's measured energy and the metered plugs' estimated energy, per hour or per day for the week view.
    func energyBuckets(now: Date = Date()) -> [EnergyBucket] {
        let from = now.addingTimeInterval(-chartSpan.seconds)
        let cal = Calendar.current
        let step: Calendar.Component = chartSpan == .week ? .day : .hour
        func start(_ d: Date) -> Date { cal.dateInterval(of: step, for: d)?.start ?? d }
        var sums: [String: [Date: Double]] = [:]
        if let hp = chartHeat {
            for h in energyHours where h.date >= from { sums[hp.name, default: [:]][start(h.date), default: 0] += h.kwh }
        }
        for p in plugs where p.hasMeter {
            for (date, kwh) in Self.plugEnergy(chartSamples[p.id] ?? [], until: now) where date >= from {
                sums[p.name, default: [:]][start(date), default: 0] += kwh
            }
        }
        // Swift Charts stacks the first source at the bottom. Ordered by their total over the period, the biggest one
        // is at the bottom and the smallest on top, the same in every bar.
        return sums.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
            .flatMap { source, byTime in
                byTime.sorted { $0.key < $1.key }.map { EnergyBucket(source: source, date: $0.key, kwh: $0.value) }
            }
    }

    /// Estimated kWh per reading: each power reading stands for the time until the next one, at most 10 minutes.
    /// Readings where the plug was offline or gave no power count as nothing.
    private static func plugEnergy(_ samples: [Sample], until now: Date) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        for (i, s) in samples.enumerated() {
            guard s.online, let w = s.power else { continue }
            let next = i + 1 < samples.count ? samples[i + 1].date : now
            let seconds = min(max(next.timeIntervalSince(s.date), 0), 600)
            out.append((s.date, w * seconds / 3_600_000))
        }
        return out
    }

    /// Sources in the energy chart, in a fixed order so their colors don't move: the heat pump first, then the plugs.
    var energySources: [String] {
        (chartHeat.map { [$0.name] } ?? []) + plugs.filter(\.hasMeter).map(\.name)
    }

    // MARK: Menyraden

    /// The cottage's temperature after the freezers' watts, or a warning if the heat pump reports a fault.
    private var heatTitle: String {
        guard let hp = heatPumps.first else { return "" }
        if hp.hasError { return "⚠ " + hp.name }
        if hp.status?.coldAlarm == true { return "⚠ " + Fmt.temp(hp.room, unit: false) }
        guard let f = heatPumpFetchedAt, Date().timeIntervalSince(f) <= Self.stale, let room = hp.room else { return "" }
        return Fmt.temp(room, unit: false)
    }

    var menuTitle: String {
        [plugTitle, heatTitle].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    private var plugTitle: String {
        if plugs.isEmpty {
            if !heatPumps.isEmpty { return "" }
            return needsSetup ? "Torpet –" : "Torpet …"
        }
        let alarmed = plugs.filter { status[$0.id]?.idleAlarm == true || status[$0.id]?.offlineAlarm == true }
        if !alarmed.isEmpty { return alarmed.map(\.name).joined(separator: ", ") }
        // Bara frysar som går just nu visar watt; står alla still syns bara blixten.
        let watched = plugs.filter { config(for: $0).enabled && $0.hasMeter }
        if !watched.isEmpty {
            return watched
                .filter { $0.online && ($0.power ?? 0) >= config(for: $0).minWatts }
                .map { Fmt.watts($0.power) }
                .joined(separator: "  ")
        }
        let total = plugs.filter(\.online).compactMap(\.power).reduce(0, +)
        return total > 0 ? Fmt.watts(total) : ""
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
