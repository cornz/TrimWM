import ApplicationServices
import CoreGraphics
import XCTest
@testable import TrimWM

@MainActor
final class ControllerTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testMenuToggleMatchesEnabledState() {
        XCTAssertEqual(MenuToggleAction(isEnabled: false), .enable)
        XCTAssertEqual(MenuToggleAction(isEnabled: false).title, "Enable")
        XCTAssertEqual(MenuToggleAction(isEnabled: true), .disable)
        XCTAssertEqual(MenuToggleAction(isEnabled: true).title, "Disable")
    }

    func testTrustLifecycleStartsOnceAndDisablesCleanly() {
        let harness = makeHarness(trusted: false)
        var statuses: [(String, String?)] = []
        var focusFrames: [CGRect?] = []
        harness.controller.onStatus = { statuses.append(($0, $1)) }
        harness.controller.onFocusFrame = { focusFrames.append($0) }

        harness.controller.start()

        XCTAssertFalse(harness.controller.isEnabled)
        XCTAssertEqual(harness.environment.requestTrustCount, 1)
        XCTAssertTrue(statuses.last?.1?.contains("Accessibility access is required") == true)

        harness.environment.trusted = true
        harness.controller.enable()
        harness.controller.enable()

        XCTAssertTrue(harness.controller.isEnabled)
        XCTAssertEqual(harness.windowSystem.startCount, 1)
        XCTAssertEqual(harness.windowSystem.rescanCount, 0)
        XCTAssertEqual(harness.hotKeys.registered.count, 1)
        XCTAssertEqual(harness.mouse.startValues, [true])
        XCTAssertEqual(statuses.last?.0, "[1T]")
        XCTAssertNil(statuses.last?.1)

        harness.controller.disable()

        XCTAssertFalse(harness.controller.isEnabled)
        XCTAssertEqual(harness.hotKeys.unregisterCount, 1)
        XCTAssertEqual(harness.mouse.stopCount, 1)
        XCTAssertNil(focusFrames.last!)
        XCTAssertEqual(statuses.last?.0, "Paused")

        harness.controller.enable()
        XCTAssertEqual(harness.windowSystem.rescanCount, 1)
    }

    func testEnableReportsHotKeyAndMouseFailures() {
        let hotKeyFailure = makeHarness()
        hotKeyFailure.hotKeys.error = TestControllerError.expected
        var hotKeyStatus: (String, String?)?
        hotKeyFailure.controller.onStatus = { hotKeyStatus = ($0, $1) }

        hotKeyFailure.controller.enable()

        XCTAssertFalse(hotKeyFailure.controller.isEnabled)
        XCTAssertTrue(hotKeyStatus?.1?.contains("Hotkeys") == true)
        XCTAssertEqual(hotKeyFailure.windowSystem.startCount, 0)

        let mouseFailure = makeHarness()
        mouseFailure.mouse.startResult = false
        var mouseStatus: (String, String?)?
        mouseFailure.controller.onStatus = { mouseStatus = ($0, $1) }

        mouseFailure.controller.enable()

        XCTAssertTrue(mouseFailure.controller.isEnabled)
        XCTAssertTrue(mouseStatus?.1?.contains("mouse event tap") == true)
    }

    func testWindowInventoryAndCommandsRouteThroughController() {
        let harness = makeHarness()
        let first = WindowToken(pid: 40, id: 1)
        let second = WindowToken(pid: 40, id: 2)
        let third = WindowToken(pid: 40, id: 3)
        harness.environment.frontmostPID = 40
        harness.controller.start()

        harness.controller.handle([.windows(40, [
            snapshot(first, x: 0),
            snapshot(second, x: 300, focused: true),
            snapshot(third, x: 600),
        ])])

        XCTAssertEqual(Set(harness.controller.world.visible.windows), [first, second, third])
        XCTAssertEqual(harness.controller.world.visible.focused, second)
        XCTAssertFalse(harness.windowSystem.writes.isEmpty)
        XCTAssertFalse(harness.mouse.updates.isEmpty)

        harness.windowSystem.liveFocused = second
        harness.controller.execute(.fullscreen)
        XCTAssertEqual(harness.controller.world.visible.fullscreen, second)
        harness.controller.execute(.fullscreen)
        XCTAssertNil(harness.controller.world.visible.fullscreen)

        harness.controller.execute(.floating(.enable))
        XCTAssertNotNil(harness.controller.world.visible.floating[second])
        harness.controller.execute(.floating(.enable))
        XCTAssertNotNil(harness.controller.world.visible.floating[second])
        harness.controller.execute(.floating(.disable))
        XCTAssertNil(harness.controller.world.visible.floating[second])

        harness.controller.execute(.layout(.niri))
        harness.controller.execute(.consume(.left))
        harness.controller.execute(.expel(.right))
        harness.controller.execute(.centerColumn)
        harness.controller.execute(.setColumnWidth(0.75))
        harness.controller.execute(.focusNext)
        harness.controller.execute(.focus(.left))
        harness.controller.execute(.move(.right))
        harness.controller.execute(.resize(.right, 50))
        harness.controller.execute(.balance)
        harness.controller.execute(.split(.vertical))

        XCTAssertEqual(harness.controller.world.visible.layout.mode, .niri)
        XCTAssertFalse(harness.windowSystem.focused.isEmpty)

        let registrations = harness.hotKeys.registered.count
        harness.controller.execute(.mode("resize"))
        XCTAssertEqual(harness.hotKeys.registered.count, registrations + 1)
        harness.controller.execute(.mode("missing"))
        XCTAssertEqual(harness.hotKeys.registered.count, registrations + 1)

        harness.controller.execute(.execute("printf test"))
        XCTAssertEqual(harness.environment.shellCommands, ["printf test"])
        harness.controller.execute(.nop)
    }

    func testWorkspaceFollowAndMouseEventsUseVisibleWindowsOnly() {
        let harness = makeHarness()
        let first = WindowToken(pid: 50, id: 1)
        let second = WindowToken(pid: 50, id: 2)
        harness.environment.frontmostPID = 50
        harness.controller.start()
        harness.controller.handle([.windows(50, [
            snapshot(first, x: 0, focused: true),
            snapshot(second, x: 500),
        ])])

        harness.windowSystem.liveFocused = first
        harness.controller.execute(.moveToWorkspace(2, follow: true))
        XCTAssertEqual(harness.controller.world.workspace(of: first), 2)
        XCTAssertEqual(harness.controller.world.visibleWorkspace, 2)

        harness.mouse.layoutTarget = second
        harness.controller.execute(.workspace(1))
        XCTAssertEqual(harness.controller.world.visible.focused, second)
        XCTAssertTrue(harness.windowSystem.focused.contains(second))

        harness.controller.handle([
            .mouse(second),
            .mouseResize(second, .right, 40),
            .mouseColumnMove(second, second),
            .frameObserved(second, CGRect(x: 10, y: 10, width: 400, height: 300)),
        ])
        XCTAssertEqual(harness.controller.world.visible.focused, second)

        harness.controller.execute(.workspace(2))
        let focusCount = harness.windowSystem.focused.count
        harness.controller.handle([.mouse(second), .mouseResize(second, .right, 40)])
        XCTAssertEqual(harness.windowSystem.focused.count, focusCount)

        harness.controller.handle([.windows(50, [snapshot(first, x: 0, focused: true)])])
        XCTAssertNil(harness.controller.world.workspace(of: second))
    }

    func testColumnDragFeedbackUsesWholeNiriTargetColumnAndClears() {
        let harness = makeHarness()
        let first = WindowToken(pid: 55, id: 1)
        let second = WindowToken(pid: 55, id: 2)
        let third = WindowToken(pid: 55, id: 3)
        harness.environment.frontmostPID = 55
        harness.controller.start()
        harness.controller.handle([.windows(55, [
            snapshot(first, x: 0),
            snapshot(second, x: 400),
            snapshot(third, x: 800, focused: true),
        ])])
        harness.controller.execute(.layout(.niri))
        harness.windowSystem.liveFocused = third
        harness.controller.execute(.consume(.left))

        guard case let .niri(layout) = harness.controller.world.visible.layout,
              let column = layout.columns.first(where: { $0.windows.contains(second) }),
              let frames = harness.mouse.updates.last?.frames
        else {
            return XCTFail("expected a Niri target column")
        }
        let targetFrames = column.windows.compactMap { frames[$0] }
        let expected = targetFrames.dropFirst().reduce(targetFrames[0]) { $0.union($1) }
        var feedback: [(Bool, CGRect?)] = []
        harness.controller.onColumnDragFeedback = { feedback.append(($0, $1)) }

        harness.controller.handle([.mouseColumnDragFeedback(.active(target: second))])
        harness.controller.handle([.mouseColumnDragFeedback(.inactive)])

        XCTAssertEqual(feedback.count, 2)
        XCTAssertTrue(feedback[0].0)
        XCTAssertEqual(feedback[0].1, expected)
        XCTAssertFalse(feedback[1].0)
        XCTAssertNil(feedback[1].1)
    }

    func testColumnDragFeedbackUsesBSPTargetAndClearsWhenDisabled() {
        let harness = makeHarness()
        let first = WindowToken(pid: 56, id: 1)
        let second = WindowToken(pid: 56, id: 2)
        harness.environment.frontmostPID = 56
        harness.controller.start()
        harness.controller.handle([.windows(56, [
            snapshot(first, x: 0, focused: true),
            snapshot(second, x: 500),
        ])])
        let expected = harness.mouse.updates.last?.frames[second]
        var feedback: [(Bool, CGRect?)] = []
        harness.controller.onColumnDragFeedback = { feedback.append(($0, $1)) }

        harness.controller.handle([.mouseColumnDragFeedback(.active(target: nil))])
        harness.controller.handle([.mouseColumnDragFeedback(.active(target: second))])
        harness.controller.handle([.mouseColumnDragFeedback(.inactive)])
        harness.controller.disable()
        harness.controller.handle([.mouseColumnDragFeedback(.active(target: second))])

        XCTAssertEqual(feedback.count, 5)
        XCTAssertTrue(feedback[0].0)
        XCTAssertNil(feedback[0].1)
        XCTAssertTrue(feedback[1].0)
        XCTAssertEqual(feedback[1].1, expected)
        XCTAssertFalse(feedback[2].0)
        XCTAssertFalse(feedback[3].0)
        XCTAssertFalse(feedback[4].0)
    }

    func testNiriSingleWindowFullWidthCanBeDisabledByReloadingConfig() throws {
        let harness = makeHarness()
        let window = WindowToken(pid: 57, id: 1)
        harness.environment.frontmostPID = 57
        harness.controller.start()
        harness.controller.handle([.windows(57, [snapshot(window, x: 0, focused: true)])])
        harness.controller.execute(.layout(.niri))
        XCTAssertEqual(harness.mouse.updates.last?.frames[window]?.width, bounds.width)

        try FileManager.default.createDirectory(
            at: harness.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WMController.defaultConfig
            .replacingOccurrences(
                of: "niri single-window-full-width true",
                with: "niri single-window-full-width false"
            )
            .write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.controller.reload()

        XCTAssertEqual(harness.mouse.updates.last?.frames[window]?.width, bounds.width / 2)
    }

    func testReloadErrorsModesShellAndEnvironmentActionsAreReported() throws {
        let harness = makeHarness()
        var statuses: [(String, String?)] = []
        var borderStyles: [BorderStyle] = []
        harness.controller.onStatus = { statuses.append(($0, $1)) }
        harness.controller.onBorderStyle = { borderStyles.append($0) }
        harness.controller.start()
        try FileManager.default.createDirectory(
            at: harness.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try "unknown-directive true".write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.controller.execute(.reload)
        XCTAssertTrue(statuses.last?.1?.contains("line 1") == true)

        try WMController.defaultConfig
            .replacingOccurrences(of: "workspace-count 10", with: "workspace-count 9")
            .write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.controller.reload()
        XCTAssertTrue(statuses.last?.1?.contains("workspace-count must be 10") == true)

        try WMController.defaultConfig
            .replacingOccurrences(of: "border width 2", with: "border width 4")
            .write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.controller.reload()
        XCTAssertEqual(borderStyles.last?.width, 4)
        XCTAssertNil(statuses.last?.1)

        harness.hotKeys.error = TestControllerError.expected
        harness.controller.execute(.mode("resize"))
        XCTAssertTrue(statuses.last?.1?.contains("expected") == true)

        harness.environment.shellError = TestControllerError.expected
        harness.controller.execute(.execute("fails"))
        XCTAssertTrue(statuses.last?.1?.contains("expected") == true)

        harness.controller.openAccessibilitySettings()
        XCTAssertEqual(harness.environment.accessibilityOpenCount, 1)
        harness.controller.quit()
        XCTAssertEqual(harness.windowSystem.stopCount, 1)
        XCTAssertEqual(harness.environment.terminateCount, 1)
    }

    func testDisableRestoresPersistedFramesBeforePublishingPaused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TrimWMControllerTests-\(UUID().uuidString)")
        let token = WindowToken(pid: 60, id: 1)
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        var journal = CrashJournal(url: directory.appending(path: "journal.json"), bootID: "boot")
        try journal.record(token, bundleID: "com.example.app", frame: frame)
        let harness = makeHarness(journal: journal)
        harness.windowSystem.contained[token] = "com.example.app"
        harness.windowSystem.syncResult = true

        harness.controller.disable()

        XCTAssertEqual(harness.windowSystem.syncWrites.count, 1)
        XCTAssertEqual(harness.windowSystem.syncWrites.first?.0, token)
        XCTAssertEqual(harness.windowSystem.syncWrites.first?.1, frame)
    }

    private func makeHarness(
        trusted: Bool = true,
        journal: CrashJournal? = nil
    ) -> ControllerHarness {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TrimWMControllerTests-\(UUID().uuidString)")
        let configURL = directory.appending(path: "config")
        let windowSystem = FakeWindowSystem()
        let hotKeys = FakeHotKeys()
        let mouse = FakeMouse()
        let environment = TestControllerEnvironment(
            trusted: trusted,
            bounds: bounds
        )
        let controller = WMController(
            windowSystem: windowSystem,
            hotKeys: hotKeys,
            mouse: mouse,
            environment: environment.value,
            configURL: configURL,
            journal: journal ?? CrashJournal(
                url: directory.appending(path: "journal.json"),
                bootID: "boot"
            )
        )
        return ControllerHarness(
            controller: controller,
            windowSystem: windowSystem,
            hotKeys: hotKeys,
            mouse: mouse,
            environment: environment,
            configURL: configURL
        )
    }

    private func snapshot(
        _ token: WindowToken,
        x: CGFloat,
        focused: Bool = false
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            token: token,
            bundleID: "com.example.app",
            title: "\(token.id)",
            frame: CGRect(x: x, y: 0, width: 400, height: 300),
            disposition: .tiled,
            isFocused: focused,
            isOnScreen: true,
            isOnCurrentSpace: true,
            minimumSize: CGSize(width: 100, height: 80),
            element: AXUIElementCreateApplication(token.pid)
        )
    }
}

@MainActor
private struct ControllerHarness {
    let controller: WMController
    let windowSystem: FakeWindowSystem
    let hotKeys: FakeHotKeys
    let mouse: FakeMouse
    let environment: TestControllerEnvironment
    let configURL: URL
}

@MainActor
private final class FakeWindowSystem: WindowSystemControlling {
    var onUpdate: ((pid_t, [AXWindowSnapshot]) -> Void)?
    var onFrame: ((WindowToken, CGRect) -> Void)?
    var onApplicationActivated: ((pid_t) -> Void)?
    var mouseSurfaces: [MouseSurface] = []
    var liveFocused: WindowToken?
    var contained: [WindowToken: String] = [:]
    var syncResult = false
    var startCount = 0
    var stopCount = 0
    var rescanCount = 0
    var writes: [(WindowToken, CGRect)] = []
    var syncWrites: [(WindowToken, CGRect)] = []
    var focused: [WindowToken] = []

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func rescan() { rescanCount += 1 }
    func frontmostFocusedWindow() -> WindowToken? { liveFocused }

    func setFrame(
        _ frame: CGRect,
        for token: WindowToken,
        completion: @escaping @Sendable (AXFrameWriteResult) -> Void
    ) {
        writes.append((token, frame))
        completion(AXFrameWriteResult(observed: frame, succeeded: true))
    }

    func setFrameSync(_ frame: CGRect, for token: WindowToken) -> Bool {
        syncWrites.append((token, frame))
        return syncResult
    }

    func focus(_ token: WindowToken) { focused.append(token) }
    func contains(_ token: WindowToken, bundleID: String) -> Bool {
        contained[token] == bundleID
    }
}

private final class FakeHotKeys: HotKeyControlling {
    var onCommand: (@Sendable (WMCommand) -> Void)?
    var error: Error?
    var registered: [[Binding]] = []
    var unregisterCount = 0

    func register(_ bindings: [Binding]) throws {
        if let error { throw error }
        registered.append(bindings)
    }

    func unregister() { unregisterCount += 1 }
}

private final class FakeMouse: MouseControlling {
    struct Update {
        let frames: [WindowToken: CGRect]
        let frontToBack: [MouseSurface]
        let columnDraggable: Set<WindowToken>
    }

    var onWindow: (@Sendable (WindowToken) -> Void)?
    var onResize: (@Sendable (WindowToken, Direction, CGFloat) -> Void)?
    var onColumnMove: (@Sendable (WindowToken, WindowToken) -> Void)?
    var onColumnDragFeedback: (@Sendable (MouseColumnDragFeedback) -> Void)?
    var startResult = true
    var startValues: [Bool] = []
    var stopCount = 0
    var updates: [Update] = []
    var layoutTarget: WindowToken?

    func start(focusesOnMove: Bool) -> Bool {
        startValues.append(focusesOnMove)
        return startResult
    }

    func stop() { stopCount += 1 }

    func update(
        _ frames: [WindowToken: CGRect],
        frontToBack: [MouseSurface],
        columnDraggable: Set<WindowToken>
    ) {
        updates.append(Update(
            frames: frames,
            frontToBack: frontToBack,
            columnDraggable: columnDraggable
        ))
    }

    func targetAfterLayoutChange() -> WindowToken? { layoutTarget }
}

@MainActor
private final class TestControllerEnvironment {
    var trusted: Bool
    var frontmostPID: pid_t?
    var requestTrustCount = 0
    var accessibilityOpenCount = 0
    var terminateCount = 0
    var shellCommands: [String] = []
    var shellError: Error?
    let bounds: CGRect

    init(trusted: Bool, bounds: CGRect) {
        self.trusted = trusted
        self.bounds = bounds
    }

    var value: ControllerEnvironment {
        ControllerEnvironment(
            isTrusted: { self.trusted },
            requestTrust: { self.requestTrustCount += 1 },
            mainScreenBounds: { self.bounds },
            displayBounds: { [self.bounds] },
            frontmostPID: { self.frontmostPID },
            runShell: { command in
                self.shellCommands.append(command)
                if let shellError = self.shellError { throw shellError }
            },
            openAccessibilitySettings: { self.accessibilityOpenCount += 1 },
            terminate: { self.terminateCount += 1 }
        )
    }
}

private enum TestControllerError: Error {
    case expected
}
