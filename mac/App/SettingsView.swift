import SwiftUI

/// The ⌘, settings window: import the shared rules config from a URL. Export is the CLI
/// `just publish-config` on the source-of-truth Mac, so it's documented here, not a button.
struct SettingsView: View {
    @EnvironmentObject private var store: RuleStore
    @AppStorage("configURL") private var configURL = ""
    @State private var importing = false
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                TextField("Config URL", text: $configURL, prompt: Text("https://…/siteblocker-config.json"))
                    .textContentType(.URL)
                HStack {
                    Button("Import") { runImport() }
                        .disabled(configURL.isEmpty || importing)
                    if importing { ProgressView().controlSize(.small) }
                    if let status { Text(status).font(.callout).foregroundStyle(failed ? .red : .secondary) }
                }
            } footer: {
                Text("Importing replaces your rules with the shared config. Publish the config from your source-of-truth Mac with `just publish-config`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    private func runImport() {
        guard let url = URL(string: configURL.trimmingCharacters(in: .whitespaces)) else {
            status = "Invalid URL"; failed = true; return
        }
        importing = true; status = nil; failed = false
        Task {
            defer { importing = false }
            do {
                try await store.importConfig(from: url)
                status = "Imported \(store.rules.count) rules."; failed = false
            } catch {
                status = "Failed: \(error.localizedDescription)"; failed = true
            }
        }
    }
}
