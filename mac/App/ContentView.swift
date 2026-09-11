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
            Menu {
                Button("Schedule") { list.rules.append(ListRule()) }
                Button("From calendar…") {
                    list.rules.append(ListRule(condition: .duringCalendarEvent(CalendarSource(id: "", title: "Choose calendar"))))
                }
            } label: {
                Label("Add exception", systemImage: "plus")
            }
            .menuStyle(.borderlessButton).buttonStyle(.bordered).controlSize(.small).fixedSize()
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

    @State private var schedule: RuleSchedule
    @State private var editingDays = false
    @State private var editingTime = false
    @State private var editingLimit = false

    /// Live width of the Days chip, and the width it had when the Days popover opened. While the
    /// popover is open we pin the chip to that frozen width so the anchor can't move — the popover
    /// stays perfectly still as the day-preview text changes, then the chip snaps to fit on close.
    @State private var daysChipWidth: CGFloat = 0
    @State private var frozenDaysWidth: CGFloat?

    init(rule: Binding<ListRule>, isFirst: Bool, baseBlocked: Bool, onDelete: @escaping () -> Void) {
        _rule = rule
        self.isFirst = isFirst
        self.baseBlocked = baseBlocked
        self.onDelete = onDelete
        _schedule = State(initialValue: RuleSchedule(condition: rule.wrappedValue.condition,
                                                     dailyLimit: rule.wrappedValue.dailyLimit))
    }

    var body: some View {
        HStack(spacing: 8) {
            if !isFirst {   // OR only precedes subsequent rows; the first stays flush left
                Text("OR").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .help("A list's exceptions are OR'd — any matching one applies")
            }

            if isCalendarException { calendarBox } else { chipBox }

            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove exception")

            Spacer(minLength: 0)
        }
        .onChange(of: schedule) { commit() }
        .onChange(of: baseBlocked) { commit() }   // a block-window carries no limit
    }

    private var isCalendarException: Bool {
        if case .duringCalendarEvent = rule.condition { return true }
        return false
    }

    /// A calendar-backed exception: pick the calendar whose event days flip the base state.
    @ViewBuilder private var calendarBox: some View {
        HStack(spacing: 6) {
            Menu {
                let calendars = store.availableCalendars()
                if calendars.isEmpty {
                    Button("Allow calendar access…") { Task { await store.requestCalendarAccess() } }
                } else {
                    ForEach(calendars) { cal in
                        Button(cal.title) { rule.condition = .duringCalendarEvent(cal) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.caption2)
                    Text(currentCalendarTitle).font(.caption)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .onAppear { if store.availableCalendars().isEmpty { Task { await store.requestCalendarAccess() } } }

            Divider().frame(height: 16)
            Text(baseBlocked ? "Allow" : "Block")
                .font(.caption.weight(.semibold)).foregroundStyle(baseBlocked ? .green : .red)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
        .fixedSize()
    }

    private var currentCalendarTitle: String {
        if case .duringCalendarEvent(let source) = rule.condition { return source.title }
        return "Choose calendar"
    }

    /// The exception's conditions (AND'd), then a plain-text indicator of its implied effect.
    private var chipBox: some View {
        HStack(spacing: 6) {
            // Days chip (always present — an exception always applies on some days).
            Chip(icon: "calendar", text: daysText, tint: schedule.days.isEmpty ? .orange : .secondary)
                { frozenDaysWidth = daysChipWidth; editingDays = true }
                .frame(width: frozenDaysWidth, alignment: .leading)   // pinned while the popover is open
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { daysChipWidth = g.size.width }
                        .onChange(of: g.size.width) { if frozenDaysWidth == nil { daysChipWidth = $0 } }
                })
                .popover(isPresented: $editingDays, arrowEdge: .bottom,
                         content: { ChipPopover(title: "Days") { DayCircles(days: $schedule.days) } })
                .onChange(of: editingDays) { if !$0 { frozenDaysWidth = nil } }   // release on close

            // Time chip (optional) — ANDed with the other conditions.
            if schedule.timeEnabled {
                andLabel
                Chip(icon: "clock", text: timeText, onRemove: { schedule.timeEnabled = false })
                    { editingTime = true }
                    .popover(isPresented: $editingTime, arrowEdge: .bottom) {
                        ChipPopover(title: "Time of day") { TimeEditor(window: $schedule.window) }
                    }
            }

            // Daily-limit chip (Allow-windows only) — ANDed with the other conditions.
            if baseBlocked && schedule.quotaEnabled {
                andLabel
                Chip(icon: "hourglass", text: "\(schedule.quotaMinutes)m/day",
                     tint: exhausted ? .red : .secondary,
                     onRemove: { schedule.quotaEnabled = false }) { editingLimit = true }
                    .popover(isPresented: $editingLimit, arrowEdge: .bottom) {
                        ChipPopover(title: "Daily limit") {
                            Stepper("\(schedule.quotaMinutes) min/day",
                                    value: $schedule.quotaMinutes, in: 5...240, step: 5).fixedSize()
                        }
                    }
            }

            if canAdd {
                Menu {
                    if !schedule.timeEnabled {
                        Button("Time of day") { schedule.timeEnabled = true; editingTime = true }
                    }
                    if baseBlocked && !schedule.quotaEnabled {
                        Button("Daily limit") { schedule.quotaEnabled = true; editingLimit = true }
                    }
                } label: {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a condition (AND)")
            }

            Divider().frame(height: 16)
            Text(baseBlocked ? "Allow" : "Block")
                .font(.caption.weight(.semibold))
                .foregroundStyle(baseBlocked ? .green : .red)
                .help(baseBlocked ? "Opens these sites while active" : "Blocks these sites while active")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
        .fixedSize()
    }

    private var canAdd: Bool {
        !schedule.timeEnabled || (baseBlocked && !schedule.quotaEnabled)
    }
    private var exhausted: Bool {
        schedule.quotaEnabled && store.totalUsageToday >= TimeInterval(schedule.quotaMinutes * 60)
    }
    private var timeText: String {
        "\(clock(schedule.window.startMinutes))–\(clock(schedule.window.endMinutes))"
    }
    private var daysText: String {
        let d = schedule.days
        if d == RuleSchedule.everyDay { return "Every day" }
        if d.isEmpty { return "Never" }
        let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        if d == weekdays { return "Weekdays" }
        if d == [.saturday, .sunday] { return "Weekends" }
        return Weekday.allCases.filter(d.contains).map(\.shortLabel).joined(separator: ", ")
    }
    private func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    /// Separator between a rule's condition chips (they're AND'd together).
    private var andLabel: some View {
        Text("AND").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            .help("All of a rule's conditions must match (AND)")
    }

    private func commit() {
        // Calendar exceptions manage their own condition via the picker; only the schedule kind
        // derives its condition from the editor here.
        if isCalendarException { rule.dailyLimit = nil; return }
        rule.condition = schedule.condition
        rule.dailyLimit = baseBlocked ? schedule.dailyLimit : nil   // a block-window carries no limit
    }
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
