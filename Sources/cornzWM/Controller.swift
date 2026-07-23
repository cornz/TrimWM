@preconcurrency import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog
import ServiceManagement

enum LoginItemAction: Equatable { case none, register, unregister }

enum LoginItemPlanner {
    static func action(startAtLogin: Bool, status: SMAppService.Status) -> LoginItemAction {
        let registered = status == .enabled || status == .requiresApproval
        if startAtLogin { return registered ? .none : .register }
        return registered ? .unregister : .none
    }
}

enum CommandTargetResolver {
    static func resolve(
        frontmostPID: pid_t?,
        nativelyFocused: [WindowToken],
        world: World
    ) -> WindowToken? {
        if let frontmostPID,
           let native = nativelyFocused.sorted().first(where: {
               $0.pid == frontmostPID && world.workspace(of: $0) != nil
           }) {
            return native
        }
        return world.visible.focused
    }
}

@MainActor
final class WMController {
    var onStatus: ((String, String?) -> Void)?
    private(set) var isEnabled = false

    private let windowSystem = WindowSystem()
    private let hotKeys = HotKeyManager()
    private let mouse = MouseFocusMonitor()
    private let events = EventQueue()
    private let logger = Logger(subsystem: "de.cornz.cornzWM", category: "runtime")
    private var config: WMConfig
    private var world = World()
    private var native: [WindowToken: AXWindowSnapshot] = [:]
    private var frameConstraints = FrameConstraintCache()
    private var ledger = FrameLedger()
    private var journal: CrashJournal
    private var mode = "default"
    private var systemStarted = false
    private var lastError: String?
    private var published: (status: String, error: String?)?

    private let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/cornzwm/config")

    init() {
        config = (try? ConfigParser.parse(Self.defaultConfig)) ?? WMConfig()
        let journalURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "cornzWM/crash-journal.json")
        journal = CrashJournal(url: journalURL, bootID: Self.bootID())

        hotKeys.onCommand = { [weak self] command in
            self?.events.push(.command(command))
        }
        mouse.onWindow = { [weak self] window in
            self?.events.push(.mouse(window))
        }
        mouse.onResize = { [weak self] window, direction, pixels in
            self?.events.push(.mouseResize(window, direction, pixels))
        }
        windowSystem.onUpdate = { [weak self] pid, windows in self?.events.push(.windows(pid, windows)) }
        windowSystem.onFrame = { [weak self] window, frame in self?.events.push(.frameObserved(window, frame)) }
        events.onDrain = { [weak self] pending in self?.drain(pending) }
    }

    func start() {
        reload()
        if WindowSystem.isTrusted { enable() }
        else {
            WindowSystem.requestTrust()
            publish(error: "Accessibility access is required; grant it, then choose Enable.")
        }
    }

    func enable() {
        guard !isEnabled else { return }
        guard WindowSystem.isTrusted else {
            WindowSystem.requestTrust()
            publish(error: "Accessibility access is not granted yet.")
            return
        }
        do { try hotKeys.register(config.bindings["default"] ?? []) }
        catch { publish(error: "Hotkeys: \(error)"); return }
        mode = "default"
        world = World(workspaceCount: config.workspaceCount)
        native.removeAll()
        frameConstraints.reset()
        ledger.reset()
        isEnabled = true
        if lastError?.hasPrefix("Accessibility") == true { lastError = nil }
        if !systemStarted { windowSystem.start(); systemStarted = true }
        else { windowSystem.rescan() }
        if !mouse.start(focusesOnMove: config.focusFollowsMouse) {
            lastError = "Could not create the mouse event tap."
        }
        publish()
    }

    func disable() {
        guard isEnabled || !journal.entries.isEmpty else { return }
        isEnabled = false
        hotKeys.unregister()
        mouse.stop()
        restoreJournal()
        publish()
    }

    func quit() {
        disable()
        windowSystem.stop()
        NSApplication.shared.terminate(nil)
    }

    func reload() {
        do {
            let source = FileManager.default.fileExists(atPath: configURL.path)
                ? try String(contentsOf: configURL, encoding: .utf8)
                : Self.defaultConfig
            let parsed = try ConfigParser.parse(source)
            try ConfigValidator.validate(parsed)
            if isEnabled, parsed.workspaceCount != config.workspaceCount {
                throw ConfigError.line(1, "workspace-count cannot change while enabled")
            }
            if isEnabled { try hotKeys.register(parsed.bindings["default"] ?? []) }
            config = parsed
            mode = "default"
            lastError = nil
            if isEnabled, !mouse.start(focusesOnMove: config.focusFollowsMouse) {
                lastError = "Could not create the mouse event tap."
            }
            updateLoginItem()
            applyLayout()
        } catch {
            lastError = String(describing: error)
        }
        publish()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func drain(_ pending: [WMEvent]) {
        for event in pending {
            switch event {
            case let .windows(pid, windows): accept(pid: pid, windows: windows)
            case let .frameObserved(window, frame): accept(frame: frame, for: window)
            case let .command(command): execute(command)
            case let .mouse(window): focusFromMouse(window)
            case let .mouseResize(window, direction, pixels): resizeFromMouse(window, direction: direction, pixels: pixels)
            case let .frameWriteResult(window, frame, result):
                guard isEnabled else { continue }
                switch ledger.completed(frame, for: window, result: result) {
                case .none: break
                case let .write(next): write(next, to: window)
                case let .refused(observed):
                    if let observed,
                       let learned = FrameConstraintLearner.minimum(target: frame, observed: observed),
                       frameConstraints.learn(learned, for: window) {
                        applyLayout()
                    }
                }
            }
        }
    }

    private func accept(frame: CGRect, for window: WindowToken) {
        guard isEnabled, let snapshot = native[window] else { return }
        snapshot.frame = frame
        ledger.observed(frame, for: window)
        let bounds = WindowSystem.mainScreenBounds
        let isManaged = world.workspace(of: window) != nil
        if Geometry.shouldReconcileRestoredWindow(
            isManaged: isManaged,
            hasJournalEntry: journal.entries[window] != nil,
            observed: frame,
            bounds: bounds
        ) {
            try? journal.remove(window)
            windowSystem.rescan()
            return
        }
        guard isManaged else { return }
        if journal.entries[window] != nil {
            let desired = world.visibleFrames(bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            if Geometry.shouldClearJournal(observed: frame, desired: desired[window], bounds: bounds) {
                try? journal.remove(window)
            }
        }
        applyLayout()
    }

    private func accept(pid: pid_t, windows: [AXWindowSnapshot]) {
        guard isEnabled else { return }
        let previous = native.keys.filter { $0.pid == pid }
        let incoming = Set(windows.map(\.token))
        for token in previous where !incoming.contains(token) {
            native.removeValue(forKey: token)
            frameConstraints.remove(token)
            world.remove(token)
            ledger.remove(token)
        }

        let bounds = WindowSystem.mainScreenBounds
        for window in windows {
            native[window.token] = window
            if world.workspace(of: window.token) == nil {
                if let entry = journal.entries[window.token], entry.bundleID == window.bundleID {
                    if window.isOnScreen, Geometry.isMeaningfullyVisible(window.frame, in: bounds) {
                        try? journal.remove(window.token)
                    }
                    else {
                        if ledger.needsWrite(entry.frame, for: window.token) { write(entry.frame, to: window.token) }
                        continue
                    }
                }
                guard window.isOnCurrentSpace, window.isOnScreen, window.frame.intersects(bounds) else { continue }
                let rule = config.rules.first { $0.bundleID.caseInsensitiveCompare(window.bundleID) == .orderedSame }
                let workspace = min(config.workspaceCount, max(1, rule?.workspace ?? world.visibleWorkspace))
                let floating = window.disposition == .floating || rule?.floating == true
                world.add(window.token, to: workspace, floating: floating ? window.frame : nil,
                          bounds: bounds, gaps: config.gaps, splitRatio: config.splitRatio,
                          minimumSizes: minimumSizes)
            }
            ledger.observed(window.frame, for: window.token)
            if window.isFocused,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                world.focusIfVisible(window.token, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            }
        }
        let desired = world.visibleFrames(bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
        for window in windows where journal.entries[window.token] != nil {
            if Geometry.shouldClearJournal(observed: window.frame, desired: desired[window.token], bounds: bounds) {
                try? journal.remove(window.token)
            }
        }
        applyLayout()
    }

    private func applyLayout() {
        guard isEnabled else { return }
        let bounds = WindowSystem.mainScreenBounds
        let minimumSizes = self.minimumSizes
        world.reflowVisibleToFit(bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
        let desired = world.visibleFrames(bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
        var visibleForMouse: [WindowToken: CGRect] = [:]
        var toJournal: [JournalEntry] = []
        var visibleWrites: [(WindowToken, CGRect)] = []
        var hiddenWrites: [(WindowToken, CGRect)] = []

        for (token, window) in native where world.workspace(of: token) != nil {
            guard window.isOnCurrentSpace, window.isOnScreen || journal.entries[token] != nil else { continue }
            if let frame = desired[token], frame.intersects(bounds) {
                visibleForMouse[token] = frame
                visibleWrites.append((token, frame))
            } else {
                if journal.entries[token] == nil, Geometry.isMeaningfullyVisible(window.frame, in: bounds) {
                    toJournal.append(JournalEntry(bootID: journal.bootID, token: token, bundleID: window.bundleID, frame: window.frame))
                }
                let hidden = Geometry.sideHiddenFrame(window.frame, mainBounds: bounds, displayBounds: WindowSystem.displayBounds)
                hiddenWrites.append((token, hidden))
            }
        }
        if !toJournal.isEmpty {
            do { try journal.record(toJournal) }
            catch {
                lastError = "Crash journal failed; hiding was cancelled: \(error)"
                mouse.update(visibleForMouse, frontToBack: windowSystem.mouseSurfaces)
                publish()
                return
            }
        }
        for (token, frame) in visibleWrites + hiddenWrites where ledger.needsWrite(frame, for: token) {
            write(frame, to: token)
        }
        mouse.update(visibleForMouse, frontToBack: windowSystem.mouseSurfaces)
        publish()
    }

    private func execute(_ command: WMCommand) {
        if command == .reload { reload(); return }
        guard isEnabled else { return }
        let bounds = WindowSystem.mainScreenBounds
        switch command {
        case let .focus(direction):
            world.focus(direction, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            focusCurrent()
        case .focusNext:
            world.focusNext(bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            focusCurrent()
        case let .move(direction):
            world.moveFocused(direction, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            applyLayout()
        case let .resize(direction, pixels): world.resizeFocused(direction, pixels: pixels, bounds: bounds); applyLayout()
        case let .workspace(index): world.switchWorkspace(to: index); applyLayout()
        case let .moveToWorkspace(index, follow):
            let window = commandWindow()
            if let window, let frame = native[window]?.frame {
                world.move(
                    window,
                    to: index,
                    follow: follow,
                    currentFrame: frame,
                    bounds: bounds,
                    gaps: config.gaps,
                    splitRatio: config.splitRatio,
                    minimumSizes: minimumSizes
                )
                applyLayout()
            }
        case let .layout(mode):
            world.changeVisibleLayout(
                to: mode,
                bounds: bounds,
                gaps: config.gaps,
                splitRatio: config.splitRatio,
                minimumSizes: minimumSizes
            )
            applyLayout()
        case let .split(axis): world.setNextSplit(axis)
        case .balance: world.balanceVisible(); applyLayout()
        case let .consume(direction):
            synchronizeVisibleCommandFocus()
            world.consume(direction, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            applyLayout()
        case let .expel(direction):
            synchronizeVisibleCommandFocus()
            world.expel(direction, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            applyLayout()
        case .centerColumn:
            world.centerColumn(bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            applyLayout()
        case let .setColumnWidth(width):
            world.setColumnWidth(width, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
            applyLayout()
        case let .floating(value):
            if let window = world.visible.focused, let frame = native[window]?.frame {
                let currentlyFloating = world.visible.floating[window] != nil
                if value == .toggle || (value == .enable && !currentlyFloating) || (value == .disable && currentlyFloating) {
                    world.toggleFloating(
                        window,
                        frame: frame,
                        bounds: bounds,
                        gaps: config.gaps,
                        splitRatio: config.splitRatio,
                        minimumSizes: minimumSizes
                    )
                    applyLayout()
                }
            }
        case .fullscreen:
            if let window = world.visible.focused {
                world.setFullscreen(window, enabled: world.visible.fullscreen != window)
                applyLayout()
            }
        case let .mode(name):
            guard let bindings = config.bindings[name] else { return }
            do { try hotKeys.register(bindings); mode = name; lastError = nil }
            catch { lastError = String(describing: error) }
            publish()
        case let .execute(shellCommand):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", shellCommand]
            do { try process.run() } catch { lastError = String(describing: error); publish() }
        case .reload, .nop: break
        }
    }

    private func focusCurrent() {
        if let window = world.visible.focused { windowSystem.focus(window) }
        applyLayout()
    }

    private func commandWindow() -> WindowToken? {
        CommandTargetResolver.resolve(
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            nativelyFocused: native.values.filter(\.isFocused).map(\.token),
            world: world
        )
    }

    private func synchronizeVisibleCommandFocus() {
        guard let window = commandWindow(), world.workspace(of: window) == world.visibleWorkspace else { return }
        world.focusIfVisible(
            window,
            bounds: WindowSystem.mainScreenBounds,
            gaps: config.gaps,
            minimumSizes: minimumSizes
        )
    }

    private func write(_ frame: CGRect, to window: WindowToken) {
        windowSystem.setFrame(frame, for: window) { [weak self] result in
            self?.events.push(.frameWriteResult(window, frame, result))
        }
    }

    private var minimumSizes: [WindowToken: CGSize] {
        native.mapValues { snapshot in
            let learned = frameConstraints.value(for: snapshot.token) ?? CGSize(width: 1, height: 1)
            return CGSize(
                width: max(1, snapshot.minimumSize.width, learned.width),
                height: max(1, snapshot.minimumSize.height, learned.height)
            )
        }
    }

    private func focusFromMouse(_ window: WindowToken) {
        guard isEnabled, world.workspace(of: window) == world.visibleWorkspace else { return }
        world.focusIfVisible(
            window,
            bounds: WindowSystem.mainScreenBounds,
            gaps: config.gaps,
            minimumSizes: minimumSizes
        )
        windowSystem.focus(window)
        applyLayout()
    }

    private func resizeFromMouse(_ window: WindowToken, direction: Direction, pixels: CGFloat) {
        guard isEnabled, world.workspace(of: window) == world.visibleWorkspace else { return }
        let bounds = WindowSystem.mainScreenBounds
        world.focusIfVisible(window, bounds: bounds, gaps: config.gaps, minimumSizes: minimumSizes)
        world.resizeFocused(direction, pixels: pixels, bounds: bounds)
        applyLayout()
    }

    private func restoreJournal() {
        for (token, entry) in journal.entries.sorted(by: { $0.key < $1.key }) {
            if windowSystem.contains(token, bundleID: entry.bundleID), windowSystem.setFrameSync(entry.frame, for: token) {
                try? journal.remove(token)
            }
        }
        ledger.reset()
    }

    private func updateLoginItem() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        do {
            switch LoginItemPlanner.action(startAtLogin: config.startAtLogin, status: SMAppService.mainApp.status) {
            case .none: break
            case .register: try SMAppService.mainApp.register()
            case .unregister: try SMAppService.mainApp.unregister()
            }
        } catch { lastError = "Login item: \(error.localizedDescription)" }
    }

    private func publish(error: String? = nil) {
        if let error { lastError = error }
        let next = (isEnabled ? world.statusText : "Paused", lastError)
        guard published?.status != next.0 || published?.error != next.1 else { return }
        published = next
        if let error = next.1 { logger.error("\(next.0, privacy: .public): \(error, privacy: .public)") }
        else { logger.notice("\(next.0, privacy: .public)") }
        onStatus?(next.0, next.1)
    }

    private static func bootID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static let defaultConfig = """
    set $mod alt
    workspace-count 10
    gaps inner 0
    gaps outer 0
    autotile split-ratio 1.0
    focus-follows-mouse true
    start-at-login true
    bindsym $mod+j focus left
    bindsym $mod+k focus down
    bindsym $mod+l focus up
    bindsym $mod+; focus right
    bindsym $mod+q focus next
    bindsym $mod+Shift+j move left
    bindsym $mod+Shift+k move down
    bindsym $mod+Shift+l move up
    bindsym $mod+Shift+; move right
    bindsym $mod+h split horizontal
    bindsym $mod+v split vertical
    bindsym $mod+f fullscreen
    bindsym $mod+w layout niri
    bindsym $mod+Shift+e layout autotile
    bindsym $mod+Shift+space floating toggle
    bindsym $mod+comma consume left
    bindsym $mod+period consume right
    bindsym $mod+Shift+comma expel left
    bindsym $mod+Shift+period expel right
    bindsym $mod+c center-column
    bindsym $mod+1 workspace 1
    bindsym $mod+2 workspace 2
    bindsym $mod+3 workspace 3
    bindsym $mod+4 workspace 4
    bindsym $mod+5 workspace 5
    bindsym $mod+6 workspace 6
    bindsym $mod+7 workspace 7
    bindsym $mod+8 workspace 8
    bindsym $mod+9 workspace 9
    bindsym $mod+0 workspace 10
    bindsym $mod+Shift+1 move-to-workspace 1 follow
    bindsym $mod+Shift+2 move-to-workspace 2 follow
    bindsym $mod+Shift+3 move-to-workspace 3 follow
    bindsym $mod+Shift+4 move-to-workspace 4 follow
    bindsym $mod+Shift+5 move-to-workspace 5 follow
    bindsym $mod+Shift+6 move-to-workspace 6 follow
    bindsym $mod+Shift+7 move-to-workspace 7 follow
    bindsym $mod+Shift+8 move-to-workspace 8 follow
    bindsym $mod+Control+1 move-to-workspace 1
    bindsym $mod+Control+2 move-to-workspace 2
    bindsym $mod+Control+3 move-to-workspace 3
    bindsym $mod+Control+4 move-to-workspace 4
    bindsym $mod+Control+5 move-to-workspace 5
    bindsym $mod+Control+6 move-to-workspace 6
    bindsym $mod+Control+7 move-to-workspace 7
    bindsym $mod+Control+8 move-to-workspace 8
    bindsym $mod+Shift+0 balance-sizes
    bindsym $mod+return exec open -a Warp
    bindsym $mod+Shift+c reload
    bindsym $mod+r mode resize
    mode resize {
        bindsym h resize left -50
        bindsym j resize down 50
        bindsym k resize up -50
        bindsym l resize right 50
        bindsym return mode default
        bindsym escape mode default
        bindsym r mode default
    }
    assign [app_id="com.apple.MobileSMS"] workspace 5
    assign [app_id="com.tinyspeck.slackmacgap"] workspace 5
    assign [app_id="com.hnc.Discord"] workspace 5
    assign [app_id="com.apple.Safari"] workspace 1
    assign [app_id="com.microsoft.edgemac"] workspace 1
    assign [app_id="com.todesktop.230313mzl4w4u92"] workspace 2
    assign [app_id="com.jetbrains.WebStorm"] workspace 2
    assign [app_id="com.openai.Codex"] workspace 6
    for_window [app_id="com.jetbrains.IntelliJ"] floating enable
    for_window [app_id="com.1password.1password"] floating enable
    for_window [app_id="com.apple.systempreferences"] floating enable
    for_window [app_id="com.apple.finder"] floating enable
    for_window [app_id="com.apple.QuickTimePlayerX"] floating enable
    """
}
