import SwiftUI
import RulesEngine

/// The rules management screen. Each rule is a single line: its condition logic as chips with the
/// editing controls inline (chips AND together; want OR? add another rule — the engine already
/// ORs rules), a sites button that opens the list editor in a popover, the enable switch, and
/// delete. Rules have no names.
struct ContentView: View {
    @EnvironmentObject private var store: RuleStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await store.toggleBlocking() }
                } label: {
                    Label(store.blockingEnabled ? "End Block" : "Start Block",
                          systemImage: store.blockingEnabled ? "hand.raised.slash.fill"
                                                             : "hand.raised.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(store.blockingEnabled ? .red : .green)
                .help(store.blockingEnabled ? "End the block (requires authentication)"
                                            : "Start blocking")

                Text("Unblocked today: \(Self.duration(store.unblockedTimeToday))")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()
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

    private func addRule() {
        store.add(Rule(name: "", targets: [], condition: .always))
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

    @State private var chips: [Chip]
    @State private var targets: [EditableTarget]
    @State private var showSites = false

    init(rule: Rule) {
        self.rule = rule
        // Legacy OR conditions flatten into one AND group; the UI no longer builds ORs.
        _chips = State(initialValue: ChipGroup.decompose(rule.condition).flatMap(\.chips))
        _targets = State(initialValue: rule.targets.map { EditableTarget(text: $0.domain) })
    }

    var body: some View {
        HStack(spacing: 8) {
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

            sitesButton

            logicLine

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: chips) { commit() }
        .onChange(of: targets) { commit() }
    }

    // MARK: Logic line

    private var logicLine: some View {
        HStack(spacing: 6) {
            if chips.isEmpty {
                Text("Always")
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
            }

            ForEach($chips) { $chip in
                ChipView(chip: $chip, onRemove: { chips.removeAll { $0.id == chip.id } })
            }

            let missing = missingKinds()
            if !missing.isEmpty {
                Menu {
                    ForEach(missing, id: \.self) { kind in
                        Button(kind.addLabel) {
                            chips.append(Chip(atom: kind.defaultAtom))
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("AND another condition")
            }
        }
    }

    private func missingKinds() -> [AtomKind] {
        let present = Set(chips.map(\.atom.kind))
        return AtomKind.allCases.filter { !present.contains($0) }
    }

    // MARK: Sites

    private var sitesButton: some View {
        Button {
            showSites = true
        } label: {
            Label("\(rule.targets.count) sites", systemImage: "list.bullet")
        }
        .controlSize(.small)
        .popover(isPresented: $showSites, arrowEdge: .bottom) {
            TargetsEditor(targets: $targets)
                .padding(12)
                .frame(width: 400)
        }
        .help("Edit blocked sites")
    }

    // MARK: Commit

    private func commit() {
        var updated = rule
        updated.targets = normalizedTargets()
        updated.condition = ChipGroup.compose([ChipGroup(chips: chips)])
        store.update(updated)
    }

    /// The saved rule gets normalized, deduped hosts; the editor rows keep the raw text so typing
    /// isn't fought by normalization.
    private func normalizedTargets() -> [HostPattern] {
        var seen = Set<String>()
        var out: [HostPattern] = []
        for target in targets {
            let host = HostPattern(target.text)
            guard !host.domain.isEmpty, seen.insert(host.domain).inserted else { continue }
            out.append(host)
        }
        return out
    }
}

// MARK: - Chips (controls live inline, inside the chip)

private struct ChipView: View {
    @EnvironmentObject private var store: RuleStore
    @Binding var chip: Chip
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch chip.atom {
            case .days: DaysChipControls(chip: $chip)
            case .time: TimeChipControls(chip: $chip)
            case .quota: QuotaChipControls(chip: $chip)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove condition")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(quotaExhausted ? Color.red.opacity(0.15)
                                                  : Color.secondary.opacity(0.10)))
        .overlay(Capsule().strokeBorder(quotaExhausted ? Color.red.opacity(0.6)
                                                       : Color.secondary.opacity(0.25)))
    }

    /// A usage chip goes red once today's allowance is spent.
    private var quotaExhausted: Bool {
        if case .quota(let limit) = chip.atom { return store.unblockedTimeToday >= limit }
        return false
    }
}

/// Seven letter toggles, like Screen Time's day picker.
private struct DaysChipControls: View {
    @Binding var chip: Chip

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = isOn(day)
                Button(day.letter) { toggle(day) }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(on ? Color.accentColor
                                                 : Color.secondary.opacity(0.15)))
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .help(day.shortLabel)
            }
        }
    }

    private func isOn(_ day: Weekday) -> Bool {
        if case .days(let days) = chip.atom { return days.contains(day) }
        return false
    }

    private func toggle(_ day: Weekday) {
        guard case .days(var days) = chip.atom else { return }
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
        chip.atom = .days(days)
    }
}

private struct TimeChipControls: View {
    @Binding var chip: Chip

    var body: some View {
        HStack(spacing: 3) {
            DatePicker("", selection: minutesBinding(\.startMinutes),
                       displayedComponents: .hourAndMinute)
            Text("–").foregroundStyle(.secondary)
            DatePicker("", selection: minutesBinding(\.endMinutes),
                       displayedComponents: .hourAndMinute)
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Bridges minutes-since-midnight to the Date a `DatePicker(.hourAndMinute)` wants.
    private func minutesBinding(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding {
            guard case .time(let window) = chip.atom else { return Date() }
            return Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(TimeInterval(window[keyPath: keyPath] * 60))
        } set: { date in
            guard case .time(var window) = chip.atom else { return }
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            window[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            chip.atom = .time(window)
        }
    }
}

private struct QuotaChipControls: View {
    @Binding var chip: Chip

    var body: some View {
        Stepper("\(minutes) min/day", value: minutesBinding, in: 5...240, step: 5)
            .font(.callout)
            .fixedSize()
            .help("Daily allowance of unblocked time — counts down while the block is off; at zero these sites re-block even with the block off")
    }

    private var minutes: Int {
        if case .quota(let limit) = chip.atom { return Int(limit / 60) }
        return 30
    }

    private var minutesBinding: Binding<Int> {
        Binding { minutes } set: { chip.atom = .quota(TimeInterval($0 * 60)) }
    }
}
