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
            } else if store.plugs.isEmpty && store.heatPumps.isEmpty {
                if store.fetchedAt != nil {
                    Text(L.t("Inga enheter hittades. Kontrollera att Smart Life-kontot är länkat till molnprojektet (Devices → Link App Account).",
                             "No devices found. Check that the Smart Life account is linked to the cloud project (Devices → Link App Account)."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
                }
            } else {
                PlugSection(store: store)
                if store.heatPumps.isEmpty, let e = store.heatPumpError {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.heatPumps) { HeatPumpCard(store: store, pump: $0) }
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

/// The switch of a plug. Switching off a watched plug (usually a freezer) asks first, so a misclick can't turn it off.
private struct PlugToggle: View {
    @ObservedObject var store: PlugStore
    let plug: Plug
    @State private var confirmOff = false

    var body: some View {
        let cfg = store.config(for: plug)
        if !plug.online {
            Label("Offline", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
        } else if let on = plug.isOn {
            let busy = store.switching.contains(plug.id)
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini) }
                Toggle(on ? L.t("På", "On") : L.t("Av", "Off"), isOn: Binding(get: { on }, set: { new in
                    if !new && cfg.enabled { confirmOff = true } else { Task { await store.setSwitch(plug, on: new) } }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(busy)
                .help(on ? L.t("Slå av", "Switch off") : L.t("Slå på", "Switch on"))
            }
            .alert(L.t("Slå av \(plug.name)?", "Switch off \(plug.name)?"), isPresented: $confirmOff) {
                Button(L.t("Slå av", "Switch off"), role: .destructive) { Task { await store.setSwitch(plug, on: false) } }
                Button(L.t("Avbryt", "Cancel"), role: .cancel) {}
            } message: {
                Text(L.t("Pluggen bevakas. Står den avslagen larmar det efter \(Fmt.hours(cfg.hours)).",
                         "This plug is watched. If it stays off, the alarm goes off after \(Fmt.hours(cfg.hours))."))
            }
        }
    }
}

/// Watched plugs (the freezers) as tiles side by side, the rest as one line each. The alarm settings of the plug
/// being edited open below, across the full width, so a narrow tile never has to hold them.
private struct PlugSection: View {
    @ObservedObject var store: PlugStore
    @State private var editing: String?

    var body: some View {
        let watched = store.plugs.filter { store.config(for: $0).enabled }
        let others = store.plugs.filter { !store.config(for: $0).enabled }
        VStack(spacing: 10) {
            if !watched.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 10) {
                    ForEach(watched) { FreezerTile(store: store, plug: $0, editing: $editing) }
                }
            }
            if !others.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider() }
                        PlugRow(store: store, plug: p, editing: $editing)
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            if let id = editing, let p = store.plugs.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L.t("Larminställningar för ", "Alarm settings for ") + p.name, systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    WatchEditor(config: store.configBinding(for: p), hasMeter: p.hasMeter)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct FreezerTile: View {
    @ObservedObject var store: PlugStore
    let plug: Plug
    @Binding var editing: String?

    var body: some View {
        let cfg = store.config(for: plug)
        let st = store.status[plug.id]
        let alarm = st?.idleAlarm == true || st?.offlineAlarm == true
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill").font(.caption)
                Text(plug.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                PlugToggle(store: store, plug: plug)
                Button { editing = editing == plug.id ? nil : plug.id } label: {
                    Image(systemName: editing == plug.id ? "chevron.up" : "slider.horizontal.3")
                }
                .buttonStyle(.borderless).help(L.t("Larminställningar", "Alarm settings"))
            }
            if plug.hasMeter {
                Text(Fmt.watts(plug.power))
                    .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(plug.online ? Color.primary : Color.secondary)
                Text([plug.voltage.map { Fmt.num($0, decimals: 0) + " V" },
                      plug.current.map { Fmt.num($0, decimals: 2) + " A" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(L.t("Ingen elmätning", "No power metering")).font(.caption).foregroundStyle(.secondary)
            }
            if let st { StatusLine(status: st, config: cfg, hasMeter: plug.hasMeter, compact: true) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alarm ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PlugRow: View {
    @ObservedObject var store: PlugStore
    let plug: Plug
    @Binding var editing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "powerplug").font(.caption).foregroundStyle(.secondary)
            Text(plug.name).font(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            if plug.hasMeter {
                Text(Fmt.watts(plug.power)).font(.subheadline).monospacedDigit()
                    .foregroundStyle(plug.online ? Color.primary : Color.secondary)
            } else {
                Text(L.t("Ingen elmätning", "No power metering")).font(.caption).foregroundStyle(.secondary)
            }
            PlugToggle(store: store, plug: plug)
            Button { editing = editing == plug.id ? nil : plug.id } label: {
                Image(systemName: editing == plug.id ? "chevron.up" : "slider.horizontal.3")
            }
            .buttonStyle(.borderless).help(L.t("Larminställningar", "Alarm settings"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private struct StatusLine: View {
    let status: AlarmStatus
    let config: WatchConfig
    let hasMeter: Bool
    /// In a narrow tile: just the alarm limit, the rest is in the settings.
    var compact = false

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
            if !compact, let a = status.lastActive { parts.append(L.t("senast ström ", "last drew power ") + Fmt.time(a)) }
        }
        if config.offlineAlarm && !compact {
            parts.append(L.t("offline-larm efter ", "offline alarm after ") + Fmt.duration(config.offlineMinutes * 60))
        }
        if !status.fresh { parts.append(L.t("väntar på mätning", "waiting for a reading")) }
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

// MARK: - Värmepump

private struct HeatPumpCard: View {
    @ObservedObject var store: PlugStore
    let pump: HeatPump
    @State private var editing = false
    @State private var confirmOff = false

    /// While frost protection is active MELCloud ignores the target temperature and the mode, so they are not offered.
    private var locked: Bool { pump.frost?.isEnabled == true && pump.frost?.active == true }

    private var alarm: Bool {
        pump.hasError || pump.status?.coldAlarm == true || pump.status?.offlineAlarm == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(pump.name, systemImage: "thermometer.medium").font(.subheadline.weight(.semibold))
                Spacer()
                if !pump.isConnected {
                    Label(L.t("Ingen kontakt", "No contact"), systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange)
                } else if let r = pump.rssi {
                    Image(systemName: "wifi", variableValue: min(max((r + 90) / 40, 0), 1))
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Wi-Fi \(Int(r)) dBm")
                }
                if store.heatBusy.contains(pump.id) { ProgressView().controlSize(.mini) }
                Toggle(pump.isOn ? L.t("På", "On") : L.t("Av", "Off"), isOn: Binding(get: { pump.isOn }, set: { new in
                    // Frost protection is what keeps the pipes safe, so switching off asks first.
                    if !new { confirmOff = true } else { Task { await store.sendHeat(pump, HeatCommand(power: true)) } }
                }))
                .toggleStyle(.switch).controlSize(.mini).font(.caption)
                .foregroundStyle(pump.isOn ? Color.green : Color.secondary)
                .disabled(store.heatBusy.contains(pump.id) || !pump.isConnected)
                Button { editing.toggle() } label: {
                    Image(systemName: editing ? "chevron.up" : "slider.horizontal.3")
                }
                .buttonStyle(.borderless).help(L.t("Larminställningar", "Alarm settings"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.temp(pump.room, unit: false))
                    .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                if pump.isOn {
                    Menu(Fmt.mode(pump.mode)) {
                        ForEach(["Heat", "Cool", "Auto", "Dry", "Fan"], id: \.self) { m in
                            Button(Fmt.mode(m)) { Task { await store.sendHeat(pump, HeatCommand(operationMode: m)) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                    .disabled(store.heatBusy.contains(pump.id) || locked)
                    Spacer()
                    let target = store.heatTargetValue(pump)
                    Stepper(value: Binding(get: { target }, set: { store.setHeatTarget(pump, $0) }),
                            in: (pump.minHeat ?? 10)...(pump.maxHeat ?? 31), step: pump.step ?? 0.5) {
                        Text(L.t("mål ", "target ") + Fmt.temp(target)).font(.caption).monospacedDigit()
                    }
                    .controlSize(.small).fixedSize()
                    .disabled(locked)
                }
            }
            if pump.hasError {
                Label(pump.error ?? L.t("Värmepumpen rapporterar ett fel", "The heat pump reports a fault"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                let w = store.heatWatch(for: pump)
                if let s = pump.status {
                    if s.coldAlarm == true {
                        Label(L.t("Kallt: under \(Fmt.temp(w.lowC)) sedan ", "Cold: below \(Fmt.temp(w.lowC)) since ")
                              + Fmt.time(s.coldSince.map { Date(timeIntervalSince1970: $0) } ?? Date()),
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else if s.coolWarning == true {
                        Label(L.t("Svalnar: under \(Fmt.temp(w.warnC))", "Getting cool: below \(Fmt.temp(w.warnC))"),
                              systemImage: "thermometer.low").foregroundStyle(.orange)
                    }
                    if s.offlineAlarm == true {
                        Label(L.t("Offline, temperaturen syns inte", "Offline, the temperature can't be seen"),
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                if w.enabled {
                    // The alarm limit and today's energy share a line: both are small facts that rarely change.
                    Label(L.t("Larm under \(Fmt.temp(w.lowC)) i \(Fmt.duration(w.minutes * 60))",
                              "Alarm below \(Fmt.temp(w.lowC)) for \(Fmt.duration(w.minutes * 60))")
                          + (store.energyToday.map { " · " + L.t("idag ", "today ") + Fmt.kwh($0) } ?? ""),
                          systemImage: "bell.fill").foregroundStyle(.secondary)
                } else {
                    Label(L.t("Värmepumpens larm är av", "Heat pump alarms are off"), systemImage: "bell.slash").foregroundStyle(.orange)
                    if let e = store.energyToday {
                        Label(L.t("Idag ", "Today ") + Fmt.kwh(e), systemImage: "bolt").foregroundStyle(.secondary)
                    }
                }
                if let f = pump.frost, f.isEnabled {
                    Label(L.t("Frostskydd håller ", "Frost protection holds ") + "\(Fmt.num(f.min, decimals: 0))–\(Fmt.num(f.max, decimals: 0)) °C",
                          systemImage: "snowflake").foregroundStyle(.secondary)
                    if locked {
                        Label(L.t("Frostskyddet styr pumpen, så måltemperaturen går inte att ändra. Stäng av frostskyddet under reglaget för att ändra den.",
                                  "Frost protection is in control, so the target temperature can't be changed. Turn it off under the slider icon to change it."),
                              systemImage: "lock.fill").foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label(L.t("Frostskydd är av", "Frost protection is off"), systemImage: "snowflake").foregroundStyle(.orange)
                }
                if let h = pump.holiday {
                    Label(L.t("Semesterläge är på", "Holiday mode is on") + Self.until(h.endDate),
                          systemImage: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                }
                if let e = store.heatPumpError {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            if editing {
                HeatControlEditor(store: store, pump: pump)
                HeatWatchEditor(config: store.heatWatchBinding(for: pump))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alarm ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 8))
        .alert(L.t("Slå av \(pump.name)?", "Switch off \(pump.name)?"), isPresented: $confirmOff) {
            Button(L.t("Slå av", "Switch off"), role: .destructive) { Task { await store.sendHeat(pump, HeatCommand(power: false)) } }
            Button(L.t("Avbryt", "Cancel"), role: .cancel) {}
        } message: {
            if let f = pump.frost, f.isEnabled {
                Text(L.t("Frostskyddet är på (\(Fmt.num(f.min, decimals: 0))–\(Fmt.num(f.max, decimals: 0)) °C).",
                         "Frost protection is on (\(Fmt.num(f.min, decimals: 0))–\(Fmt.num(f.max, decimals: 0)) °C)."))
            } else {
                Text(L.t("Frostskyddet är av, så rummet kan bli kallt och vattenrören frysa.",
                         "Frost protection is off, so the room can get cold and the water pipes can freeze."))
            }
        }
    }

    /// " till 30 nov 22:18" from the unit's wall-clock end date, or nothing if it can't be read.
    private static func until(_ iso: String?) -> String {
        guard let iso, iso.count >= 19 else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let d = f.date(from: String(iso.prefix(19))) else { return "" }
        return L.t(" till ", " until ") + Fmt.time(d)
    }
}

/// Fan speed, frost protection and holiday mode: things that change rarely, so they live behind the slider icon.
private struct HeatControlEditor: View {
    @ObservedObject var store: PlugStore
    let pump: HeatPump
    @State private var planning = false
    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()

    var body: some View {
        let frost = store.frostValue(pump)
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if pump.isOn {
                Picker(L.t("Fläkt", "Fan"), selection: Binding(get: { pump.fan ?? "Auto" },
                                                              set: { f in Task { await store.sendHeat(pump, HeatCommand(setFanSpeed: f)) } })) {
                    ForEach(["Auto", "One", "Two", "Three", "Four", "Five"], id: \.self) { Text(Fmt.fan($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Toggle(L.t("Frostskydd", "Frost protection"), isOn: Binding(get: { frost.isEnabled },
                                                                       set: { var f = frost; f.isEnabled = $0; store.setFrost(pump, f) }))
            if frost.isEnabled {
                Stepper(value: Binding(get: { frost.min }, set: { var f = frost; f.min = $0; store.setFrost(pump, f) }), in: 4...14, step: 1) {
                    Text(L.t("Värmer när det blir under ", "Heats when it falls below ") + Fmt.temp(frost.min))
                }
                Stepper(value: Binding(get: { frost.max }, set: { var f = frost; f.max = $0; store.setFrost(pump, f, changedMax: true) }), in: 6...16, step: 1) {
                    Text(L.t("Slutar vid ", "Stops at ") + Fmt.temp(frost.max))
                }
                Text(L.t("Medan frostskyddet är aktivt styr det pumpen och måltemperaturen går inte att ändra. Håll lägsta gränsen över ert larm.",
                         "While frost protection is active it controls the unit and the target temperature can't be changed. Keep the lower limit above your alarm."))
                    .foregroundStyle(.secondary)
            }
            if pump.holiday != nil {
                Label(L.t("Semesterläge är på", "Holiday mode is on"), systemImage: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                Button(L.t("Stäng av semesterläge", "Turn off holiday mode")) { Task { await store.setHoliday(pump, enabled: false) } }
                    .disabled(store.heatBusy.contains(pump.id))
            } else if planning {
                DatePicker(L.t("Från", "From"), selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker(L.t("Till", "To"), selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                Text(L.t("Semesterläge ändrar hur pumpen körs medan ni är borta. Kontrollera att frostskyddet är på.",
                         "Holiday mode changes how the unit runs while you're away. Check that frost protection is on."))
                    .foregroundStyle(.orange)
                HStack {
                    Button(L.t("Avbryt", "Cancel")) { planning = false }
                    Spacer()
                    Button(L.t("Slå på", "Turn on")) {
                        planning = false
                        Task { await store.setHoliday(pump, enabled: true, start: start, end: end) }
                    }
                }
            } else {
                Button(L.t("Planera semesterläge…", "Plan holiday mode…")) { start = Date(); planning = true }
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

private struct HeatWatchEditor: View {
    @Binding var config: HeatWatch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle(L.t("Larma för värmepumpen", "Alarm for the heat pump"), isOn: $config.enabled)
            if config.enabled {
                Stepper(value: $config.lowC, in: 4...20, step: 0.5) {
                    Text(L.t("Larma under ", "Alarm below ") + Fmt.temp(config.lowC))
                }
                Stepper(value: $config.warnC, in: config.lowC...25, step: 0.5) {
                    Text(L.t("Varna under ", "Warn below ") + Fmt.temp(config.warnC))
                }
                Stepper(value: $config.minutes, in: 10...240, step: 10) {
                    Text(L.t("Efter ", "After ") + Fmt.duration(config.minutes * 60) + L.t(" under gränsen", " below the limit"))
                }
                Toggle(L.t("Larma om pumpen rapporterar fel", "Alarm when the unit reports a fault"), isOn: $config.errorAlarm)
                Stepper(value: $config.offlineMinutes, in: 10...360, step: 10) {
                    Text(L.t("Offline-larm efter ", "Offline alarm after ") + Fmt.duration(config.offlineMinutes * 60))
                }
                Text(L.t("Temperaturen är värmepumpens egen termometer, som sitter högt på väggen.",
                         "The temperature is the heat pump's own thermometer, which sits high on the wall."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Diagram

private struct SpanPicker: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        Picker("", selection: $store.chartSpan) {
            ForEach(ChartSpan.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }
}

private func chartAxisLabel(_ d: Date, span: ChartSpan) -> String {
    span == .week
        ? d.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.locale))
        : d.formatted(.dateTime.hour().minute().locale(Fmt.locale))
}

private struct PowerChart: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        let metered = store.plugs.filter(\.hasMeter)
        let hasHeat = !store.heatPumps.isEmpty
        if !metered.isEmpty || hasHeat {
            VStack(alignment: .leading, spacing: 8) {
                if hasHeat {
                    // Without any metered plug there is no power chart to pick.
                    Picker("", selection: $store.chartKind) {
                        ForEach(metered.isEmpty ? ChartKind.allCases.filter { $0 != .power } : ChartKind.allCases) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                switch store.chartKind {
                case .power: powerChart(metered)
                case .temperature: HeatTempChart(store: store)
                case .energy: HeatEnergyChart(store: store)
                }
            }
        }
    }

    private func powerChart(_ metered: [Plug]) -> some View {
        let pts = store.chartPoints()
        return VStack(alignment: .leading, spacing: 8) {
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
            SpanPicker(store: store)

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

    private func axisLabel(_ d: Date) -> String { chartAxisLabel(d, span: store.chartSpan) }

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


// MARK: - Värmepumpens diagram

private struct HeatTempChart: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        let now = Date()
        let (pts, bands) = store.heatSeries(now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("Temperatur", "Temperature")).font(.subheadline.weight(.semibold))
                Spacer()
                if let n = store.chartHeat?.name { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
            SpanPicker(store: store)
            ZStack {
                chart(pts, bands, now: now).frame(height: 160)
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
            if !pts.isEmpty { legendAndSummary(pts, hasBands: !bands.isEmpty) }
        }
    }

    private static func bandColor(_ mode: String?) -> Color {
        switch mode {
        case "Cool": .blue
        case "Dry": .teal
        case "Fan": .indigo
        case "Auto": .green
        default: .orange
        }
    }

    private func chart(_ pts: [TempPoint], _ bands: [RunBand], now: Date) -> some View {
        Chart {
            ForEach(bands) { b in
                RectangleMark(xStart: .value("Start", b.start), xEnd: .value(L.t("Slut", "End"), b.end))
                    .foregroundStyle(Self.bandColor(b.mode).opacity(0.12))
            }
            ForEach(pts) { p in
                LineMark(x: .value("Tid", p.date), y: .value("°C", p.room), series: .value("Del", "r\(p.segment)"))
                    .foregroundStyle(.orange)
                if let s = p.set {
                    LineMark(x: .value("Tid", p.date), y: .value(L.t("Mål", "Target"), s), series: .value("Del", "s\(p.segment)"))
                        .foregroundStyle(.green).interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            if let f = store.chartHeat?.frost, f.isEnabled {
                RuleMark(y: .value(L.t("Frostskydd", "Frost protection"), f.min))
                    .foregroundStyle(.blue.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXScale(domain: now.addingTimeInterval(-store.chartSpan.seconds)...now)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine()
                AxisValueLabel(collisionResolution: .greedy) {
                    if let d = v.as(Date.self) { Text(chartAxisLabel(d, span: store.chartSpan)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.num(d, decimals: 0) + "°") } }
            }
        }
    }

    private func legendAndSummary(_ pts: [TempPoint], hasBands: Bool) -> some View {
        let rooms = pts.map(\.room)
        let avg = rooms.reduce(0, +) / Double(rooms.count)
        var parts = ["Min \(Fmt.temp(rooms.min()))", "Max \(Fmt.temp(rooms.max()))", L.t("Medel ", "Average ") + Fmt.temp(avg)]
        parts.append(L.t("orange: rum, grön streckad: mål", "orange: room, dashed green: target") + (hasBands ? L.t(", skuggat: igång", ", shaded: running") : ""))
        return Text(parts.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

private struct HeatEnergyChart: View {
    @ObservedObject var store: PlugStore

    var body: some View {
        let now = Date()
        let buckets = store.energyBuckets(now: now)
        let unit: Calendar.Component = store.chartSpan == .week ? .day : .hour
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("Energi", "Energy")).font(.subheadline.weight(.semibold))
                Spacer()
                if let n = store.chartHeat?.name { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
            SpanPicker(store: store)
            ZStack {
                Chart(buckets) { b in
                    BarMark(x: .value("Tid", b.date, unit: unit), y: .value("kWh", b.kwh))
                        .foregroundStyle(.indigo)
                }
                .chartXScale(domain: now.addingTimeInterval(-store.chartSpan.seconds)...now)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine()
                        AxisValueLabel(collisionResolution: .greedy) {
                            if let d = v.as(Date.self) { Text(chartAxisLabel(d, span: store.chartSpan)) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.num(d, decimals: d < 10 ? 1 : 0)) } }
                    }
                }
                .frame(height: 160)
                if buckets.isEmpty {
                    if store.chartLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L.t("Ingen energidata för perioden.", "No energy data for this period."))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            if !buckets.isEmpty {
                let total = buckets.reduce(0) { $0 + $1.kwh }
                Text(L.t("Totalt ", "Total ") + Fmt.kwh(total) + L.t(" · kWh per ", " · kWh per ")
                     + (store.chartSpan == .week ? L.t("dag", "day") : L.t("timme", "hour")))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
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
