import SwiftUI
import RulesEngine

/// Top level: a list of **site lists** (shared `SiteList` model). Each drills down to an editor with
/// the list's domains, its default, and an ordered sublist of Allow/Deny **rules** (first active rule
/// wins).
struct ContentView: View {
    @EnvironmentObject private var store: MobileStore
    @AppStorage("configURL") private var configURL = ""
    @State private var importing = false
    @State private var importStatus: String?
    @State private var importFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    lockRow
                    budgetLine
                    blockingRow
                } footer: { Text(lockFooter) }

                Section("Site lists") {
                    ForEach($store.lists) { $list in
                        NavigationLink { ListEditView(list: $list) } label: {
                            ListRow(list: list, isBlocked: store.blockedListIDs.contains(list.id),
                                    disabled: store.isDisabled)
                        }
                        .listRowBackground(listTint(list))
                    }
                    .onDelete { $0.map { store.lists[$0] }.forEach(store.delete) }
                    .onMove { store.moveLists(from: $0, to: $1) }

                    Button { store.addList() } label: { Label("Add List", systemImage: "plus") }
                }

                syncSection
            }
            .navigationTitle("SiteBlocker")
            .toolbar { EditButton() }
        }
    }

    // MARK: Lock control

    private var lockRow: some View {
        HStack {
            if store.isUnlocked {
                Label("Unlocked", systemImage: "lock.open.fill").foregroundStyle(.green)
                Spacer()
                Button("Lock") { store.lock() }
            } else {
                Label("Locked", systemImage: "lock.fill").foregroundStyle(.secondary)
                Spacer()
                Button("Unlock") { Task { await store.unlock() } }.disabled(!store.canUnlock)
            }
        }
    }

    /// Master enable/disable for all blocking, mirroring the desktop's top-bar control.
    private var blockingRow: some View {
        HStack {
            if store.isDisabled {
                Label("Blocking disabled", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Enable") { Task { await store.setDisabled(false) } }
            } else {
                Label("Blocking on", systemImage: "shield.fill").foregroundStyle(.secondary)
                Spacer()
                Button("Disable") { Task { await store.setDisabled(true) } }
            }
        }
    }

    @ViewBuilder private var budgetLine: some View {
        if let budget = store.budget {
            if budget.remaining <= 0 {
                Label("Daily limit reached", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label("Daily limit: \(Self.minutes(budget.remaining)) left of \(Self.minutes(budget.limit))",
                      systemImage: "hourglass")
                    .font(.callout).foregroundStyle(store.isUnlocked ? .green : .secondary)
            }
        }
    }

    private var lockFooter: String {
        if store.isDisabled { return "Blocking is disabled — no sites are blocked. Enable to resume." }
        if store.isUnlocked { return "Unlocked — limited lists are open until the budget is spent." }
        if store.canUnlock { return "A limited list can be unlocked now with Face ID." }
        return "Lists follow their rules. Nothing to unlock right now."
    }

    // MARK: Sync

    private var syncSection: some View {
        Section {
            TextField("Config URL", text: $configURL,
                      prompt: Text("https://…/siteblocker-config.json"))
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
            Button { runImport() } label: {
                HStack { Text("Import from URL"); Spacer(); if importing { ProgressView() } }
            }
            .disabled(configURL.isEmpty || importing)
            if let importStatus {
                Text(importStatus).font(.caption).foregroundStyle(importFailed ? .red : .secondary)
            }
        } header: { Text("Sync") } footer: {
            Text("Importing replaces your lists with the shared config from your Mac.")
        }
    }

    private func runImport() {
        guard let url = URL(string: configURL.trimmingCharacters(in: .whitespaces)) else {
            importStatus = "Invalid URL"; importFailed = true; return
        }
        importing = true; importStatus = nil; importFailed = false
        Task {
            defer { importing = false }
            do {
                try await store.importConfig(from: url)
                importStatus = "Imported \(store.lists.count) lists."; importFailed = false
            } catch {
                importStatus = "Failed: \(error.localizedDescription)"; importFailed = true
            }
        }
    }

    /// Subtle row tint mirroring the desktop: grey when off, red when blocked now, green when open.
    private func listTint(_ list: SiteList) -> Color {
        if store.isDisabled { return Color.secondary.opacity(0.10) }
        if store.blockedListIDs.contains(list.id) { return Color.red.opacity(0.10) }
        return Color.green.opacity(0.08)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        var mins = Int(seconds / 60)
        if seconds.truncatingRemainder(dividingBy: 60) > 0 { mins += 1 }
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Rows

private struct ListRow: View {
    let list: SiteList
    let isBlocked: Bool
    var disabled = false
    var body: some View {
        HStack {
            Circle().fill(status.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name.isEmpty ? "Untitled" : list.name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.label).font(.caption2.weight(.semibold)).foregroundStyle(status.color)
        }
    }
    /// Live state, mirroring the desktop: Off (blocking disabled), Blocked now, or Open now.
    private var status: (color: Color, label: String) {
        if disabled { return (.secondary, "Off") }
        if isBlocked { return (.red, "Blocked") }
        return (.green, "Open")
    }
    private var subtitle: String {
        let n = list.targets.count
        let sites = "\(n) site\(n == 1 ? "" : "s")"
        let base = list.isBlockedByDefault ? "blocked" : "allowed"
        let c = list.rules.count
        let exceptions = c == 0 ? "no exceptions" : "\(c) exception\(c == 1 ? "" : "s")"
        return "\(sites) · \(base) · \(exceptions)"
    }
}

// MARK: - List editor

private struct ListEditView: View {
    @EnvironmentObject private var store: MobileStore
    @Binding var list: SiteList

    private enum Kind: Hashable { case manual, url }
    @State private var kind: Kind = .manual
    @State private var domainsText = ""
    @State private var urlText = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $list.name)
            }

            Section {
                Picker("Default", selection: $list.isBlockedByDefault) {
                    Text("Blocked").tag(true)
                    Text("Allowed").tag(false)
                }
                .pickerStyle(.segmented)
            } header: { Text("Default") } footer: {
                Text(list.isBlockedByDefault
                     ? "Blocked by default. Exceptions below open these sites while active."
                     : "Allowed by default. Exceptions below block these sites while active.")
            }

            Section {
                ForEach($list.rules) { $rule in
                    let isActive = list.isEnabled && store.activeRuleID(for: list) == rule.id
                    NavigationLink { RuleEditView(rule: $rule, baseBlocked: list.isBlockedByDefault) } label: {
                        RuleSummaryRow(rule: rule, baseBlocked: list.isBlockedByDefault, isActive: isActive)
                    }
                }
                .onDelete { list.rules.remove(atOffsets: $0) }
                .onMove { list.rules.move(fromOffsets: $0, toOffset: $1) }
                Menu {
                    Button("Schedule") { list.rules.append(ListRule()) }
                    Button("From calendar…") {
                        list.rules.append(ListRule(condition: .duringCalendarEvent(
                            CalendarSource(id: "", title: "Choose calendar"))))
                        store.ensureCalendarAccessIfNeeded()
                    }
                    Button("From Focus…") {
                        list.rules.append(ListRule(condition: .duringFocus(FocusSource(id: "", name: ""))))
                    }
                    Button("At location…") {
                        list.rules.append(ListRule(condition: .atLocation(
                            GeoRegion(name: "", latitude: 0, longitude: 0, radius: 150))))
                        store.requestLocationAccess()
                    }
                } label: {
                    Label("Add exception", systemImage: "plus")
                }
            } header: {
                Text("Exceptions")
            } footer: {
                Text(list.isBlockedByDefault
                     ? "Each opens these sites while active — the first active one wins."
                     : "Each blocks these sites while active — the first active one wins.")
            }

            Section {
                Picker("Source", selection: $kind) {
                    Text("Typed").tag(Kind.manual)
                    Text("URL").tag(Kind.url)
                }
                .pickerStyle(.segmented)

                if kind == .manual {
                    TextEditor(text: $domainsText)
                        .frame(minHeight: 140).autocorrectionDisabled()
                        .textInputAutocapitalization(.never).font(.body.monospaced())
                } else {
                    TextField("https://example.com/blocklist.txt", text: $urlText)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                    HStack {
                        Button("Apply / Refresh") { applyURL() }
                            .disabled(URL(string: urlText.trimmingCharacters(in: .whitespaces)) == nil)
                        Spacer()
                        Text("\(list.targets.count) sites loaded").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Websites") } footer: {
                Text(kind == .manual
                     ? "One domain per line, or hosts format. # ! ; comments are handled."
                     : "A blocklist URL — fetched now and refreshed periodically. The last list is kept if a fetch fails.")
            }
        }
        .navigationTitle(list.name.isEmpty ? "List" : list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear {
            if case .remote(let url) = list.source { kind = .url; urlText = url.absoluteString }
            else { kind = .manual }
            domainsText = list.targets.map(\.domain).joined(separator: "\n")
        }
        .onChange(of: domainsText) { newValue in
            guard kind == .manual else { return }
            let hosts = SiteRuleset.parse(newValue).map { HostPattern($0) }
            list.targets = hosts
            list.source = .manual(hosts)
        }
    }

    private func applyURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else { return }
        list.source = .remote(url)
        store.resolveRemoteSources(force: true)
    }
}

/// One exception. Its effect is implied by the list's base state: a green "Allow" window opens a
/// blocked list; a red "Block" window closes an allowed one.
private struct RuleSummaryRow: View {
    let rule: ListRule
    var baseBlocked = true
    var isActive = false
    private var allows: Bool { baseBlocked }   // an exception flips the base state
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: allows ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(allows ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(allows ? "Allow" : "Block").font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if isActive { Spacer(); ActiveBadge() }
        }
    }
    private var subtitle: String {
        switch rule.condition {
        case .duringCalendarEvent(let s): return "Calendar · \(s.title)"
        case .duringFocus(let f):         return "Focus · \(f.name.isEmpty ? "unnamed" : f.name)"
        case .atLocation(let r):          return "Location · \(r.name.isEmpty ? "unset" : r.name)"
        default:                          return RuleFormat.schedule(rule, showLimit: baseBlocked)
        }
    }
}

/// Small green pill marking the rule that's deciding the list right now.
private struct ActiveBadge: View {
    var body: some View {
        Text("Active now")
            .font(.caption2.weight(.semibold)).foregroundStyle(.green)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.15)))
    }
}

// MARK: - Rule editor

private struct RuleEditView: View {
    @EnvironmentObject private var store: MobileStore
    @Binding var rule: ListRule
    /// The list's base state: this exception is an Allow-window when blocked, a Block-window when
    /// allowed. A daily limit only applies to an Allow-window.
    let baseBlocked: Bool
    @State private var schedule: RuleSchedule

    init(rule: Binding<ListRule>, baseBlocked: Bool) {
        _rule = rule
        self.baseBlocked = baseBlocked
        _schedule = State(initialValue: RuleSchedule(condition: rule.wrappedValue.condition,
                                                     dailyLimit: rule.wrappedValue.dailyLimit))
    }

    private enum Kind { case schedule, calendar, focus, location }
    private var kind: Kind {
        switch rule.condition {
        case .duringCalendarEvent: return .calendar
        case .duringFocus:         return .focus
        case .atLocation:          return .location
        default:                   return .schedule
        }
    }

    var body: some View {
        Form {
            switch kind {
            case .calendar: calendarSection
            case .focus:    focusSection
            case .location: locationSection
            case .schedule: scheduleSections
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: schedule) { _ in commit() }
        .onAppear { if kind == .calendar && store.availableCalendars().isEmpty {
            Task { await store.requestCalendarAccess() } } }
    }

    private var title: String {
        let verb = baseBlocked ? "allow" : "block"
        switch kind {
        case .calendar: return "Calendar \(verb)"
        case .focus:    return "Focus \(verb)"
        case .location: return "Location \(verb)"
        case .schedule: return baseBlocked ? "Allow window" : "Block window"
        }
    }

    // MARK: Focus editor

    private var focusSection: some View {
        Section {
            TextField("Focus name (e.g. Work)", text: Binding(
                get: { if case .duringFocus(let f) = rule.condition { return f.name }; return "" },
                set: { name in rule.condition = .duringFocus(
                    FocusSource(id: name.lowercased().trimmingCharacters(in: .whitespaces), name: name)) }))
                .autocorrectionDisabled()
        } header: { Text("Focus") } footer: {
            Text("Add SiteBlocker's Focus Filter to this Focus in Settings › Focus, and enter the same name. The exception applies while that Focus is on.")
        }
    }

    // MARK: Location editor

    private var region: GeoRegion {
        if case .atLocation(let r) = rule.condition { return r }
        return GeoRegion(name: "", latitude: 0, longitude: 0, radius: 150)
    }
    private func setRegion(_ transform: (inout GeoRegion) -> Void) {
        var r = region; transform(&r); rule.condition = .atLocation(r)
    }
    private var locationSection: some View {
        Section {
            TextField("Name (e.g. Home)", text: Binding(
                get: { region.name }, set: { v in setRegion { $0.name = v } }))
            HStack {
                Text("Latitude"); Spacer()
                TextField("0", value: Binding(get: { region.latitude },
                    set: { v in setRegion { $0.latitude = v } }),
                          format: .number.precision(.fractionLength(5)))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Longitude"); Spacer()
                TextField("0", value: Binding(get: { region.longitude },
                    set: { v in setRegion { $0.longitude = v } }),
                          format: .number.precision(.fractionLength(5)))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
            }
            Stepper("Radius \(Int(region.radius)) m", value: Binding(
                get: { region.radius }, set: { v in setRegion { $0.radius = v } }),
                    in: 50...5000, step: 50)
            Button("Use current location") {
                if let c = store.currentCoordinate {
                    setRegion { $0.latitude = c.latitude; $0.longitude = c.longitude }
                } else { store.requestLocationAccess() }
            }
        } header: { Text("Location") } footer: {
            Text("The exception applies while you're inside this area. Requires “Always” location access to work in the background.")
        }
    }

    /// Pick which calendar's event days drive this exception.
    @ViewBuilder private var calendarSection: some View {
        Section {
            let calendars = store.availableCalendars()
            if calendars.isEmpty {
                Button("Allow calendar access…") { Task { await store.requestCalendarAccess() } }
            } else {
                ForEach(calendars) { cal in
                    Button {
                        rule.condition = .duringCalendarEvent(cal)
                    } label: {
                        HStack {
                            Text(cal.title).foregroundStyle(.primary)
                            Spacer()
                            if currentCalendarID == cal.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        } header: { Text("Calendar") } footer: {
            Text(baseBlocked ? "Opens these sites on days this calendar has an event (e.g. holidays)."
                             : "Blocks these sites on days this calendar has an event.")
        }
    }

    private var currentCalendarID: String? {
        if case .duringCalendarEvent(let s) = rule.condition { return s.id }
        return nil
    }

    @ViewBuilder private var scheduleSections: some View {
            Section {
                DaysPicker(days: $schedule.days)
                Toggle("Time of day", isOn: $schedule.timeEnabled)
                if schedule.timeEnabled {
                    HStack {
                        DatePicker("From", selection: minutesBinding(\.startMinutes),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: minutesBinding(\.endMinutes),
                                   displayedComponents: .hourAndMinute)
                    }
                }
            } header: { Text("Applies on") } footer: {
                Text(baseBlocked ? "Opens these sites during the selected days/time. No days = never."
                                 : "Blocks these sites during the selected days/time. No days = never.")
            }

            if baseBlocked {
                Section {
                    Toggle("Daily limit (Face ID)", isOn: $schedule.quotaEnabled)
                    if schedule.quotaEnabled {
                        Stepper("\(schedule.quotaMinutes) min/day",
                                value: $schedule.quotaMinutes, in: 5...240, step: 5)
                    }
                } footer: {
                    Text("With a limit, these sites need a Face ID unlock and stay open until the shared daily budget is spent.")
                }
            }
        }

    private func commit() {
        // Signal exceptions (calendar/focus/location) manage their own condition via their editors.
        if kind != .schedule { rule.dailyLimit = nil; return }
        rule.condition = schedule.condition
        rule.dailyLimit = baseBlocked ? schedule.dailyLimit : nil   // a block-window carries no limit
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(TimeInterval(schedule.window[keyPath: keyPath] * 60))
        } set: { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule.window[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }
    }
}

// MARK: - Shared bits

enum RuleFormat {
    static func schedule(_ rule: ListRule, showLimit: Bool = true) -> String {
        let s = RuleSchedule(condition: rule.condition, dailyLimit: rule.dailyLimit)
        var parts: [String] = [days(s.days)]
        if s.timeEnabled { parts.append("\(clock(s.window.startMinutes))–\(clock(s.window.endMinutes))") }
        if showLimit && s.quotaEnabled { parts.append("\(s.quotaMinutes) min/day") }
        return parts.joined(separator: " · ")
    }
    private static func days(_ set: Set<Weekday>) -> String {
        if set.isEmpty { return "never" }
        if set == Set(Weekday.allCases) { return "every day" }
        if set == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "weekdays" }
        if set == [.saturday, .sunday] { return "weekends" }
        return Weekday.allCases.filter(set.contains).map(\.shortLabel).joined(separator: ", ")
    }
    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct DaysPicker: View {
    @Binding var days: Set<Weekday>
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = days.contains(day)
                Button { toggle(day) } label: {
                    Text(day.letter)
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.shortLabel)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
    }
    private func toggle(_ day: Weekday) {
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
    }
}
