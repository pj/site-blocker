import SwiftUI
import RulesEngine

/// One editable target row. Identity is stable across edits (unlike the domain text), so the list
/// and its selection behave while you type.
struct EditableTarget: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

// MARK: - Manual targets editor

/// The hand-edited site list: one row per domain, standard +/- buttons. File- and URL-backed
/// lists are configured in `SourceEditor` instead.
struct TargetsEditor: View {
    @Binding var targets: [EditableTarget]

    @State private var selection: Set<UUID> = []

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
                    Text("No sites yet — use + to add one.")
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
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func addRow() {
        let new = EditableTarget(text: "")
        targets.append(new)
        selection = [new.id]
    }

    private func removeSelected() {
        targets.removeAll { selection.contains($0.id) }
        selection = []
    }
}

/// Parses domain lists in plain (one-per-line) or hosts-file format. Handles the comment styles
/// common to public blocklists (e.g. HaGeZi, AdGuard, Steven Black hosts): full-line and trailing
/// comments introduced by `#`, `!`, or `;` are stripped, blank lines skipped, and hosts-format
/// lines ("0.0.0.0 example.com") reduced to the domain.
enum TargetImport {
    private static let commentMarkers: Set<Character> = ["#", "!", ";"]

    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        text.enumerateLines { rawLine, _ in
            var line = rawLine
            if let comment = line.firstIndex(where: { commentMarkers.contains($0) }) {
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
