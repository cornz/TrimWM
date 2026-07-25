import AppKit

enum FocusBorderGeometry {
    static func strokeWidth(configured: CGFloat, scale: CGFloat, minimum: CGFloat) -> CGFloat {
        max(minimum, configured * scale)
    }

    static func appKitFrame(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: screenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
final class FocusBorder {
    private let panel: NSPanel
    private let content: NSView
    private let widthScale: CGFloat
    private let minimumWidth: CGFloat
    private let fillOpacity: CGFloat
    private var style = BorderStyle()
    private var targetFrame: CGRect?
    private var displayedFrame: CGRect?

    init(
        widthScale: CGFloat = 1,
        minimumWidth: CGFloat = 0,
        fillOpacity: CGFloat = 0
    ) {
        self.widthScale = widthScale
        self.minimumWidth = minimumWidth
        self.fillOpacity = fillOpacity
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        content = NSView(frame: .zero)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        panel.contentView = content
        apply(style)
    }

    func apply(_ style: BorderStyle) {
        self.style = style
        let color = style.color.nsColor
        content.layer?.borderColor = color.cgColor
        content.layer?.borderWidth = strokeWidth
        content.layer?.cornerRadius = style.radius
        content.layer?.backgroundColor = color.withAlphaComponent(fillOpacity).cgColor
        update(targetFrame)
    }

    func update(_ frame: CGRect?) {
        targetFrame = frame
        guard let frame,
              strokeWidth > 0 || fillOpacity > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else {
            displayedFrame = nil
            panel.orderOut(nil)
            return
        }
        let expanded = frame.insetBy(dx: -strokeWidth, dy: -strokeWidth)
        let display = FocusBorderGeometry.appKitFrame(expanded, screenFrame: screen.frame)
        if displayedFrame != display {
            panel.setFrame(display, display: true, animate: false)
            displayedFrame = display
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private var strokeWidth: CGFloat {
        FocusBorderGeometry.strokeWidth(
            configured: style.width,
            scale: widthScale,
            minimum: minimumWidth
        )
    }
}

private extension BorderColor {
    var nsColor: NSColor {
        switch self {
        case .accent:
            NSColor.controlAccentColor
        case let .rgba(red, green, blue, alpha):
            NSColor(
                srgbRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: CGFloat(alpha) / 255
            )
        }
    }
}

enum RuntimeEnvironment {
    static func shouldStartWindowManager(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"]
            .contains { environment[$0] != nil }
    }
}

enum MenuToggleAction: Equatable {
    case enable
    case disable

    init(isEnabled: Bool) {
        self = isEnabled ? .disable : .enable
    }

    var title: String {
        switch self {
        case .enable: "Enable"
        case .disable: "Disable"
        }
    }
}

@main
@MainActor
enum TrimWMMain {
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
    private let focusBorder = FocusBorder()
    private let dragTargetBorder = FocusBorder(widthScale: 2, minimumWidth: 4, fillOpacity: 0.1)
    private var dragCursorPushed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard RuntimeEnvironment.shouldStartWindowManager() else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let controller = WMController()
        controller.onStatus = { [weak self] status, error in self?.updateMenu(status: status, error: error) }
        controller.onFocusFrame = { [weak self] frame in self?.focusBorder.update(frame) }
        controller.onColumnDragFeedback = { [weak self] active, frame in
            self?.updateColumnDragFeedback(active: active, frame: frame)
        }
        controller.onBorderStyle = { [weak self] style in
            self?.focusBorder.apply(style)
            self?.dragTargetBorder.apply(style)
        }
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
        let state = NSMenuItem(title: error ?? "TrimWM · \(status)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let toggle = MenuToggleAction(isEnabled: controller?.isEnabled == true)
        let toggleSelector = switch toggle {
        case .enable: #selector(enable)
        case .disable: #selector(disable)
        }
        menu.addItem(withTitle: toggle.title, action: toggleSelector, keyEquivalent: "")
        menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r")
        menu.addItem(withTitle: "Restore Hidden Windows", action: #selector(disable), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Accessibility Settings…", action: #selector(accessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TrimWM", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { if item.action != nil { item.target = self } }
        statusItem?.menu = menu
    }

    @objc private func enable() { controller?.enable() }
    @objc private func disable() { controller?.disable() }
    @objc private func reload() { controller?.reload() }
    @objc private func accessibility() { controller?.openAccessibilitySettings() }
    @objc private func quit() { controller?.quit() }

    private func updateColumnDragFeedback(active: Bool, frame: CGRect?) {
        if active, !dragCursorPushed {
            NSCursor.closedHand.push()
            dragCursorPushed = true
        } else if !active, dragCursorPushed {
            NSCursor.pop()
            dragCursorPushed = false
        }
        dragTargetBorder.update(active ? frame : nil)
    }
}
