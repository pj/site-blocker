import SwiftUI
import RulesEngine
import UniformTypeIdentifiers

/// One editable target row. Identity is stable across edits (unlike the domain text), so the list
/// and its selection behave while you type.
struct EditableTarget: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

// MARK: - Targets editor

struct TargetsEditor: View {
    @Binding var targets: [EditableTarget]

    @State private var selection: Set<UUID> = []
    @State private var showFileImporter = false
    @State private var showURLPrompt = false
    @State private var urlString = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: $selection) {
                ForEach($targets) { $target in
                    TextField("example.com", text: $target.text)
                        .textFieldStyle(.plain)
                }
            }
            .frame(height: 150)  // fixed: this List nests inside the rules ScrollView
            .overlay {
                if targets.isEmpty {
                    Text("No sites yet — use + or import.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Button { addRow() } label: { Image(systemName: "plus") }
                    .help("Add a site")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .help("Remove selected")
                    .disabled(selection.isEmpty)
                Spacer()
                if isDownloading { ProgressView().controlSize(.small) }
                Button("From File…") { showFileImporter = true }
                Button("From URL…") { showURLPrompt = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.plainText, .text, .commaSeparatedText, .data],
                      onCompletion: handleFileImport)
        .popover(isPresented: $showURLPrompt, arrowEdge: .bottom) { urlPrompt }
    }

    private var urlPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download blocklist").font(.headline)
            Text("A text file of domains, one per line, or hosts format (`0.0.0.0 example.com`).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://example.com/blocklist.txt", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            HStack {
                Spacer()
                Button("Cancel") { showURLPrompt = false }
                Button("Download") { Task { await download() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.isEmpty || isDownloading)
            }
        }
        .padding()
    }

    // MARK: Actions

    private func addRow() {
        let new = EditableTarget(text: "")
        targets.append(new)
        selection = [new.id]
    }

    private func removeSelected() {
        targets.removeAll { selection.contains($0.id) }
        selection = []
    }

    /// Append normalized domains that aren't already present.
    private func append(_ domains: [String]) {
        var seen = Set(targets.map { HostPattern($0.text).domain })
        for domain in domains where seen.insert(domain).inserted {
            targets.append(EditableTarget(text: domain))
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        errorMessage = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            append(TargetImport.parse(text))
        } catch {
            errorMessage = "Couldn't read file: \(error.localizedDescription)"
        }
    }

    private func download() async {
        errorMessage = nil
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "Enter a valid http(s) URL."
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        do {
            append(try await TargetImport.download(from: url))
            urlString = ""
            showURLPrompt = false
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }
}

/// Parses domain lists in plain (one-per-line) or hosts-file format, stripping comments.
enum TargetImport {
    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        text.enumerateLines { rawLine, _ in
            var line = rawLine
            if let comment = line.firstIndex(where: { $0 == "#" || $0 == "!" }) {
                line = String(line[..<comment])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            // hosts format ("0.0.0.0 example.com") → take the last token
            let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? line
            let domain = HostPattern(token).domain
            guard !domain.isEmpty, domain != "localhost", seen.insert(domain).inserted else { return }
            out.append(domain)
        }
        return out
    }

    static func download(from url: URL) async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return parse(String(decoding: data, as: UTF8.self))
    }
}
