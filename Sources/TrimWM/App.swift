import AppKit

enum FocusBorderGeometry {
    static func cornerRadius(configured: CGFloat?, strokeWidth: CGFloat, macOSMajorVersion: Int) -> CGFloat {
        if let configured { return configured }
        // The panel expands by the stroke width. Keep its inner edge aligned
        // with macOS 27's uniform 16-point window corners.
        return macOSMajorVersion >= 27 ? 16 + strokeWidth : 9
    }

    /// The ring's inner edge follows the window's own corners; a configured
    /// radius sets the outer edge, as it does for the panel border.
    static func ringRadii(
        configured: CGFloat?,
        windowRadius: CGFloat?,
        strokeWidth: CGFloat,
        macOSMajorVersion: Int
    ) -> (inner: CGFloat, outer: CGFloat) {
        if let configured { return (max(0, configured - strokeWidth), configured) }
        let inner = max(0, windowRadius ?? cornerRadius(
            configured: nil, strokeWidth: strokeWidth, macOSMajorVersion: macOSMajorVersion
        ) - strokeWidth)
        return (inner, inner + strokeWidth)
    }

    /// The frame's center in screen coordinates. Frames are global top-left;
    /// screen frames are bottom-left around the primary screen.
    static func screenPoint(of frame: CGRect, primaryScreenFrame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: primaryScreenFrame.maxY - frame.midY)
    }

    /// How far the ring reaches into the window: macOS draws a 1-point
    /// highlight inside every window edge and a hairline outside it.
    static let windowRimOverlap: CGFloat = 1

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
        content.layer?.cornerRadius = FocusBorderGeometry.cornerRadius(
            configured: style.radius,
            strokeWidth: strokeWidth,
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
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

/// The focus border: a SkyLight window kept directly above the focused window,
/// or the panel border where SkyLight's window functions are unavailable.
@MainActor
final class WindowBorder {
    private let skyLight = SkyLight()
    private let ring = SkyLightBorder()
    private let fallback = FocusBorder()
    private var style = BorderStyle()
    private var target: FocusBorderTarget?
    private var windowRadius: CGFloat?
    private var spaceID: UInt64?

    func apply(_ style: BorderStyle) {
        self.style = style
        if ring == nil { fallback.apply(style) } else { update(target) }
    }

    func update(_ target: FocusBorderTarget?) {
        guard let ring else {
            fallback.update(target?.frame)
            return
        }
        if target?.window != self.target?.window || self.target == nil {
            windowRadius = target.flatMap { skyLight.cornerRadius($0.window) }
            spaceID = target.flatMap(space)
        }
        self.target = target
        let width = max(0, style.width)
        guard let target, width > 0,
              let color = style.color.nsColor.usingColorSpace(.sRGB),
              let primary = NSScreen.screens.first
        else {
            ring.hide()
            return
        }
        // WindowServer's bounds, as JankyBorders and Dinky use: the frame the
        // window is drawn at, even before an Accessibility frame catches up.
        let frame = skyLight.bounds(target.window) ?? target.frame
        let radii = FocusBorderGeometry.ringRadii(
            configured: style.radius,
            windowRadius: windowRadius,
            strokeWidth: width,
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        let point = FocusBorderGeometry.screenPoint(of: frame, primaryScreenFrame: primary.frame)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? primary
        ring.show(
            BorderRing(
                size: frame.size,
                width: width,
                overlap: FocusBorderGeometry.windowRimOverlap,
                innerRadius: radii.inner,
                outerRadius: radii.outer,
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent,
                alpha: color.alphaComponent
            ),
            around: frame,
            above: target.window,
            scale: screen.backingScaleFactor,
            spaceID: spaceID
        )
    }

    private func space(of target: FocusBorderTarget) -> UInt64? {
        guard let spaces = skyLight.windowSpaceIDs(target.window) else { return nil }
        if let current = skyLight.currentMainSpaceID(), spaces.contains(current) { return current }
        return spaces.min()
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

enum AppMetadata {
    static func version(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        info?["CFBundleShortVersionString"] as? String ?? "development"
    }

    static func menuTitle(status: String, error: String?, version: String) -> String {
        "TrimWM \(version) · \(error ?? status)"
    }

    static let changelogURL = URL(string: "https://github.com/cornz/TrimWM/blob/main/CHANGELOG.md")!
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
    private let focusBorder = WindowBorder()
    private let dragTargetBorder = FocusBorder(widthScale: 2, minimumWidth: 4, fillOpacity: 0.1)
    private var dragCursorPushed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard RuntimeEnvironment.shouldStartWindowManager() else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let controller = WMController()
        controller.onStatus = { [weak self] status, error in self?.updateMenu(status: status, error: error) }
        controller.onFocusBorder = { [weak self] target in self?.focusBorder.update(target) }
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
        let version = AppMetadata.version()
        statusItem?.button?.title = status
        statusItem?.button?.toolTip = "TrimWM \(version)"
        let menu = NSMenu()
        let state = NSMenuItem(
            title: AppMetadata.menuTitle(status: status, error: error, version: version),
            action: nil,
            keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let toggle = MenuToggleAction(isEnabled: controller?.isEnabled == true)
        let toggleSelector = switch toggle {
        case .enable: #selector(enable)
        case .disable: #selector(disable)
        }
        menu.addItem(withTitle: toggle.title, action: toggleSelector, keyEquivalent: "")
        menu.addItem(withTitle: "Open Configuration…", action: #selector(openConfig), keyEquivalent: "")
        menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r")
        menu.addItem(withTitle: "Restore Hidden Windows", action: #selector(disable), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Accessibility Settings…", action: #selector(accessibility), keyEquivalent: "")
        menu.addItem(withTitle: "Changelog…", action: #selector(changelog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TrimWM", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { if item.action != nil { item.target = self } }
        statusItem?.menu = menu
    }

    @objc private func enable() { controller?.enable() }
    @objc private func disable() { controller?.disable() }
    @objc private func openConfig() { controller?.openConfig() }
    @objc private func reload() { controller?.reload() }
    @objc private func accessibility() { controller?.openAccessibilitySettings() }
    @objc private func changelog() { NSWorkspace.shared.open(AppMetadata.changelogURL) }
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
