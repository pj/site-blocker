import SwiftUI
import RulesEngine

/// The management screen. Each **site list** is a card: its sites (a manual/file/URL source), a
/// base state (Blocked/Allowed by default), and an *ordered* list of **exceptions** that flip the
/// base while active (first active exception wins). Exceptions OR together; edit fully in place.
struct ContentView: View {
    @EnvironmentObject private var store: RuleStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await store.toggleLock() }
                } label: {
                    Label(store.isUnlocked ? "Lock" : "Unlock",
                          systemImage: store.isUnlocked ? "lock.open.fill" : "lock.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isUnlocked ? .green : .red)
                .disabled(store.isDisabled || (!store.isUnlocked && !store.canUnlock))

                Button {
                    Task { await store.toggleDisabledAuthenticated() }
                } label: {
                    Label(store.isDisabled ? "Enable blocking" : "Disable blocking",
                          systemImage: store.isDisabled ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .help(store.isDisabled ? "Resume blocking on all lists"
                                       : "Pause blocking on all lists (requires authentication)")

                Text(statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Viewed today: \(Self.duration(store.totalUsageToday))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($store.lists) { $list in
                        ListRowView(list: $list)
                    }
                }
                .padding(12)
            }
            .overlay {
                if store.lists.isEmpty {
                    ContentUnavailableView("No Lists", systemImage: "hand.raised",
                                           description: Text("Add a site list to start blocking."))
                }
            }

            Divider()
            HStack {
                Button { store.add(SiteList(name: "New List")) } label: {
                    Label("Add List", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 900, minHeight: 420)
    }

    private var statusText: String {
        if store.isDisabled { return "Blocking disabled" }
        if store.isUnlocked { return "Unlocked" }
        if store.openAccessActive {
            return store.canUnlock ? "Some sites open · unlock available" : "Some sites open now"
        }
        return store.canUnlock ? "Locked — unlock available" : "Locked — following rules"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - List row (one list, six aligned columns)

private struct ListRowView: View {
    @EnvironmentObject private var store: RuleStore
    @Binding var list: SiteList
    @State private var showSites = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 1. Block status — a dot; the label shows on hover.
            Circle().fill(statusColor).frame(width: 9, height: 9)
                .help(statusText)

            // 2. Name.
            TextField("Name", text: $list.name)
                .textFieldStyle(.roundedBorder).frame(width: 150)

            // 3. List (sites source).
            sitesButton.frame(width: 130, alignment: .leading)

            // 4. Default (base state).
            BaseStatePicker(isBlocked: $list.isBlockedByDefault)
                .frame(width: 150)

            // 5. Exceptions.
            RulesColumn(list: $list)

            // 6. Delete (right side).
            Button { Task { await store.deleteAuthenticated(list) } } label: {
                Image(systemName: "trash").font(.title3)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).fixedSize()
            .help("Delete list (requires authentication)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowColor))
    }

    private var statusColor: Color {
        if store.isDisabled { return .secondary }
        return store.blockedListIDs.contains(list.id) ? .red : .green
    }
    private var statusText: String {
        if store.isDisabled { return "Blocking disabled" }
        return store.blockedListIDs.contains(list.id) ? "Blocked now" : "Open now"
    }
    /// A faint tint of the current status behind the whole row.
    private var rowColor: Color {
        if store.isDisabled { return Color.gray.opacity(0.14) }
        return store.blockedListIDs.contains(list.id)
            ? Color.red.opacity(0.09) : Color.green.opacity(0.08)
    }

    private var sitesButton: some View {
        Button { showSites = true } label: { Label(sitesSummary, systemImage: sitesIcon) }
            .controlSize(.small)
            .popover(isPresented: $showSites, arrowEdge: .bottom) {
                SourceEditor(list: list).padding(12).frame(width: 400)
            }
            .help("Edit this list's sites")
    }
    private var sitesIcon: String {
        switch list.source {
        case .manual: return "list.bullet"
        case .file:   return "doc"
        case .remote: return "link"
        }
    }
    private var sitesSummary: String {
        let n = list.targets.count
        let sites = "\(n.formatted()) \(n == 1 ? "site" : "sites")"
        switch list.source {
        case .manual: return sites
        case .file:   return "File · \(sites)"
        case .remote: return "URL · \(sites)"
        }
    }
}

/// The list's ordered exceptions (each flips the base state while active), then "Add exception".
/// An exception has no allow/deny of its own — its effect is implied by the base state.
private struct RulesColumn: View {
    @Binding var list: SiteList
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($list.rules) { $rule in
                RuleRow(rule: $rule,
                        isFirst: rule.id == list.rules.first?.id,
                        baseBlocked: list.isBlockedByDefault) {
                    list.rules.removeAll { $0.id == rule.id }
                }
            }
            Button { list.rules.append(ListRule()) } label: {
                Label("Add exception", systemImage: "plus")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The list's base state as a 2-segment control: red "Blocked" / green "Allowed".
private struct BaseStatePicker: View {
    @Binding var isBlocked: Bool
    var body: some View {
        HStack(spacing: 0) {
            segment("Blocked", selected: isBlocked, color: .red) { isBlocked = true }
            Divider().frame(height: 20)
            segment("Allowed", selected: !isBlocked, color: .green) { isBlocked = false }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.25)))
        .help("The list's default when no exception is active")
    }

    private func segment(_ title: String, selected: Bool, color: Color,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(selected ? color : Color.secondary.opacity(0.08))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Exception row (a schedule that flips the base state, chip-based)

private struct RuleRow: View {
    @EnvironmentObject private var store: RuleStore
    @Binding var rule: ListRule
    let isFirst: Bool
    /// The list's base state: exceptions are Allow-windows when blocked, Block-windows when allowed.
    /// A daily limit only applies to an Allow-window.
    let baseBlocked: Bool
    let onDelete: () -> Void

    @State private var draft: Draft
    @State private var editing = false

    init(rule: Binding<ListRule>, isFirst: Bool, baseBlocked: Bool, onDelete: @escaping () -> Void) {
        _rule = rule
        self.isFirst = isFirst
        self.baseBlocked = baseBlocked
        self.onDelete = onDelete
        _draft = State(initialValue: Draft(rule: rule.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 8) {
            if !isFirst {   // OR only precedes subsequent rows; the first stays flush left
                Text("OR").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .help("A list's exceptions are OR'd — any matching one applies")
            }

            summaryButton

            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove exception")

            Spacer(minLength: 0)
        }
        .onChange(of: draft) { apply() }
        .onChange(of: baseBlocked) { apply() }   // a block-window carries no limit
    }

    // MARK: Summary row + popover

    private var summaryButton: some View {
        Button { editing = true } label: {
            HStack(spacing: 8) {
                Text(baseBlocked ? "Allow" : "Block")
                    .font(.caption.weight(.semibold)).foregroundStyle(baseBlocked ? .green : .red)
                Text(summaryText).font(.caption).foregroundStyle(.primary)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            ScrollView { editor.padding(16).frame(width: 400) }
                .frame(maxHeight: 640)
        }
    }

    private var summaryText: String {
        var parts: [String] = []
        if draft.useCalendar {
            parts.append(draft.calendar.id.isEmpty ? "no calendar" : draft.calendar.title)
        } else {
            var s = [daysText]
            if draft.schedule.timeEnabled { s.append(timeText) }
            parts.append(s.joined(separator: " "))
        }
        if draft.focusEnabled { parts.append(draft.focus.name.isEmpty ? "a Focus" : "“\(draft.focus.name)”") }
        if draft.locationEnabled {
            let place = draft.region.name.isEmpty ? "location" : draft.region.name
            parts.append("\(draft.locationInverted ? "not at" : "at") \(place)")
        }
        if baseBlocked && draft.limitEnabled { parts.append("\(draft.limitMinutes)m/day") }
        return parts.joined(separator: " · ")
    }

    // MARK: The single editor (everything on one popover)

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Applies-when: schedule OR calendar (mutually exclusive).
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $draft.useCalendar) {
                    Text("Days & times").tag(false)
                    Text("Calendar days").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                if draft.useCalendar {
                    calendarPicker
                } else {
                    DayCircles(days: $draft.schedule.days)
                    Divider()
                    Toggle("Time of day", isOn: $draft.schedule.timeEnabled)
                    if draft.schedule.timeEnabled { TimeEditor(window: $draft.schedule.window) }
                }
                if baseBlocked {
                    Divider()
                    Toggle("Daily limit", isOn: $draft.limitEnabled)
                    if draft.limitEnabled {
                        Stepper("\(draft.limitMinutes) min/day", value: $draft.limitMinutes, in: 5...240, step: 5)
                    }
                }
            }

            Divider()
            Toggle("Only while a Focus is on", isOn: $draft.focusEnabled)
            if draft.focusEnabled {
                TextField("Focus name (e.g. Work)", text: $draft.focus.name).textFieldStyle(.roundedBorder)
                Text("Attach SiteBlocker’s Focus Filter to this Focus in System Settings and use the same name.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()
            Toggle("Only based on a location", isOn: $draft.locationEnabled)
            if draft.locationEnabled {
                Picker("", selection: $draft.locationInverted) {
                    Text("While at this location").tag(false)
                    Text("While not at this location").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                locationFields
            }
        }
    }

    @ViewBuilder private var calendarPicker: some View {
        let calendars = store.availableCalendars()
        if calendars.isEmpty {
            Button("Allow calendar access…") { Task { await store.requestCalendarAccess() } }
                .onAppear { Task { await store.requestCalendarAccess() } }
        } else {
            Picker("Calendar", selection: calendarSelection) {
                Text("Choose calendar").tag("")
                ForEach(calendars) { Text($0.title).tag($0.id) }
            }
            Text("Applies on days this calendar has an event (e.g. holidays).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var calendarSelection: Binding<String> {
        Binding(get: { draft.calendar.id }, set: { id in
            let title = store.availableCalendars().first { $0.id == id }?.title ?? "Choose calendar"
            draft.calendar = CalendarSource(id: id, title: title)
        })
    }

    @ViewBuilder private var locationFields: some View {
        LocationPicker(region: $draft.region, currentCoordinate: store.currentCoordinate) {
            Task { await store.requestLocationAccess() }
        }
    }

    // MARK: Draft ⇄ rule

    /// The editor's state: a schedule *or* a calendar for "when", plus optional Focus and Location
    /// constraints that AND together, plus an optional daily limit.
    private struct Draft: Equatable {
        var useCalendar = false
        var calendar = CalendarSource(id: "", title: "Choose calendar")
        var schedule = RuleSchedule()
        var focusEnabled = false
        var focus = FocusSource(id: "", name: "")
        var locationEnabled = false
        var locationInverted = false   // true = applies while *away from* the region
        var region = GeoRegion(name: "", latitude: 0, longitude: 0, radius: 150)
        var limitEnabled = false
        var limitMinutes = 30

        init() {}

        init(rule: ListRule) {
            let flat = Draft.flatten(rule.condition)
            if let cal = flat.compactMap({ c -> CalendarSource? in
                if case .duringCalendarEvent(let s) = c { return s }; return nil }).first {
                useCalendar = true; calendar = cal
            }
            schedule = RuleSchedule(condition: rule.condition, dailyLimit: nil)   // days/time only
            if let f = flat.compactMap({ c -> FocusSource? in
                if case .duringFocus(let s) = c { return s }; return nil }).first {
                focusEnabled = true; focus = f
            }
            for c in flat {
                if case .atLocation(let s) = c {
                    locationEnabled = true; region = s; locationInverted = false; break
                }
                if case .not(let inner) = c, case .atLocation(let s) = inner {
                    locationEnabled = true; region = s; locationInverted = true; break
                }
            }
            if let limit = rule.dailyLimit { limitEnabled = true; limitMinutes = max(1, Int(limit / 60)) }
        }

        private static func flatten(_ c: Condition) -> [Condition] {
            if case .allOf(let list) = c { return list }
            return [c]
        }

        /// Build the composite condition + daily limit for the current base state.
        func resolve(baseBlocked: Bool) -> (Condition, TimeInterval?) {
            var parts: [Condition] = []
            if useCalendar {
                // No calendar chosen yet → the exception applies on *no* days (never), rather than
                // falling through to `.always` (every day).
                parts.append(calendar.id.isEmpty ? .not(.always) : .duringCalendarEvent(calendar))
            } else {
                let s = schedule.condition
                if s != .always { parts.append(s) }
            }
            if focusEnabled {
                parts.append(.duringFocus(FocusSource(id: FocusBridge.identifier(for: focus.name),
                                                      name: focus.name)))
            }
            if locationEnabled {
                let loc: Condition = .atLocation(region)
                parts.append(locationInverted ? .not(loc) : loc)
            }
            let condition: Condition = parts.isEmpty ? .always
                : (parts.count == 1 ? parts[0] : .allOf(parts))
            let limit: TimeInterval? = (baseBlocked && limitEnabled)
                ? TimeInterval(limitMinutes * 60) : nil
            return (condition, limit)
        }
    }

    private func apply() {
        let (condition, limit) = draft.resolve(baseBlocked: baseBlocked)
        guard rule.condition != condition || rule.dailyLimit != limit else { return }
        // Write both fields in one assignment so the store's @Published lists mutates once (two
        // separate property writes would fire didSet — and a full save/refresh — twice per edit).
        var updated = rule
        updated.condition = condition
        updated.dailyLimit = limit
        rule = updated
    }

    // MARK: Text helpers

    private var timeText: String {
        "\(clock(draft.schedule.window.startMinutes))–\(clock(draft.schedule.window.endMinutes))"
    }
    private var daysText: String {
        let d = draft.schedule.days
        if d == RuleSchedule.everyDay { return "Every day" }
        if d.isEmpty { return "Never" }
        let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        if d == weekdays { return "Weekdays" }
        if d == [.saturday, .sunday] { return "Weekends" }
        return Weekday.allCases.filter(d.contains).map(\.shortLabel).joined(separator: ", ")
    }
    private func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}

// MARK: - Chip + popover building blocks

private struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary
    var onRemove: (() -> Void)? = nil
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.caption2)
                    Text(text).font(.caption).lineLimit(1)
                }
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }
}

private struct ChipPopover<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(12)
    }
}

private struct DayCircles: View {
    @Binding var days: Set<Weekday>
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = days.contains(day)
                Button { if on { days.remove(day) } else { days.insert(day) } } label: {
                    Text(day.letter)
                        .font(.caption2.weight(.semibold)).frame(width: 22, height: 22)
                        .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(day.shortLabel)
            }
        }
    }
}

private struct TimeEditor: View {
    @Binding var window: TimeWindow
    var body: some View {
        HStack(spacing: 4) {
            DatePicker("", selection: minutesBinding(\.startMinutes), displayedComponents: .hourAndMinute)
            Text("–").foregroundStyle(.secondary)
            DatePicker("", selection: minutesBinding(\.endMinutes), displayedComponents: .hourAndMinute)
        }
        .labelsHidden().fixedSize()
    }
    private func minutesBinding(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(TimeInterval(window[keyPath: keyPath] * 60))
        } set: { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            window[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }
    }
}
