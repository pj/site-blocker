import SwiftUI
import AppKit
import AppIntents
import Combine
import RulesEngine
import Sparkle

@main
struct SiteBlockerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All UI is driven from AppDelegate via an AppKit NSStatusItem + NSMenu of *standard* menu
        // items (the shape Karabiner-Elements uses). Only real menu tracking keeps an auto-hiding
        // system menu bar revealed, and custom NSHostingView items inside menus lay out unreliably,
        // so everything is a native item. The Settings scene backs the standard ⌘, window, where
        // the Config URL / Import lives.
        Settings {
            SettingsView().environmentObject(appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: RuleStore
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var toggleItem: NSMenuItem!
    private var usageItem: NSMenuItem!
    private var managementWindow: NSWindow?
    private var iconSync: AnyCancellable?
    // startingUpdater: true launches the standard Sparkle update-checking machinery (background
    // scheduled checks + user-facing UI) as soon as the controller is created.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    #if ENABLE_NETWORK_EXTENSION
    private let enforcer: SystemExtensionEnforcer
    #endif

    override init() {
        #if ENABLE_NETWORK_EXTENSION
        let enforcer = SystemExtensionEnforcer()
        self.enforcer = enforcer
        store = RuleStore(enforcer: enforcer)
        #else
        store = RuleStore(enforcer: MockEnforcer())
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if ENABLE_NETWORK_EXTENSION
        // Request activation here, not in init(): OSSystemExtensionManager needs a live main run
        // loop, and a request submitted from init() is silently dropped (no request ever reaches
        // sysextd, so no approval prompt appears). The first successful request prompts the user
        // to approve the extension in System Settings › General › Login Items & Extensions.
        enforcer.activateAndEnable()
        #endif

        Notifier.requestAuthorization()   // for budget-countdown alerts while unlocked
        AppDependencyManager.shared.add(dependency: self.store)   // lets App Intents reach the store

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        // An NSMenu of standard items only, not an NSPopover: the system keeps an auto-hiding menu
        // bar revealed only while a real menu is tracking, and custom NSHostingView items misplace
        // their content. The key equivalent renders the ⌃⌥⌘B hint natively; the Carbon hotkey
        // (which handles the global case) intercepts the combo before it reaches the menu, so it
        // won't fire twice.
        menu = NSMenu()
        menu.autoenablesItems = false   // we drive the Unlock item's enabled state ourselves

        toggleItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "b")
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Non-interactive readout of today's viewing time (and time left while unlocked). Disabled so
        // it reads as a status line rather than a command; refreshed via the store sink below.
        usageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        menu.addItem(usageItem)

        menu.addItem(.separator())
        let manageItem = NSMenuItem(title: "Manage Rules…",
                                    action: #selector(showManagementWindow), keyEquivalent: "")
        manageItem.target = self
        menu.addItem(manageItem)

        let updateItem = NSMenuItem(title: "Check for Updates…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SiteBlocker",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        updateToggleItem()
        updateUsageItem()

        // Keep the colored menu-bar icon, toggle item, and usage readout in sync with the state.
        iconSync = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateToggleItem()
                self?.updateUsageItem()
            }
        }
    }

    @objc private func toggleLock() {
        Task { await store.toggleLock() }
    }

    @objc private func showManagementWindow() {
        if managementWindow == nil {
            let hosting = NSHostingController(rootView: ContentView().environmentObject(store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "SiteBlocker"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 920, height: 440))
            window.isReleasedWhenClosed = false
            window.center()
            managementWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        managementWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateIcon() {
        // Red padlock while locked (sites blocked), green open padlock while unlocked.
        let symbol = store.isUnlocked ? "lock.open.fill" : "lock.fill"
        let color: NSColor = store.isUnlocked ? .systemGreen : .systemRed
        statusItem.button?.image = .tintedSymbol(symbol, color: color)
    }

    private func updateToggleItem() {
        if store.isUnlocked {
            toggleItem.title = "Lock"
            toggleItem.image = .tintedSymbol("lock.open.fill", color: .systemGreen, pointSize: 13)
            toggleItem.isEnabled = true
        } else {
            toggleItem.title = "Unlock"
            toggleItem.image = .tintedSymbol("lock.fill", color: .systemRed, pointSize: 13)
            // Unlock is only possible when some rule's window is open with budget left.
            toggleItem.isEnabled = store.canUnlock
        }
    }

    private func updateUsageItem() {
        var text = "Viewed today: \(Self.duration(store.totalUsageToday))"
        if let remaining = store.viewingTimeRemaining {
            text += "  ·  Time left: \(Self.duration(remaining))"
        }
        usageItem.title = text
    }

    /// Rounds a viewing-time interval to whole minutes for the menu (0m, 8m, 1h 5m).
    private static func duration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

private extension NSImage {
    /// A colored, non-template copy of an SF Symbol suitable for a menu-bar item.
    static func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat = 15) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
