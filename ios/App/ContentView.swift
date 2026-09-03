import SwiftUI
import RulesEngine
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: MobileStore
    @State private var editing: MobileRule?
    @AppStorage("configURL") private var configURL = ""
    @State private var importing = false
    @State private var importStatus: String?
    @State private var importFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Blocking on", isOn: Binding(
                        get: { store.isBlocking },
                        set: { $0 ? store.resume() : store.pause() }))
                    if store.canUnlock || store.isUnlocked { unlockRow }
                } footer: {
                    Text(store.isBlocking
                         ? "Sites are blocked in Safari according to each list's schedule."
                         : "Paused — nothing is blocked right now.")
                }

                Section("Blocked sites") {
                    ForEach(store.rules) { rule in
                        Button { editing = rule } label: { RuleRow(rule: rule) }
                            .tint(.primary)
                    }
                    .onDelete { $0.map { store.rules[$0] }.forEach(store.delete) }

                    Button { store.add() } label: {
                        Label("Add List", systemImage: "plus")
                    }
                }

                Section {
                    TextField("Config URL", text: $configURL,
                              prompt: Text("https://…/siteblocker-config.json"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button { runImport() } label: {
                        HStack {
                            Text("Import from URL")
                            Spacer()
                            if importing { ProgressView() }
                        }
                    }
                    .disabled(configURL.isEmpty || importing)
                    if let importStatus {
                        Text(importStatus).font(.caption)
                            .foregroundStyle(importFailed ? .red : .secondary)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Importing replaces your lists with the shared config published from your Mac — including each list's days, time window, and Face-ID gating.")
                }
            }
            .navigationTitle("SiteBlocker")
            .sheet(item: $editing) { rule in
                RuleEditor(rule: rule).environmentObject(store)
            }
        }
    }

    /// Unlock (Face ID) / Lock control for the Face-ID-gated lists, shown only when one is relevant.
    private var unlockRow: some View {
        HStack {
            if store.isUnlocked {
                Label("Unlocked", systemImage: "lock.open.fill").foregroundStyle(.green)
                Spacer()
                Button("Lock") { store.lock() }
            } else {
                Label("Locked", systemImage: "lock.fill").foregroundStyle(.secondary)
                Spacer()
                Button("Unlock") { Task { await store.unlock() } }
                    .disabled(!store.canUnlock)
            }
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
                importStatus = "Imported \(store.rules.count) lists."; importFailed = false
            } catch {
                importStatus = "Failed: \(error.localizedDescription)"; importFailed = true
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
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled" : rule.name)
                Text("\(rule.siteCountSummary) · \(rule.scheduleSummary)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Editor for one named list: the domains, plus the allow schedule (days + optional time window)
/// and optional Face-ID gating — matching the macOS rule model.
private struct RuleEditor: View {
    @EnvironmentObject private var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MobileRule
    @State private var sitesText: String
    @State private var showFileImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var importing = false
    @State private var importError: String?

    init(rule: MobileRule) {
        _rule = State(initialValue: rule)
        _sitesText = State(initialValue: rule.siteDomains.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.isEnabled)
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
                    Toggle("Require Face ID to unlock", isOn: $rule.requiresUnlock)
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(scheduleFooter)
                }

                Section {
                    TextEditor(text: $sitesText)
                        .frame(minHeight: 160)
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
            }
            .navigationTitle("Blocked List")
            .navigationBarTitleDisplayMode(.inline)
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
                        store.update(rule)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Explains the current schedule state in plain English so the allow-model isn't surprising.
    private var scheduleFooter: String {
        if rule.days.isEmpty {
            return "No days selected — these sites are always blocked. Select the days they're allowed."
        }
        var text = "Allowed on the selected days"
        text += rule.timeEnabled ? " during the time window" : " (all day)"
        text += ", and blocked otherwise."
        if rule.requiresUnlock {
            text += " While allowed, they stay blocked until you unlock with Face ID."
        }
        return text
    }

    /// Bridges minutes-since-midnight to the Date a `DatePicker(.hourAndMinute)` wants.
    private func minutesBinding(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(TimeInterval(rule.window[keyPath: keyPath] * 60))
        } set: { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.window[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
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
}

/// Seven letter toggles, like Screen Time's day picker. All selected = every day; none = never.
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func toggle(_ day: Weekday) {
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
    }
}
