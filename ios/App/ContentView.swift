import SwiftUI
import FamilyControls
import UniformTypeIdentifiers
import RulesEngine

struct ContentView: View {
    @EnvironmentObject private var store: MobileStore
    @State private var editing: MobileRule?

    var body: some View {
        NavigationStack {
            List {
                if !store.isAuthorized {
                    Section {
                        Button("Enable Screen Time access") {
                            Task { await store.requestAuthorization() }
                        }
                    } footer: {
                        Text("Required to block apps and websites. Approve the Screen Time prompt.")
                    }
                }

                Section {
                    Toggle("Block everything now", isOn: Binding(
                        get: { store.isLocked },
                        set: { $0 ? store.lock() : store.unlock() }))
                } footer: {
                    Text(store.isLocked
                         ? "Override on — everything is blocked regardless of schedule."
                         : "Rules enforce automatically on their days, times, and limits.")
                }

                Section("Rules") {
                    ForEach(store.rules) { rule in
                        Button { editing = rule } label: { RuleRow(rule: rule) }
                            .tint(.primary)
                    }
                    .onDelete { $0.map { store.rules[$0] }.forEach(store.delete) }

                    Button { store.add() } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("SiteBlocker")
            .sheet(item: $editing) { rule in
                RuleEditor(rule: rule).environmentObject(store)
            }
        }
    }
}

private struct RuleRow: View {
    let rule: MobileRule
    var body: some View {
        HStack {
            Circle()
                .fill(rule.isEnabled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(rule.name.isEmpty ? "Untitled" : rule.name)
                Text(rule.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Inline editor: pick apps/sites via the Family Controls picker, then set the schedule.
private struct RuleEditor: View {
    @EnvironmentObject private var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MobileRule
    @State private var pickerShown = false
    @State private var timeEnabled: Bool
    @State private var limitEnabled: Bool
    @State private var sitesText: String
    @State private var showFileImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var importing = false
    @State private var importError: String?

    init(rule: MobileRule) {
        _rule = State(initialValue: rule)
        _timeEnabled = State(initialValue: rule.window != nil)
        _limitEnabled = State(initialValue: rule.dailyLimitMinutes != nil)
        _sitesText = State(initialValue: rule.siteDomains.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.isEnabled)
                }

                Section("Apps") {
                    Button("Choose apps…") { pickerShown = true }
                    Text(rule.summary).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $sitesText)
                        .frame(minHeight: 110)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                    HStack {
                        Button { showFileImporter = true } label: { Label("Import file", systemImage: "doc") }
                        Spacer()
                        Button { urlText = ""; showURLPrompt = true } label: { Label("Import URL", systemImage: "link") }
                        if importing { ProgressView().padding(.leading, 6) }
                    }
                    .font(.callout)
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Websites")
                } footer: {
                    Text("One domain per line, or import a list from a file or URL — hosts format and # ! ; comments are handled. Blocks in Safari (and in-app Safari views).")
                }

                Section("Days") {
                    HStack {
                        ForEach(Weekday.allCases, id: \.self) { day in
                            let on = rule.days.contains(day)
                            Button(day.shortName) {
                                if on { rule.days.remove(day) } else { rule.days.insert(day) }
                            }
                            .font(.caption).frame(maxWidth: .infinity)
                            .foregroundStyle(on ? .white : .secondary)
                            .padding(.vertical, 6)
                            .background(on ? Color.accentColor : Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Time of day") {
                    Toggle("Only between times", isOn: $timeEnabled)
                    if timeEnabled {
                        DatePicker("From", selection: bind(\.startMinutes), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: bind(\.endMinutes), displayedComponents: .hourAndMinute)
                    }
                }

                Section("Daily limit") {
                    Toggle("Limit usage per day", isOn: $limitEnabled)
                    if limitEnabled {
                        Stepper("\(rule.dailyLimitMinutes ?? 30) min/day",
                                value: Binding(get: { rule.dailyLimitMinutes ?? 30 },
                                               set: { rule.dailyLimitMinutes = $0 }),
                                in: 5...240, step: 5)
                    }
                }
            }
            .navigationTitle("Rule")
            .familyActivityPicker(isPresented: $pickerShown, selection: $rule.selection)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.plainText, .text, .commaSeparatedText, .data]) { result in
                if case .success(let url) = result { importFile(url) }
            }
            .alert("Import from URL", isPresented: $showURLPrompt) {
                TextField("https://example.com/blocklist.txt", text: $urlText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Import") { importURL() }
            } message: {
                Text("A text file of domains — one per line, or hosts format.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        rule.siteDomains = SiteRuleset.parse(sitesText)
                        rule.window = timeEnabled ? (rule.window ?? TimeWindow(startHour: 9, endHour: 17)) : nil
                        if !limitEnabled { rule.dailyLimitMinutes = nil }
                        else if rule.dailyLimitMinutes == nil { rule.dailyLimitMinutes = 30 }
                        store.update(rule)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Merge imported domains into the text area (parsed + de-duplicated against what's there).
    private func appendDomains(_ domains: [String]) {
        let existing = SiteRuleset.parse(sitesText)
        let merged = existing + domains.filter { !existing.contains($0) }
        sitesText = merged.joined(separator: "\n")
    }

    private func importFile(_ url: URL) {
        importError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            appendDomains(SiteRuleset.parse(try String(contentsOf: url, encoding: .utf8)))
        } catch {
            importError = "Couldn't read file: \(error.localizedDescription)"
        }
    }

    private func importURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            importError = "Enter a valid http(s) URL."
            return
        }
        importError = nil
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                appendDomains(SiteRuleset.parse(String(decoding: data, as: UTF8.self)))
            } catch {
                importError = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Bridge minutes-since-midnight to the Date a `DatePicker(.hourAndMinute)` wants.
    private func bind(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding {
            let w = rule.window ?? TimeWindow(startHour: 9, endHour: 17)
            return Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(w[keyPath: keyPath] * 60))
        } set: { date in
            var w = rule.window ?? TimeWindow(startHour: 9, endHour: 17)
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            w[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            rule.window = w
        }
    }
}
