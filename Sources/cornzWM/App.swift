import AppKit

enum RuntimeEnvironment {
    static func shouldStartWindowManager(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"]
            .contains { environment[$0] != nil }
    }
}

@main
@MainActor
enum cornzWMMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: WMController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard RuntimeEnvironment.shouldStartWindowManager() else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let controller = WMController()
        controller.onStatus = { [weak self] status, error in self?.updateMenu(status: status, error: error) }
        self.controller = controller
        updateMenu(status: "Starting", error: nil)
        controller.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.disable()
        return .terminateNow
    }

    private func updateMenu(status: String, error: String?) {
        statusItem?.button?.title = status
        let menu = NSMenu()
        let state = NSMenuItem(title: error ?? "cornzWM v2 · \(status)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enable", action: #selector(enable), keyEquivalent: "")
        menu.addItem(withTitle: "Disable", action: #selector(disable), keyEquivalent: "")
        menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r")
        menu.addItem(withTitle: "Restore Hidden Windows", action: #selector(disable), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Accessibility Settings…", action: #selector(accessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit cornzWM", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { if item.action != nil { item.target = self } }
        statusItem?.menu = menu
    }

    @objc private func enable() { controller?.enable() }
    @objc private func disable() { controller?.disable() }
    @objc private func reload() { controller?.reload() }
    @objc private func accessibility() { controller?.openAccessibilitySettings() }
    @objc private func quit() { controller?.quit() }
}
