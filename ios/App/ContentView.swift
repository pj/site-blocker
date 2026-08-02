import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: MobileStore
    @State private var editing: MobileRule?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Blocking on", isOn: Binding(
                        get: { store.isBlocking },
                        set: { $0 ? store.resume() : store.pause() }))
                } footer: {
                    Text(store.isBlocking
                         ? "Enabled rules' sites are blocked in Safari."
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

/// Editor for one named list of blocked domains: type them, or import from a file or URL.
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
            .navigationTitle("Blocked Sites")
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
