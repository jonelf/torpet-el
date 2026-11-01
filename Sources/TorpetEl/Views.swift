import Charts
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: PlugStore
    @State private var contentHeight: CGFloat = 0
    /// Så högt som skärmen tillåter, med plats för rubrik och sidfot.
    private var maxHeight: CGFloat { max((NSScreen.main?.visibleFrame.height ?? 800) - 140, 300) }

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store)
            Divider()
            // En ScrollView i menyradsfönstret saknar egen höjd och krymper till noll, så höjden mäts.
            ScrollView {
                content.padding(14)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: HeightKey.self, value: g.size.height)
                    })
            }
            .frame(height: min(max(contentHeight, 60), maxHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            Divider()
            Footer(store: store)
        }
        .frame(width: 420)
        .id(store.language)   // ritar om allt när språket byts
        .task { await store.refresh(ifOlderThan: 60) }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.notificationsAllowed == false {
                Label(L.t("Notiser är avstängda för Torpet El. Slå på dem i Systeminställningar → Notiser, annars syns larmen bara här.",
                          "Notifications are off for Torpet El. Turn them on in System Settings → Notifications, or alarms only show here."),
                      systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.showSettings || store.needsSetup {
                SettingsView(store: store)
            } else if store.plugs.isEmpty {
                if store.fetchedAt != nil {
                    Text(L.t("Inga enheter hittades. Kontrollera att Smart Life-kontot är länkat till molnprojektet (Devices → Link App Account).",
                             "No devices found. Check that the Smart Life account is linked to the cloud project (Devices → Link App Account)."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
                }
            } else {
                ForEach(store.plugs) { PlugCard(store: store, plug: $0) }
                PowerChart(store: store)
            }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct Header: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Torpet El").font(.headline)
                if !store.plugs.isEmpty {
                    let watched = store.plugs.filter { store.config(for: $0).enabled }.count
                    Text(L.t("\(store.plugs.count) pluggar · \(watched) bevakas", "\(store.plugs.count) plugs · \(watched) watched"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).help(L.t("Hämta nu", "Refresh now"))
            Button { store.showSettings.toggle() } label: {
                Image(systemName: store.showSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.borderless).help(L.t("Inställningar", "Settings"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct Footer: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        HStack {
            if let f = store.fetchedAt {
                Text(L.t("Mätt ", "Measured ") + Fmt.ago(f) + L.t(" · var 5:e minut i molnet", " · every 5 minutes in the cloud"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L.t("Avsluta", "Quit")) { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Pluggar

private struct PlugCard: View {
    @ObservedObject var store: PlugStore
    let plug: Plug
    @State private var editing = false
    @State private var confirmOff = false

    var body: some View {
        let cfg = store.config(for: plug)
        let st = store.status[plug.id]
        let alarm = st?.idleAlarm == true || st?.offlineAlarm == true
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(plug.name, systemImage: cfg.enabled ? "bell.fill" : "powerplug")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !plug.online {
                    Label("Offline", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
                } else if let on = plug.isOn {
                    let busy = store.switching.contains(plug.id)
                    if busy { ProgressView().controlSize(.mini) }
                    Toggle(on ? L.t("På", "On") : L.t("Av", "Off"), isOn: Binding(get: { on }, set: { new in
                        // En bevakad plugg är oftast en frys, så den slås inte av med ett felklick.
                        if !new && cfg.enabled { confirmOff = true } else { Task { await store.setSwitch(plug, on: new) } }
                    }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .foregroundStyle(on ? Color.green : Color.secondary)
                    .disabled(busy)
                    .help(on ? L.t("Slå av", "Switch off") : L.t("Slå på", "Switch on"))
                }
                Button { editing.toggle() } label: {
                    Image(systemName: editing ? "chevron.up" : "slider.horizontal.3")
                }
                .buttonStyle(.borderless).help(L.t("Larminställningar", "Alarm settings"))
            }
            if plug.hasMeter {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.watts(plug.power))
                        .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(plug.online ? Color.primary : Color.secondary)
                    Text([plug.voltage.map { Fmt.num($0, decimals: 0) + " V" },
                          plug.current.map { Fmt.num($0, decimals: 2) + " A" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text(L.t("Ingen elmätning", "No power metering")).font(.caption).foregroundStyle(.secondary)
            }
            if cfg.enabled, let st { StatusLine(status: st, config: cfg, hasMeter: plug.hasMeter) }
            if editing { WatchEditor(config: store.configBinding(for: plug), hasMeter: plug.hasMeter) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alarm ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 8))
        .alert(L.t("Slå av \(plug.name)?", "Switch off \(plug.name)?"), isPresented: $confirmOff) {
            Button(L.t("Slå av", "Switch off"), role: .destructive) { Task { await store.setSwitch(plug, on: false) } }
            Button(L.t("Avbryt", "Cancel"), role: .cancel) {}
        } message: {
            Text(L.t("Pluggen bevakas. Står den avslagen larmar det efter \(Fmt.hours(cfg.hours)).",
                     "This plug is watched. If it stays off, the alarm goes off after \(Fmt.hours(cfg.hours))."))
        }
    }
}

private struct StatusLine: View {
    let status: AlarmStatus
    let config: WatchConfig
    let hasMeter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.offlineAlarm, let s = status.offlineSince {
                Label(L.t("Offline sedan ", "Offline since ") + Fmt.time(s), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if status.idleAlarm, let s = status.idleSince {
                Label(L.t("Ingen ström sedan ", "No power since ") + Fmt.time(s), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var summary: String {
        var parts: [String] = []
        if hasMeter {
            parts.append(L.t("Larm under ", "Alarm below ") + Fmt.watts(config.minWatts) + L.t(" i ", " for ") + Fmt.hours(config.hours))
            if let a = status.lastActive { parts.append(L.t("senast ström ", "last drew power ") + Fmt.time(a)) }
        }
        if config.offlineAlarm {
            parts.append(L.t("offline-larm efter ", "offline alarm after ") + Fmt.duration(config.offlineMinutes * 60))
        }
        if !status.fresh { parts.append(L.t("väntar på färska mätningar", "waiting for fresh readings")) }
        return parts.joined(separator: " · ")
    }
}

private struct WatchEditor: View {
    @Binding var config: WatchConfig
    let hasMeter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle(L.t("Bevaka den här pluggen", "Watch this plug"), isOn: $config.enabled)
            if config.enabled {
                if hasMeter {
                    Stepper(value: $config.minWatts, in: 1...500, step: 1) {
                        Text(L.t("Räknas som strömlös under ", "Counts as no power below ") + Fmt.watts(config.minWatts))
                    }
                    Stepper(value: $config.hours, in: 0.5...48, step: 0.5) {
                        Text(L.t("Larma efter ", "Alarm after ") + Fmt.hours(config.hours) + L.t(" utan ström", " without power"))
                    }
                }
                Toggle(L.t("Larma om den går offline", "Alarm when it goes offline"), isOn: $config.offlineAlarm)
                if config.offlineAlarm {
                    Stepper(value: $config.offlineMinutes, in: 10...360, step: 10) {
                        Text(L.t("Offline-larm efter ", "Offline alarm after ") + Fmt.duration(config.offlineMinutes * 60))
                    }
                }
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Diagram

private struct PowerChart: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        let metered = store.plugs.filter(\.hasMeter)
        if !metered.isEmpty {
            let pts = store.chartPoints()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.t("Effekt", "Power")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("", selection: $store.chartPlugID) {
                        if metered.count > 1 {
                            Text(L.t("Alla", "All")).tag(Optional(PlugStore.allPlugs))
                            Divider()
                        }
                        ForEach(metered) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
                Picker("", selection: $store.chartSpan) {
                    ForEach(ChartSpan.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                ZStack {
                    chart(pts, plugs: metered).frame(height: store.chartShowsAll ? 180 : 160)
                    if pts.isEmpty {
                        if store.chartLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L.t("Ingen data än. Molnet sparar en mätning var 5:e minut.",
                                     "No data yet. The cloud saves a reading every 5 minutes."))
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                }
                if !pts.isEmpty { summary(pts) }
            }
        }
    }

    /// Färger för "Alla", i pluggarnas ordning. Orange först, som när en plugg visas ensam.
    private static let colors: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .brown]

    private func chart(_ pts: [ChartPoint], plugs: [Plug]) -> some View {
        let now = Date()
        let limit = store.chartConfig.flatMap { $0.enabled ? $0.minWatts : nil }
        let names = plugs.map(\.name)
        return Chart {
            ForEach(pts) { p in
                if store.chartShowsAll {
                    LineMark(x: .value("Tid", p.date), y: .value("W", p.power), series: .value("Del", p.series))
                        .foregroundStyle(by: .value(L.t("Plugg", "Plug"), p.plugName))
                } else {
                    LineMark(x: .value("Tid", p.date), y: .value("W", p.power), series: .value("Del", p.series))
                        .foregroundStyle(.orange)
                }
            }
            if let limit {
                RuleMark(y: .value(L.t("Gräns", "Limit"), limit))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(domain: names, range: names.indices.map { Self.colors[$0 % Self.colors.count] })
        .chartLegend(store.chartShowsAll ? .visible : .hidden)
        .chartXScale(domain: now.addingTimeInterval(-store.chartSpan.seconds)...now)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel(collisionResolution: .greedy) {
                    if let d = v.as(Date.self) { Text(axisLabel(d)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.num(d, decimals: 0) + " W") } }
            }
        }
    }

    private func axisLabel(_ d: Date) -> String {
        store.chartSpan == .week
            ? d.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.locale))
            : d.formatted(.dateTime.hour().minute().locale(Fmt.locale))
    }

    /// Min, max och medel, och hur stor del av mätningarna som låg över gränsen (för en frys: hur mycket kompressorn går).
    private func summary(_ pts: [ChartPoint]) -> some View {
        if store.chartShowsAll {
            // Medel per plugg; min och max säger lite när kurvorna ligger i samma diagram.
            let parts = Dictionary(grouping: pts, by: \.plugName)
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, ps in "\(name) " + L.t("medel ", "average ") + Fmt.watts(ps.map(\.power).reduce(0, +) / Double(ps.count)) }
            return Text(parts.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        let values = pts.map(\.power)
        let avg = values.reduce(0, +) / Double(values.count)
        var parts = ["Min \(Fmt.watts(values.min()))", "Max \(Fmt.watts(values.max()))", L.t("Medel ", "Average ") + Fmt.watts(avg)]
        if let cfg = store.chartConfig, cfg.enabled {
            let share = Double(values.filter { $0 >= cfg.minWatts }.count) / Double(values.count) * 100
            parts.append(L.t("igång \(Int(share.rounded())) %", "running \(Int(share.rounded())) %"))
        }
        return Text(parts.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

// MARK: - Inställningar

struct SettingsView: View {
    @ObservedObject var store: PlugStore
    @State private var url = ""
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("Molnet", "Cloud")).font(.subheadline.weight(.semibold))
            Text(L.t("Lambda-funktionen i AWS hämtar från Tuya och larmar till telefonen via ntfy. Adressen skrivs ut av cloud/deploy.sh och nyckeln av cloud/setup-params.sh.",
                     "The Lambda function in AWS fetches from Tuya and sends alarms to the phone through ntfy. cloud/deploy.sh prints the URL and cloud/setup-params.sh the key."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L.t("Adress (https://…lambda-url…)", "URL (https://…lambda-url…)"), text: $url)
            SecureField(hasKey ? L.t("API-nyckel (sparad)", "API key (saved)") : L.t("API-nyckel", "API key"), text: $apiKey)
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(L.t("Spara", "Save")) {
                    saving = true
                    Task {
                        await store.saveCloud(url: url, apiKey: apiKey)
                        apiKey = ""
                        hasKey = await store.client.current != nil
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || (apiKey.isEmpty && !hasKey) || saving)
            }
            Divider()
            Picker(L.t("Språk", "Language"), selection: $store.language) {
                ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(L.t("Starta vid inloggning", "Launch at login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
            HStack {
                Text(L.t("Larmen kommer som notiser här och i ntfy på telefonen.", "Alarms arrive as notifications here and in ntfy on the phone."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L.t("Testa larm", "Test alarm")) { Task { await store.testNotification() } }.font(.caption)
            }
            Text(L.t("Adressen och nyckeln sparas i ", "The URL and key are stored in ") + CloudStore.url.path(percentEncoded: false)
                 + L.t(". Mätningarna sparas i AWS i 90 dagar.", ". Readings are kept in AWS for 90 days."))
                .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .task {
            if let c = await store.client.current {
                url = c.url
                hasKey = true
            }
        }
    }
}
