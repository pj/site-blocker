import SwiftUI
import RulesEngine

/// Top level: a list of **site lists**. Each drills down to an editor with the list's domains, its
/// default, and an ordered sublist of Allow/Deny **rules** (first active rule wins).
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
                } footer: { Text(lockFooter) }

                Section("Site lists") {
                    ForEach($store.lists) { $list in
                        NavigationLink { ListEditView(list: $list) } label: { ListRow(list: list) }
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
            Text("Importing replaces your lists with the shared config from your Mac (each becomes a list with one Allow rule).")
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
    var body: some View {
        HStack {
            Circle().fill(list.isEnabled ? Color.green : Color.secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name.isEmpty ? "Untitled" : list.name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var subtitle: String {
        let sites = "\(list.domains.count) site\(list.domains.count == 1 ? "" : "s")"
        let rules = "\(list.rules.count) rule\(list.rules.count == 1 ? "" : "s")"
        return "\(sites) · \(rules) · default \(list.defaultAllowed ? "Allowed" : "Blocked")"
    }
}

// MARK: - List editor

private struct ListEditView: View {
    @Binding var list: SiteList
    @State private var domainsText = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $list.name)
                Toggle("Enabled", isOn: $list.isEnabled)
                Picker("When no rule matches", selection: $list.defaultAllowed) {
                    Text("Blocked").tag(false)
                    Text("Allowed").tag(true)
                }
            }

            Section {
                ForEach($list.rules) { $rule in
                    NavigationLink { RuleEditView(rule: $rule) } label: { RuleSummaryRow(rule: rule) }
                }
                .onDelete { list.rules.remove(atOffsets: $0) }
                .onMove { list.rules.move(fromOffsets: $0, toOffset: $1) }
                Button { list.rules.append(ListRule()) } label: { Label("Add Rule", systemImage: "plus") }
            } header: {
                Text("Rules (first active rule wins)")
            } footer: {
                Text("Checked top to bottom; the first rule active right now decides. If none match, the default applies.")
            }

            Section {
                TextEditor(text: $domainsText)
                    .frame(minHeight: 140).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).font(.body.monospaced())
            } header: { Text("Websites") } footer: {
                Text("One domain per line, or hosts format. # ! ; comments are handled.")
            }
        }
        .navigationTitle(list.name.isEmpty ? "List" : list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear { domainsText = list.domains.joined(separator: "\n") }
        .onChange(of: domainsText) { newValue in list.domains = SiteRuleset.parse(newValue) }
    }
}

private struct RuleSummaryRow: View {
    let rule: ListRule
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rule.action == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(rule.action == .allow ? .green : .red)
                .opacity(rule.isEnabled ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.action == .allow ? "Allow" : "Deny").font(.body)
                Text(RuleFormat.schedule(rule)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Rule editor

private struct RuleEditView: View {
    @Binding var rule: ListRule

    var body: some View {
        Form {
            Section {
                Picker("Action", selection: $rule.action) {
                    Text("Allow").tag(RuleAction.allow)
                    Text("Deny").tag(RuleAction.deny)
                }
                .pickerStyle(.segmented)
                Toggle("Enabled", isOn: $rule.isEnabled)
            } footer: {
                Text(rule.action == .allow ? "Allow these sites while this rule is active."
                                           : "Block these sites while this rule is active.")
            }

            Section {
                DaysPicker(days: $rule.days)
                Toggle("Time of day", isOn: $rule.timeEnabled)
                if rule.timeEnabled {
                    HStack {
                        DatePicker("From", selection: minutesBinding(\.startMinutes),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: minutesBinding(\.endMinutes),
                                   displayedComponents: .hourAndMinute)
                    }
                }
            } header: { Text("Applies on") } footer: {
                Text("No days selected = the rule never applies.")
            }

            if rule.action == .allow {
                Section {
                    Toggle("Daily limit (Face ID)", isOn: Binding(
                        get: { rule.dailyLimitMinutes != nil },
                        set: { rule.dailyLimitMinutes = $0 ? (rule.dailyLimitMinutes ?? 30) : nil }))
                    if let minutes = rule.dailyLimitMinutes {
                        Stepper("\(minutes) min/day", value: Binding(
                            get: { minutes },
                            set: { rule.dailyLimitMinutes = $0 }), in: 5...240, step: 5)
                    }
                } footer: {
                    Text("With a limit, these sites need a Face ID unlock and stay open until the shared daily budget is spent.")
                }
            }
        }
        .navigationTitle(rule.action == .allow ? "Allow rule" : "Deny rule")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(TimeInterval(rule.window[keyPath: keyPath] * 60))
        } set: { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.window[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }
    }
}

// MARK: - Shared bits

/// Human-readable schedule summary for a rule row.
enum RuleFormat {
    static func schedule(_ rule: ListRule) -> String {
        var parts: [String] = [days(rule.days)]
        if rule.timeEnabled {
            parts.append("\(clock(rule.window.startMinutes))–\(clock(rule.window.endMinutes))")
        }
        if let m = rule.dailyLimitMinutes { parts.append("\(m) min/day") }
        if !rule.isEnabled { parts.append("(off)") }
        return parts.joined(separator: " · ")
    }
    private static func days(_ set: Set<Weekday>) -> String {
        if set.isEmpty { return "never" }
        if set == Set(Weekday.allCases) { return "every day" }
        return Weekday.allCases.filter(set.contains).map(\.shortLabel).joined(separator: ", ")
    }
    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// Seven letter toggles, like Screen Time's day picker.
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
