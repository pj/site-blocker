import UIKit
import MobileCoreServices

/// Safari Content Blocker entry point. Safari asks the extension for its rule JSON here (and again
/// each time the app calls `SFContentBlockerManager.reloadContentBlocker`). We serve the JSON the
/// app regenerates into the shared App Group container; a bundled empty ruleset is the fallback.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    private static let appGroup = "group.com.pauljohnson.siteblocker"

    func beginRequest(with context: NSExtensionContext) {
        let shared = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("blockerList.json")
        let url: URL? =
            (shared.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? Bundle.main.url(forResource: "blockerList", withExtension: "json")

        guard let url, let attachment = NSItemProvider(contentsOf: url) else {
            context.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let item = NSExtensionItem()
        item.attachments = [attachment]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
