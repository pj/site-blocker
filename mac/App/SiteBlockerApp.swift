import SwiftUI
import AppKit
import Combine
import RulesEngine

@main
struct SiteBlockerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All UI is driven from AppDelegate via an AppKit NSStatusItem + NSMenu of *standard* menu
        // items (the shape Karabiner-Elements uses). Only real menu tracking keeps an auto-hiding
        // system menu bar revealed, and custom NSHostingView items inside menus lay out unreliably,
        // so everything is a native item. This empty scene just satisfies the App requirement.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: RuleStore
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var toggleItem: NSMenuItem!
    private var managementWindow: NSWindow?
    private var iconSync: AnyCancellable?

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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        // An NSMenu of standard items only, not an NSPopover: the system keeps an auto-hiding menu
        // bar revealed only while a real menu is tracking, and custom NSHostingView items misplace
        // their content. The key equivalent renders the ⌃⌥⌘B hint natively; the Carbon hotkey
        // (which handles the global case) intercepts the combo before it reaches the menu, so it
        // won't fire twice.
        menu = NSMenu()

        toggleItem = NSMenuItem(title: "", action: #selector(toggleBlocking), keyEquivalent: "b")
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        let manageItem = NSMenuItem(title: "Manage Rules…",
                                    action: #selector(showManagementWindow), keyEquivalent: "")
        manageItem.target = self
        menu.addItem(manageItem)
        menu.addItem(NSMenuItem(title: "Quit SiteBlocker",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        updateToggleItem()

        // Keep the colored menu-bar icon and toggle item in sync with the blocking state.
        iconSync = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateToggleItem()
            }
        }
    }

    @objc private func toggleBlocking() {
        Task { await store.toggleBlocking() }
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
        let symbol = store.blockingEnabled ? "hand.raised.slash.fill" : "hand.raised.fill"
        let color: NSColor = store.blockingEnabled ? .systemRed : .systemGreen
        statusItem.button?.image = .tintedSymbol(symbol, color: color)
    }

    private func updateToggleItem() {
        // Same red/green metaphor as the old prominent button: red while blocking is on.
        if store.blockingEnabled {
            toggleItem.title = "End Block"
            toggleItem.image = .tintedSymbol("hand.raised.slash.fill", color: .systemRed,
                                             pointSize: 13)
        } else {
            toggleItem.title = "Start Block"
            toggleItem.image = .tintedSymbol("hand.raised.fill", color: .systemGreen,
                                             pointSize: 13)
        }
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
