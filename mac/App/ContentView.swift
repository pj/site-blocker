import SwiftUI
import RulesEngine

/// The rules management screen. Each rule is a single line: three static condition controls (which
/// days, an optional time-of-day window, an optional daily unblocked-time limit — all ANDed; want
/// OR? add another rule, the engine ORs rules), a sites button that opens the list editor in a
/// popover, the enable switch, and delete. An optional free-text name labels the row (purely a
/// guide for the user — it has no effect on matching).
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
                .help(store.isUnlocked ? "Lock now"
                                       : (store.canUnlock ? "Unlock the allowed sites (Touch ID)"
                                                          : "Nothing is allowed right now"))

                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Viewed today: \(Self.duration(store.totalUsageToday))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.rules) { rule in
                        RuleRow(rule: rule)
                        Divider()
                    }
                }
            }
            .overlay {
                if store.rules.isEmpty {
                    ContentUnavailableView("No Rules", systemImage: "hand.raised",
                                           description: Text("Add a rule to start blocking."))
                }
            }

            Divider()
            HStack {
                Button { addRule() } label: { Label("Add Rule", systemImage: "plus") }
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 880, minHeight: 380)
    }

    private var statusText: String {
        if store.isUnlocked { return "Unlocked" }
        if store.openAccessActive {
            return store.canUnlock ? "Some sites open · unlock available" : "Some sites open now"
        }
        return store.canUnlock ? "Locked — unlock available" : "Locked — no allowance active now"
    }

    private func addRule() {
        store.add(Rule())
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Rule row

/// One rule on one line, edited fully in place; every change commits straight back to the store.
private struct RuleRow: View {
    @EnvironmentObject private var store: RuleStore
    let rule: Rule

    @State private var schedule: RuleSchedule
    @State private var name: String
    @State private var showSites = false

    init(rule: Rule) {
        self.rule = rule
        _schedule = State(initialValue: RuleSchedule(condition: rule.condition,
                                                     dailyLimit: rule.dailyLimit))
        _name = State(initialValue: rule.name)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { Task { await store.deleteAuthenticated(rule) } } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete rule (requires authentication)")

            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in Task { await store.toggleRuleAuthenticated(rule) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(rule.isEnabled ? "Disable rule (requires authentication)"
                                     : "Enable rule (requires authentication)")

            LabeledControl(title: "Name") {
                TextField("Optional", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }

            sitesButton

            Divider().frame(height: 34)

            DaysControl(days: $schedule.days)
            TimeControl(enabled: $schedule.timeEnabled, window: $schedule.window)
            QuotaControl(enabled: $schedule.quotaEnabled, minutes: $schedule.quotaMinutes, rule: rule)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: schedule) { commit() }
        .onChange(of: name) { commit() }
    }

    private var sitesButton: some View {
        Button {
            showSites = true
        } label: {
            Label(sitesSummary, systemImage: sitesIcon)
        }
        .controlSize(.small)
        .popover(isPresented: $showSites, arrowEdge: .bottom) {
            SourceEditor(rule: rule)
                .padding(12)
                .frame(width: 400)
        }
        .help("Edit blocked sites")
    }

    /// An SF Symbol hinting where the list comes from: hand-edited, a local file, or a URL blocklist.
    private var sitesIcon: String {
        switch rule.source {
        case .manual: return "list.bullet"
        case .file:   return "doc"
        case .remote: return "link"
        }
    }

    /// Summarise the source *and* its size so a file/URL list doesn't read as "1 site". Manual lists
    /// just show the count; file/remote lists prefix the kind (the count is what they resolved to).
    private var sitesSummary: String {
        let n = rule.targets.count
        let sites = "\(n.formatted()) \(n == 1 ? "site" : "sites")"
        switch rule.source {
        case .manual: return sites
        case .file:   return "File · \(sites)"
        case .remote: return "URL list · \(sites)"
        }
    }

    private func commit() {
        var updated = rule
        updated.name = name
        updated.condition = schedule.condition
        updated.dailyLimit = schedule.dailyLimit
        store.update(updated)
    }
}

// MARK: - Static condition controls

/// A control group with a small caption above its control, so every rule shows the same columns.
private struct LabeledControl<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            control
        }
    }
}

/// Seven letter toggles, like Screen Time's day picker. All selected = every day.
private struct DaysControl: View {
    @Binding var days: Set<Weekday>

    var body: some View {
        LabeledControl(title: "Days") {
            HStack(spacing: 3) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    let on = days.contains(day)
                    // Style lives inside the label (with an explicit contentShape) so the whole
                    // circle is the tap target — a `.plain` button only hit-tests its label, so
                    // frame/background applied outside it would leave just the letter clickable.
                    Button { toggle(day) } label: {
                        Text(day.letter)
                            .font(.caption2.weight(.semibold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(on ? Color.accentColor
                                                         : Color.secondary.opacity(0.15)))
                            .foregroundStyle(on ? Color.white : Color.secondary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(day.shortLabel)
                }
            }
        }
    }

    private func toggle(_ day: Weekday) {
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
    }
}

/// A checkbox that gates an optional time-of-day window; the pickers dim when it's off.
private struct TimeControl: View {
    @Binding var enabled: Bool
    @Binding var window: TimeWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $enabled) { Text("Time of day").font(.caption2) }
                .toggleStyle(.checkbox)
            HStack(spacing: 3) {
                DatePicker("", selection: minutesBinding(\.startMinutes),
                           displayedComponents: .hourAndMinute)
                Text("–").foregroundStyle(.secondary)
                DatePicker("", selection: minutesBinding(\.endMinutes),
                           displayedComponents: .hourAndMinute)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }

    /// Bridges minutes-since-midnight to the Date a `DatePicker(.hourAndMinute)` wants.
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

/// A checkbox that gates an optional daily budget of viewing time; goes red once spent.
private struct QuotaControl: View {
    @EnvironmentObject private var store: RuleStore
    @Binding var enabled: Bool
    @Binding var minutes: Int
    let rule: Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $enabled) { Text("Daily limit").font(.caption2) }
                .toggleStyle(.checkbox)
                .help("Off: these sites are simply available during the window — no unlock, no timer. On: they're unlock-gated (Touch ID) and drain the daily budget below.")
            Stepper("\(minutes) min/day", value: $minutes, in: 5...240, step: 5)
                .font(.callout)
                .fixedSize()
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .foregroundStyle(exhausted ? Color.red : Color.primary)
                .help("Daily budget of viewing time — drains while unlocked; at zero these sites re-block for the rest of the day")
        }
    }

    private var exhausted: Bool {
        enabled && store.totalUsageToday >= TimeInterval(minutes * 60)
    }
}
