import Foundation
import NetworkExtension

// Entry point for the content-filter system extension. `startSystemExtensionMode()` reads the
// NEProviderClasses map from Info.plist and instantiates `FilterDataProvider` on demand, then the
// process parks on the main dispatch queue waiting for flows.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
