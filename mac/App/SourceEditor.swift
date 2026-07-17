import SwiftUI
import RulesEngine
import UniformTypeIdentifiers

/// The sites popover: pick where a rule's site list comes from — hand-edited, a local file managed
/// externally, or a blocklist URL — and configure it. The three are mutually exclusive; file/URL
/// lists are read-only here because the file or server is the source of truth.
struct SourceEditor: View {
    @EnvironmentObject private var store: RuleStore
    let rule: Rule

    enum Kind: String, CaseIterable {
        case manual = "Manual", file = "File", url = "URL"
    }

    @State private var kind: Kind
    @State private var manualRows: [EditableTarget]
    @State private var urlString: String
    @State private var showFilePicker = false

    init(rule: Rule) {
        self.rule = rule
        switch rule.source {
        case .manual(let hosts):
            _kind = State(initialValue: .manual)
            _manualRows = State(initialValue: hosts.map { EditableTarget(text: $0.domain) })
            _urlString = State(initialValue: "")
        case .file:
            _kind = State(initialValue: .file)
            _manualRows = State(initialValue: [])
            _urlString = State(initialValue: "")
        case .remote(let url):
            _kind = State(initialValue: .url)
            _manualRows = State(initialValue: [])
            _urlString = State(initialValue: url.absoluteString)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .manual: manualEditor
            case .file: fileEditor
            case .url: urlEditor
            }
        }
        .onChange(of: kind) { kindChanged() }
        .onChange(of: manualRows) { commitManual() }
    }

    // MARK: Manual

    private var manualEditor: some View {
        TargetsEditor(targets: $manualRows)
    }

    private func kindChanged() {
        switch kind {
        case .manual:
            // Start from the current resolved list so switching away from file/URL loses nothing.
            manualRows = rule.targets.map { EditableTarget(text: $0.domain) }
            commitManual()
        case .file, .url:
            // Nothing committed until a file is chosen / a URL applied; the rule keeps its
            // previous source and cached targets in the meantime.
            break
        }
    }

    private func commitManual() {
        guard kind == .manual else { return }
        store.setSource(rule, source: .manual(normalized(manualRows)))
    }

    /// The saved rule gets normalized, deduped hosts; the rows keep raw text so typing isn't
    /// fought by normalization.
    private func normalized(_ rows: [EditableTarget]) -> [HostPattern] {
        var seen = Set<String>()
        var out: [HostPattern] = []
        for row in rows {
            let host = HostPattern(row.text)
            guard !host.domain.isEmpty, seen.insert(host.domain).inserted else { continue }
            out.append(host)
        }
        return out
    }

    // MARK: File

    private var fileEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Choose File…") { showFilePicker = true }
                Text(store.fileDisplayPath(for: rule) ?? "No file selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("One domain per line, or hosts format. Edit the file anywhere — changes apply "
                 + "within seconds.")
                .font(.caption2).foregroundStyle(.secondary)
            statusLine
            preview
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.plainText, .text, .commaSeparatedText, .data]) { result in
            if case .success(let url) = result {
                store.setFileSource(rule, url: url)
            }
        }
    }

    // MARK: URL

    private var urlEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("https://example.com/blocklist.txt", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyURL)
                Button(isCurrentURL ? "Refresh" : "Apply") {
                    isCurrentURL ? store.refreshSource(rule) : applyURL()
                }
                .disabled(URL(string: urlString.trimmingCharacters(in: .whitespaces)) == nil)
            }
            Text("Re-fetched every few hours; the last successful list is kept if a fetch fails.")
                .font(.caption2).foregroundStyle(.secondary)
            statusLine
            preview
        }
    }

    private var isCurrentURL: Bool {
        if case .remote(let url) = rule.source {
            return url.absoluteString == urlString.trimmingCharacters(in: .whitespaces)
        }
        return false
    }

    private func applyURL() {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return
        }
        store.setSource(rule, source: .remote(url))
    }

    // MARK: Shared

    @ViewBuilder
    private var statusLine: some View {
        let status = store.sourceStatus[rule.id]
        if let error = status?.error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let updated = status?.lastUpdated {
            Text("Updated \(updated.formatted(date: .omitted, time: .shortened)) — "
                 + "\(rule.targets.count) sites")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        List(rule.targets, id: \.domain) { host in
            Text(host.domain)
        }
        .frame(height: 150)
        .overlay {
            if rule.targets.isEmpty {
                Text("No sites loaded yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
