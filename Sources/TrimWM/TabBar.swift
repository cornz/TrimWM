import AppKit

enum TabBarGeometry {
    static let expandedRailWidth: CGFloat = 240
    static let maximumTopTabWidth: CGFloat = 220
    static let inset: CGFloat = 4
    static let leftInset: CGFloat = 6
    static let flashDuration: TimeInterval = 1.2
    static let hideDelay: TimeInterval = 0.3
    /// How close to the bar's outer edge the pointer reveals a hidden bar.
    static let revealDistance: CGFloat = 2

    /// The tabs' frames in a flipped view of the given size. In a side rail,
    /// the tabs are squares as wide as the collapsed rail allows, and rows of
    /// the same height when it is expanded.
    static func tabFrames(count: Int, position: TabBarPosition, size: CGSize, thickness: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        switch position.isHorizontal {
        case true:
            let spacing: CGFloat = 2
            let available = max(0, size.width - inset * 2 - spacing * CGFloat(count - 1))
            let width = floor(min(maximumTopTabWidth, available / CGFloat(count)))
            let height = max(12, size.height - inset * 2)
            let top = floor((size.height - height) / 2)
            return (0..<count).map {
                CGRect(x: inset + CGFloat($0) * (width + spacing), y: top, width: width, height: height)
            }
        case false:
            let spacing: CGFloat = 6
            let side = max(12, thickness - leftInset * 2)
            return (0..<count).map {
                CGRect(x: leftInset, y: leftInset + CGFloat($0) * (side + spacing), width: max(side, size.width - leftInset * 2), height: side)
            }
        }
    }

    static func index(at point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    /// The bar's corner radius: the window's own, at most a capsule.
    static func cornerRadius(windowRadius: CGFloat?, thickness: CGFloat) -> CGFloat {
        min(windowRadius ?? 16, thickness / 2)
    }

    /// A rail expanded on hover grows away from the screen edge it sits at.
    static func expandedFrame(_ bar: CGRect, position: TabBarPosition) -> CGRect {
        guard !position.isHorizontal, bar.width < expandedRailWidth else { return bar }
        var frame = bar
        frame.size.width = expandedRailWidth
        if position == .right { frame.origin.x = bar.maxX - expandedRailWidth }
        return frame
    }

    /// Whether the pointer is on the bar, edges included: a pointer pushed
    /// against the screen edge the bar sits at is still on it.
    static func contains(_ frame: CGRect, pointer: CGPoint) -> Bool {
        pointer.x >= frame.minX - 1 && pointer.x <= frame.maxX + 1
            && pointer.y >= frame.minY - 1 && pointer.y <= frame.maxY + 1
    }

    /// Whether the pointer, in AppKit coordinates, touches the outer edge of a
    /// bar whose AppKit frame is given. AppKit's y grows upwards, so the top
    /// bar's outer edge is its maximum y.
    static func revealsHiddenBar(pointer: CGPoint, bar: CGRect, position: TabBarPosition) -> Bool {
        let alongX = pointer.x >= bar.minX && pointer.x <= bar.maxX
        let alongY = pointer.y >= bar.minY && pointer.y <= bar.maxY
        return switch position {
        case .top: alongX && pointer.y >= bar.maxY - revealDistance && pointer.y <= bar.maxY + 1
        case .bottom: alongX && pointer.y >= bar.minY - 1 && pointer.y <= bar.minY + revealDistance
        case .left: alongY && pointer.x >= bar.minX - 1 && pointer.x <= bar.minX + revealDistance
        case .right: alongY && pointer.x >= bar.maxX - revealDistance && pointer.x <= bar.maxX + 1
        }
    }
}

/// The tab bar: a non-activating panel of Liquid Glass above the tabs' shared
/// frame. It takes clicks without taking focus from the app whose tab is shown.
@MainActor
final class TabBar {
    var onSelect: ((WindowToken) -> Void)?
    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    private let view: TabBarView
    private let skyLight = SkyLight()
    private var windowRadii: [CGWindowID: CGFloat] = [:]
    private var model: TabBarModel?
    private var barFrame: CGRect?
    private var revealed = false
    private var hovering = false
    private var hideWork: DispatchWorkItem?
    private var pointerMonitor: Any?
    private var hoverMonitors: [Any] = []

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        // Set explicitly, a transparent window takes the mouse on all of its
        // area instead of letting it through where the glass is see-through.
        panel.ignoresMouseEvents = false
        panel.level = .floating
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        view = TabBarView(frame: .zero)
        glass.style = .regular
        glass.contentView = view
        panel.contentView = glass
        view.onSelect = { [weak self] window in self?.onSelect?(window) }
        view.onHover = { [weak self] inside in self?.hover(inside) }
    }

    func update(_ model: TabBarModel?) {
        let previous = self.model
        self.model = model
        guard let model, let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            barFrame = nil
            stopWatchingPointer()
            setHovering(false)
            panel.orderOut(nil)
            return
        }
        barFrame = FocusBorderGeometry.appKitFrame(model.frame, screenFrame: screen.frame)
        view.model = model
        glass.cornerRadius = TabBarGeometry.cornerRadius(
            windowRadius: model.tabs.first(where: \.isActive).flatMap { windowRadius($0.window.id) },
            thickness: model.settings.thickness
        )
        if model.settings.autohide {
            watchPointer()
            let changed = previous?.tabs.map(\.window) != model.tabs.map(\.window)
                || previous?.tabs.first(where: \.isActive)?.window != model.tabs.first(where: \.isActive)?.window
            if changed { reveal(for: TabBarGeometry.flashDuration) } else { layout() }
        } else {
            stopWatchingPointer()
            revealed = true
            layout()
        }
    }

    private func windowRadius(_ window: CGWindowID) -> CGFloat? {
        if let radius = windowRadii[window] { return radius }
        let radius = skyLight.cornerRadius(window)
        windowRadii[window] = radius
        return radius
    }

    private func layout() {
        guard let model, let barFrame else { return }
        let shown = !model.settings.autohide || revealed
        // A hidden rail shows expanded: there is no collapsed rail to hover.
        let expanded = !model.settings.position.isHorizontal && (hovering || (model.settings.autohide && shown))
        view.isExpanded = expanded
        let frame = expanded ? TabBarGeometry.expandedFrame(barFrame, position: model.settings.position) : barFrame
        guard shown else {
            panel.orderOut(nil)
            return
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: false)
            panel.invalidateShadow()
        }
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The view's tracking area reports entering; leaving is decided by where
    /// the pointer is, because the tracking area also reports leaving when
    /// the pointer is pushed against the screen edge the bar sits at.
    private func hover(_ inside: Bool) {
        if inside { setHovering(true) } else { checkPointer() }
    }

    private func checkPointer() {
        guard hovering, !TabBarGeometry.contains(panel.frame, pointer: NSEvent.mouseLocation) else { return }
        setHovering(false)
    }

    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        hideWork?.cancel()
        if value {
            revealed = true
            let check: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.checkPointer() } }
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: check) { hoverMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { check($0); return $0 }) {
                hoverMonitors.append(local)
            }
        } else {
            for monitor in hoverMonitors { NSEvent.removeMonitor(monitor) }
            hoverMonitors.removeAll()
            if model?.settings.autohide == true { scheduleHide(after: TabBarGeometry.hideDelay) }
        }
        layout()
    }

    private func reveal(for duration: TimeInterval) {
        revealed = true
        layout()
        scheduleHide(after: duration)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model?.settings.autohide == true, !self.hovering else { return }
                self.revealed = false
                self.layout()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func watchPointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(NSEvent.mouseLocation) }
        }
    }

    private func stopWatchingPointer() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        hideWork?.cancel()
        revealed = false
    }

    private func pointerMoved(_ pointer: CGPoint) {
        guard let model, model.settings.autohide, !revealed, let barFrame,
              TabBarGeometry.revealsHiddenBar(pointer: pointer, bar: barFrame, position: model.settings.position)
        else { return }
        hideWork?.cancel()
        revealed = true
        layout()
        // The pointer may never enter the bar; hide it again unless it does.
        scheduleHide(after: TabBarGeometry.flashDuration)
    }
}

/// Draws the tabs on the glass: the active tab is a raised capsule or square
/// with an accent mark, the others only an icon and a dimmed title.
@MainActor
final class TabBarView: NSView {
    var onSelect: ((WindowToken) -> Void)?
    var onHover: ((Bool) -> Void)?
    var model: TabBarModel? { didSet { if model != oldValue { needsDisplay = true } } }
    var isExpanded = false { didSet { if isExpanded != oldValue { needsDisplay = true } } }
    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
    private var icons: [pid_t: NSImage] = [:]
    private var names: [pid_t: String] = [:]

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        onHover?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = TabBarGeometry.index(at: convert(event.locationInWindow, from: nil), in: tabFrames)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model,
              let index = TabBarGeometry.index(at: convert(event.locationInWindow, from: nil), in: tabFrames)
        else { return }
        onSelect?(model.tabs[index].window)
    }

    private var tabFrames: [CGRect] {
        guard let model else { return [] }
        return TabBarGeometry.tabFrames(
            count: model.tabs.count,
            position: model.settings.position,
            size: bounds.size,
            thickness: model.settings.thickness
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let accent = Self.color(model.border.color)
        for (index, (tab, frame)) in zip(model.tabs, tabFrames).enumerated() {
            if model.settings.position.isHorizontal {
                drawBarTab(tab, in: frame, hovered: index == hoveredIndex, accent: accent)
            } else {
                drawRailTab(tab, in: frame, hovered: index == hoveredIndex, accent: accent, onRight: model.settings.position == .right)
            }
        }
    }

    private func drawBarTab(_ tab: TabBarTab, in frame: CGRect, hovered: Bool, accent: NSColor) {
        let radius = frame.height / 2
        drawBackground(of: tab, in: frame, radius: radius, hovered: hovered)
        let iconSide = min(16, frame.height - 6)
        let icon = CGRect(x: frame.minX + 9, y: frame.midY - iconSide / 2, width: iconSide, height: iconSide)
        drawIcon(for: tab.window.pid, in: icon)
        var titleEnd = frame.maxX - 10
        if tab.isActive {
            accent.setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.maxX - 14, y: frame.midY - 3, width: 6, height: 6)).fill()
            titleEnd = frame.maxX - 20
        }
        drawTitle(of: tab, in: CGRect(x: icon.maxX + 6, y: frame.minY, width: max(0, titleEnd - icon.maxX - 6), height: frame.height))
    }

    /// The accent mark sits at the screen edge the rail is on.
    private func drawRailTab(_ tab: TabBarTab, in frame: CGRect, hovered: Bool, accent: NSColor, onRight: Bool) {
        drawBackground(of: tab, in: frame, radius: min(10, frame.height / 3), hovered: hovered)
        if tab.isActive {
            accent.setFill()
            let mark = CGRect(x: onRight ? bounds.maxX - 4.5 : 1.5, y: frame.midY - 7, width: 3, height: 14)
            NSBezierPath(roundedRect: mark, xRadius: 1.5, yRadius: 1.5).fill()
        }
        let iconSide = min(20, frame.height - 10)
        let iconX = isExpanded ? frame.minX + 8 : frame.midX - iconSide / 2
        let icon = CGRect(x: iconX, y: frame.midY - iconSide / 2, width: iconSide, height: iconSide)
        drawIcon(for: tab.window.pid, in: icon)
        guard isExpanded else { return }
        drawTitle(of: tab, in: CGRect(x: icon.maxX + 8, y: frame.minY, width: max(0, frame.maxX - icon.maxX - 16), height: frame.height))
    }

    private func drawBackground(of tab: TabBarTab, in frame: CGRect, radius: CGFloat, hovered: Bool) {
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        if tab.isActive {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor(white: 0, alpha: isDark ? 0.4 : 0.12)
            shadow.set()
            (isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.95)).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if hovered {
            (isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)).setFill()
            shape.fill()
        }
    }

    private func drawIcon(for pid: pid_t, in rect: CGRect) {
        icon(for: pid).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawTitle(of tab: TabBarTab, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = tab.title.isEmpty ? name(for: tab.window.pid) : tab.title
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: tab.isActive ? .semibold : .regular),
            .foregroundColor: tab.isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let height = ceil(text.size().height)
        text.draw(
            with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func icon(for pid: pid_t) -> NSImage {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        icons[pid] = icon
        return icon
    }

    private func name(for pid: pid_t) -> String {
        if let name = names[pid] { return name }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        names[pid] = name
        return name
    }

    private static func color(_ color: BorderColor) -> NSColor {
        switch color {
        case .accent: .controlAccentColor
        case let .rgba(red, green, blue, alpha):
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
        }
    }
}
