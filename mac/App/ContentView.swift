import SwiftUI
import RulesEngine

/// The management screen. Each **site list** is a card: its sites (a manual/file/URL source), a
/// default (Allowed/Blocked when no rule is active), and an *ordered* list of Allow/Deny **rules**
/// (first active rule wins). Rules OR together within their action; edit fully in place.
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
                .disabled(!store.isUnlocked && !store.canUnlock)

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
                Button { store.add(SiteList(name: "New List", rules: [SiteList.defaultRule()])) } label: {
                    Label("Add List", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 900, minHeight: 420)
    }

    private var statusText: String {
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

            // 4. Sub rules.
            RulesColumn(list: $list)

            // 5. Enable / disable (right side).
            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { _ in Task { await store.toggleListAuthenticated(list) } }))
                .toggleStyle(.switch).labelsHidden()
                .help(list.isEnabled ? "Disable list (auth)" : "Enable list (auth)")

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
        if !list.isEnabled { return .secondary }
        return store.blockedListIDs.contains(list.id) ? .red : .green
    }
    private var statusText: String {
        if !list.isEnabled { return "Disabled" }
        return store.blockedListIDs.contains(list.id) ? "Blocked now" : "Open now"
    }
    /// A faint tint of the current status behind the whole row.
    private var rowColor: Color {
        if !list.isEnabled { return Color.gray.opacity(0.14) }
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

/// Column 2: the ordered rules. The last rule is the catch-all default — always present, pinned at
/// the bottom, and not removable; "Add Rule" inserts a new rule just before it.
private struct RulesColumn: View {
    @Binding var list: SiteList
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($list.rules) { $rule in
                RuleRow(rule: $rule,
                        isFirst: rule.id == list.rules.first?.id,
                        isDefault: rule.id == list.rules.last?.id) {
                    list.rules.removeAll { $0.id == rule.id }
                }
            }
            Button { list.rules.insert(ListRule(), at: max(0, list.rules.count - 1)) } label: {
                Label("Add Rule", systemImage: "plus").font(.callout)
            }
            .buttonStyle(.borderless).padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Green Allow / red Deny chip with a menu to switch. Shared by rules and the list default.
private struct ActionChip: View {
    let isAllow: Bool
    var help: String = ""
    let onSet: (Bool) -> Void
    var body: some View {
        Menu {
            Button("Allow") { onSet(true) }
            Button("Deny") { onSet(false) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isAllow ? "checkmark.circle.fill" : "xmark.circle.fill").font(.caption2)
                Text(isAllow ? "Allow" : "Deny").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(isAllow ? Color.green : Color.red))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(help)
    }
}


// MARK: - Rule row (one Allow/Deny rule, chip-based)

private struct RuleRow: View {
    @EnvironmentObject private var store: RuleStore
    @Binding var rule: ListRule
    let isFirst: Bool
    /// The last rule in a list is the catch-all default: pure Allow/Deny, no conditions, not removable.
    let isDefault: Bool
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

    init(rule: Binding<ListRule>, isFirst: Bool, isDefault: Bool, onDelete: @escaping () -> Void) {
        _rule = rule
        self.isFirst = isFirst
        self.isDefault = isDefault
        self.onDelete = onDelete
        _schedule = State(initialValue: RuleSchedule(condition: rule.wrappedValue.condition,
                                                     dailyLimit: rule.wrappedValue.dailyLimit))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("OR").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                .opacity(isFirst ? 0 : 1)   // hidden on the first rule, but keeps the box aligned
                .help("A list's rules are OR'd — any matching rule applies")

            chipBox

            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove rule")
                .opacity(isDefault ? 0 : 1)          // the default (last) rule can't be removed
                .disabled(isDefault)                  // but keep its slot so rows stay aligned

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .onChange(of: schedule) { commit() }
        .onChange(of: rule.action) { commit() }
    }

    /// The rule's Allow/Deny action then its conditions (AND'd), boxed together.
    /// The default rule is a pure catch-all: just the Allow/Deny action, no conditions.
    private var chipBox: some View {
        HStack(spacing: 6) {
            actionChip

            if !isDefault {
            Divider().frame(height: 16)

            // Days chip (always present — a rule always applies on some days).
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

            // Daily-limit chip (Allow rules only) — ANDed with the other conditions.
            if rule.action == .allow && schedule.quotaEnabled {
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
                    if rule.action == .allow && !schedule.quotaEnabled {
                        Button("Daily limit") { schedule.quotaEnabled = true; editingLimit = true }
                    }
                } label: {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a condition (AND)")
            }
            }   // end if !isDefault
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
        .fixedSize()
    }

    private var canAdd: Bool {
        !schedule.timeEnabled || (rule.action == .allow && !schedule.quotaEnabled)
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

    /// Allow/Deny as a chip at the start of the box.
    private var actionChip: some View {
        ActionChip(isAllow: rule.action == .allow,
                   help: "Allow or deny these sites when this rule matches") {
            rule.action = $0 ? .allow : .deny
        }
    }

    private func commit() {
        if isDefault {                       // catch-all: always active, no limit
            rule.condition = .always
            rule.dailyLimit = nil
            return
        }
        rule.condition = schedule.condition
        rule.dailyLimit = rule.action == .allow ? schedule.dailyLimit : nil
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
