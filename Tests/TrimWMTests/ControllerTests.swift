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

    func testStatusMenuMetadataIncludesVersionAndChangelog() {
        XCTAssertEqual(
            AppMetadata.version(["CFBundleShortVersionString": "0.3.1"]),
            "0.3.1"
        )
        XCTAssertEqual(AppMetadata.version([:]), "development")
        XCTAssertEqual(
            AppMetadata.menuTitle(status: nil, error: nil, version: "0.3.1"),
            "TrimWM 0.3.1"
        )
        XCTAssertEqual(
            AppMetadata.menuTitle(status: "Paused", error: nil, version: "0.3.1"),
            "TrimWM 0.3.1 · Paused"
        )
        XCTAssertEqual(
            AppMetadata.menuTitle(status: "Paused", error: "Configuration failed", version: "0.3.1"),
            "TrimWM 0.3.1 · Configuration failed"
        )
        XCTAssertEqual(
            AppMetadata.changelogURL.absoluteString,
            "https://github.com/cornz/TrimWM/blob/main/CHANGELOG.md"
        )
    }

    func testOpenConfigCreatesDefaultOnceAndUsesTextEditor() throws {
        let harness = makeHarness()

        harness.controller.openConfig()

        XCTAssertEqual(harness.environment.openedTextFiles, [harness.configURL])
        XCTAssertEqual(
            try String(contentsOf: harness.configURL, encoding: .utf8),
            WMController.defaultConfig
        )

        try "custom config".write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.controller.openConfig()

        XCTAssertEqual(harness.environment.openedTextFiles, [harness.configURL, harness.configURL])
        XCTAssertEqual(try String(contentsOf: harness.configURL, encoding: .utf8), "custom config")
    }

    func testSavedConfigReloadsOnlyWhenItsContentChanges() throws {
        let harness = makeHarness()
        var widths: [CGFloat] = []
        harness.controller.onBorderStyle = { widths.append($0.width) }
        try FileManager.default.createDirectory(
            at: harness.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try WMController.defaultConfig.write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.controller.start()
        XCTAssertEqual(widths, [2])

        harness.environment.configChanged?()
        XCTAssertEqual(widths, [2])

        let edited = WMController.defaultConfig.replacingOccurrences(of: "border width 2", with: "border width 7")
        try edited.write(to: harness.configURL, atomically: true, encoding: .utf8)
        harness.environment.configChanged?()
        XCTAssertEqual(widths, [2, 7])

        harness.environment.configChanged?()
        XCTAssertEqual(widths, [2, 7])
    }

    func testTrustLifecycleStartsOnceAndDisablesCleanly() {
        let harness = makeHarness(trusted: false)
        var statuses: [(String, String?)] = []
        var focusFrames: [FocusBorderTarget?] = []
        harness.controller.onStatus = { statuses.append(($0, $1)) }
        harness.controller.onFocusBorder = { focusFrames.append($0) }

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

    func testClosingFocusedWindowFocusesRemainingWindow() {
        let harness = makeHarness()
        let codex = WindowToken(pid: 40, id: 1)
        let edge = WindowToken(pid: 41, id: 2)
        harness.environment.frontmostPID = edge.pid
        harness.controller.start()
        harness.controller.handle([.windows(codex.pid, [snapshot(codex, x: 0)])])
        harness.controller.handle([.windows(edge.pid, [snapshot(edge, x: 500, focused: true)])])
        XCTAssertEqual(harness.controller.world.visible.focused, edge)

        harness.windowSystem.focused.removeAll()
        harness.controller.handle([.windows(edge.pid, [])])

        XCTAssertEqual(harness.controller.world.visible.focused, codex)
        XCTAssertEqual(harness.windowSystem.focused, [codex])
        XCTAssertEqual(harness.mouse.updates.last?.frames[codex]?.width, bounds.width)
    }

    func testRelaunchedAppWindowReturnsToThePlaceOfItsOldWindow() {
        let harness = makeHarness()
        let slack = WindowToken(pid: 40, id: 1)
        let relaunched = WindowToken(pid: 50, id: 7)
        let messages = WindowToken(pid: 41, id: 2)
        harness.environment.frontmostPID = messages.pid
        harness.controller.start()
        harness.controller.handle([.windows(slack.pid, [snapshot(slack, x: 0, bundleID: "com.example.slack")])])
        harness.controller.handle([.windows(messages.pid, [snapshot(messages, x: 500, focused: true)])])

        harness.controller.handle([.windows(slack.pid, [])])
        harness.environment.now += WMController.departedLifetime
        harness.controller.handle([.windows(relaunched.pid, [snapshot(relaunched, x: 0, bundleID: "com.example.slack")])])

        XCTAssertEqual(harness.mouse.updates.last?.frames[relaunched]?.minX, 0)
        XCTAssertEqual(harness.mouse.updates.last?.frames[messages]?.minX, 500)
    }

    func testWindowOfAnAppThatLeftLongAgoSplitsFocusedWindow() {
        let harness = makeHarness()
        let slack = WindowToken(pid: 40, id: 1)
        let relaunched = WindowToken(pid: 50, id: 7)
        let messages = WindowToken(pid: 41, id: 2)
        harness.environment.frontmostPID = messages.pid
        harness.controller.start()
        harness.controller.handle([.windows(slack.pid, [snapshot(slack, x: 0, bundleID: "com.example.slack")])])
        harness.controller.handle([.windows(messages.pid, [snapshot(messages, x: 500, focused: true)])])

        harness.controller.handle([.windows(slack.pid, [])])
        harness.environment.now += WMController.departedLifetime + 1
        harness.controller.handle([.windows(relaunched.pid, [snapshot(relaunched, x: 0, bundleID: "com.example.slack")])])

        XCTAssertEqual(harness.mouse.updates.last?.frames[messages]?.minX, 0)
        XCTAssertEqual(harness.mouse.updates.last?.frames[relaunched]?.minX, 500)
    }

    func testFloatingWindowKeepsManualMovesAndResizesAndUpdatesFocusBorder() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.environment.frontmostPID = token.pid
        var focusFrame: CGRect?
        harness.controller.onFocusBorder = { focusFrame = $0?.frame }
        harness.controller.start()
        harness.controller.handle([.windows(token.pid, [
            snapshot(token, x: 100, focused: true, disposition: .floating),
        ])])

        for frame in [CGRect(x: 180, y: 90, width: 400, height: 300),
                      CGRect(x: 240, y: 120, width: 520, height: 360)] {
            harness.controller.handle([.frameObserved(token, frame)])
            XCTAssertEqual(harness.controller.world.visible.floating[token], frame)
            XCTAssertEqual(harness.mouse.updates.last?.frames[token], frame)
            XCTAssertEqual(focusFrame, frame)
        }
        XCTAssertTrue(harness.windowSystem.writes.isEmpty)
    }

    func testFocusBorderFollowsTheObservedFrameOfATiledWindow() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.environment.frontmostPID = token.pid
        var focusTarget: FocusBorderTarget?
        harness.controller.onFocusBorder = { focusTarget = $0 }
        harness.controller.start()
        harness.controller.handle([.windows(token.pid, [snapshot(token, x: 0, focused: true)])])
        let desired = harness.windowSystem.writes.last!.1

        let snapped = CGRect(x: desired.minX, y: desired.minY, width: desired.width - 7, height: desired.height - 5)
        harness.controller.handle([.frameObserved(token, snapped)])

        XCTAssertEqual(focusTarget, FocusBorderTarget(window: token.id, frame: snapped))
        XCTAssertEqual(harness.mouse.updates.last?.frames[token], desired)

        focusTarget = nil
        harness.controller.handle([.windowsReordered])
        XCTAssertEqual(focusTarget, FocusBorderTarget(window: token.id, frame: snapped))
    }

    func testFloatingWindowInventoryAdoptsManualFrameChanges() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.controller.start()
        harness.controller.handle([.windows(token.pid, [snapshot(token, x: 100, disposition: .floating)])])
        let moved = snapshot(token, x: 250, disposition: .floating)
        moved.frame.size = CGSize(width: 500, height: 350)

        harness.controller.handle([.windows(token.pid, [moved])])

        XCTAssertEqual(harness.controller.world.visible.floating[token], moved.frame)
        XCTAssertTrue(harness.windowSystem.writes.isEmpty)
    }

    func testFloatingWindowIgnoresIntermediateCommandResizeEcho() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.controller.start()
        harness.controller.handle([.windows(token.pid, [snapshot(token, x: 100, disposition: .floating)])])
        harness.controller.execute(.resize(.right, 100))
        let target = harness.controller.world.visible.floating[token]!
        let intermediate = CGRect(x: 100, y: 0, width: 450, height: 300)

        harness.controller.handle([.frameObserved(token, intermediate)])
        let scanned = snapshot(token, x: 100, disposition: .floating)
        scanned.frame = intermediate
        harness.controller.handle([.windows(token.pid, [scanned])])

        XCTAssertEqual(harness.controller.world.visible.floating[token], target)
        XCTAssertEqual(harness.windowSystem.writes.count, 1)
        harness.controller.handle([.frameWriteResult(token, target, .init(observed: target, succeeded: true))])
        let moved = target.offsetBy(dx: 80, dy: 60)
        harness.controller.handle([.frameObserved(token, moved)])
        XCTAssertEqual(harness.controller.world.visible.floating[token], moved)
        XCTAssertEqual(harness.windowSystem.writes.count, 1)
    }

    func testFloatingWindowRetainsManualFrameAcrossWorkspaceHideAndRestore() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.controller.start()
        harness.controller.handle([.windows(token.pid, [snapshot(token, x: 100, disposition: .floating)])])
        let moved = CGRect(x: 240, y: 120, width: 500, height: 350)
        harness.controller.handle([.frameObserved(token, moved)])
        harness.controller.execute(.workspace(2))
        let hidden = harness.windowSystem.writes.last!.1
        harness.controller.handle([
            .frameWriteResult(token, hidden, .init(observed: hidden, succeeded: true)),
            .frameObserved(token, hidden),
        ])
        XCTAssertEqual(harness.controller.world.workspaces[0].floating[token], moved)

        harness.controller.execute(.workspace(1))
        XCTAssertEqual(harness.windowSystem.writes.last?.1, moved)
        harness.controller.handle([.frameObserved(token, hidden)])
        XCTAssertEqual(harness.controller.world.visible.floating[token], moved)
        harness.controller.handle([
            .frameWriteResult(token, moved, .init(observed: moved, succeeded: true)),
            .frameObserved(token, moved),
        ])
        let movedAgain = moved.offsetBy(dx: 30, dy: 20)
        let writeCount = harness.windowSystem.writes.count
        harness.controller.handle([.frameObserved(token, movedAgain)])
        XCTAssertEqual(harness.controller.world.visible.floating[token], movedAgain)
        XCTAssertEqual(harness.windowSystem.writes.count, writeCount)
    }

    func testFloatingFullscreenDoesNotReplaceRestoreFrame() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.environment.frontmostPID = token.pid
        harness.windowSystem.liveFocused = token
        harness.controller.start()
        let window = snapshot(token, x: 100, focused: true, disposition: .floating)
        let original = window.frame
        harness.controller.handle([.windows(token.pid, [window])])
        harness.controller.execute(.fullscreen)
        harness.controller.handle([
            .frameWriteResult(token, bounds, .init(observed: bounds, succeeded: true)),
            .frameObserved(token, bounds),
        ])
        XCTAssertEqual(harness.controller.world.visible.floating[token], original)

        harness.controller.execute(.fullscreen)
        XCTAssertEqual(harness.windowSystem.writes.last?.1, original)
    }

    func testTiledWindowStillReturnsToItsTileAfterManualMovement() {
        let harness = makeHarness()
        let token = WindowToken(pid: 40, id: 1)
        harness.controller.start()
        harness.controller.handle([.windows(token.pid, [snapshot(token, x: 100)])])
        let tile = harness.windowSystem.writes.last!.1
        harness.controller.handle([
            .frameWriteResult(token, tile, .init(observed: tile, succeeded: true)),
            .frameObserved(token, tile.offsetBy(dx: 100, dy: 50)),
        ])
        XCTAssertNil(harness.controller.world.visible.floating[token])
        XCTAssertEqual(harness.windowSystem.writes.count, 2)
        XCTAssertEqual(harness.windowSystem.writes.last?.1, tile)
    }

    func testClosingBackgroundWindowDoesNotStealFocus() {
        let harness = makeHarness()
        let codex = WindowToken(pid: 40, id: 1)
        let edge = WindowToken(pid: 41, id: 2)
        harness.environment.frontmostPID = codex.pid
        harness.controller.start()
        harness.controller.handle([.windows(edge.pid, [snapshot(edge, x: 500)])])
        harness.controller.handle([.windows(codex.pid, [snapshot(codex, x: 0, focused: true)])])
        XCTAssertEqual(harness.controller.world.visible.focused, codex)

        harness.windowSystem.focused.removeAll()
        harness.controller.handle([.windows(edge.pid, [])])

        XCTAssertEqual(harness.controller.world.visible.focused, codex)
        XCTAssertTrue(harness.windowSystem.focused.isEmpty)
    }

    func testAppSwitchLeavesFullscreenAndRevealsFocusedWindow() {
        let harness = makeHarness()
        let fullscreen = WindowToken(pid: 40, id: 1)
        let otherApplication = WindowToken(pid: 41, id: 2)
        harness.environment.frontmostPID = fullscreen.pid
        harness.controller.start()
        harness.controller.handle([.windows(fullscreen.pid, [
            snapshot(fullscreen, x: 0, focused: true),
        ])])
        harness.controller.handle([.windows(otherApplication.pid, [
            snapshot(otherApplication, x: 500),
        ])])
        harness.windowSystem.liveFocused = fullscreen
        harness.controller.execute(.fullscreen)
        XCTAssertEqual(harness.controller.world.visible.fullscreen, fullscreen)

        harness.environment.frontmostPID = otherApplication.pid
        harness.controller.handle([.windows(otherApplication.pid, [
            snapshot(otherApplication, x: 500, focused: true),
        ])])

        XCTAssertNil(harness.controller.world.visible.fullscreen)
        XCTAssertEqual(harness.controller.world.visible.focused, otherApplication)
        XCTAssertNotNil(harness.mouse.updates.last?.frames[otherApplication])
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

    func testClosedNiriWindowIsRemovedWhenAXKeepsItsOffscreenElement() {
        let harness = makeHarness()
        let first = WindowToken(pid: 58, id: 1)
        let second = WindowToken(pid: 58, id: 2)
        harness.environment.frontmostPID = 58
        harness.controller.start()
        harness.controller.handle([.windows(58, [
            snapshot(first, x: 0, focused: true),
            snapshot(second, x: 500),
        ])])
        harness.controller.execute(.layout(.niri))
        XCTAssertEqual(harness.mouse.updates.last?.frames[first]?.width, bounds.width / 2)

        harness.controller.handle([.windows(58, [
            snapshot(first, x: 0, focused: true),
            snapshot(second, x: 500, isOnScreen: false),
        ])])

        XCTAssertNil(harness.controller.world.workspace(of: second))
        XCTAssertEqual(harness.mouse.updates.last?.frames[first]?.width, bounds.width)
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

    func testLearnedAppMinimumWidensNewWindowsOfThatApp() {
        var minimums = AppMinimumSizes(url: nil)
        for target in [400.0, 300.0] {
            _ = minimums.refused(
                target: CGRect(x: 0, y: 0, width: target, height: 600),
                observed: CGRect(x: 0, y: 0, width: 700, height: 600),
                bundleID: "com.example.wide"
            )
        }
        let harness = makeHarness(appMinimumSizes: minimums)
        let wide = WindowToken(pid: 40, id: 1)
        let other = WindowToken(pid: 41, id: 2)
        harness.controller.start()

        harness.controller.handle([.windows(40, [snapshot(wide, x: 0, width: 700, bundleID: "com.example.wide")])])
        harness.controller.handle([.windows(41, [snapshot(other, x: 500)])])

        let frames = Dictionary(harness.windowSystem.writes.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
        XCTAssertGreaterThanOrEqual(frames[wide]!.width, 700)
        XCTAssertLessThanOrEqual(frames[other]!.width, 300)
    }

    func testLearnedAppMinimumIsForgottenOnceAWindowOfThatAppIsSeenBelowIt() {
        var minimums = AppMinimumSizes(url: nil)
        for target in [400.0, 300.0] {
            _ = minimums.refused(
                target: CGRect(x: 0, y: 0, width: target, height: 600),
                observed: CGRect(x: 0, y: 0, width: 1000, height: 600),
                bundleID: "com.example.slow"
            )
        }
        let harness = makeHarness(appMinimumSizes: minimums)
        let slow = WindowToken(pid: 40, id: 1)
        let other = WindowToken(pid: 41, id: 2)
        harness.windowSystem.writeResult = { _, frame in AXFrameWriteResult(observed: frame, succeeded: true) }
        harness.controller.start()
        harness.controller.handle([.windows(40, [snapshot(slow, x: 0, width: 1000, bundleID: "com.example.slow")])])
        harness.controller.handle([.windows(41, [snapshot(other, x: 500)])])
        settleWrites(harness)
        XCTAssertEqual(harness.windowSystem.writes.last { $0.0 == other }?.1.width, 1000)

        harness.controller.handle([.frameObserved(slow, CGRect(x: 0, y: 0, width: 500, height: 600))])
        harness.controller.handle([.windows(41, [])])
        settleWrites(harness)
        let next = WindowToken(pid: 42, id: 3)
        harness.controller.handle([.windows(42, [snapshot(next, x: 500, bundleID: "com.example.next")])])
        settleWrites(harness)

        XCTAssertEqual(harness.windowSystem.writes.last { $0.0 == next }?.1, CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    func testSlowlyAppliedFrameIsWrittenAgainLaterInsteadOfLearnedAsMinimum() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TrimWMControllerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "minimum-sizes.json")
        let harness = makeHarness(appMinimumSizes: AppMinimumSizes(url: url))
        let slow = WindowToken(pid: 40, id: 1)
        let other = WindowToken(pid: 41, id: 2)
        let half = CGRect(x: 0, y: 0, width: 500, height: 600)
        // Like Warp: the app applies a write on its own event loop, so its
        // frame read right after the write is still the old one.
        var applied = CGRect(x: 0, y: 0, width: 1000, height: 600)
        harness.windowSystem.writeResult = { token, frame in
            let observed = token == slow ? applied : frame
            return AXFrameWriteResult(observed: observed, succeeded: observed == frame)
        }
        harness.controller.start()
        harness.controller.handle([.windows(40, [snapshot(slow, x: 0, width: 1000, bundleID: "com.example.slow")])])
        harness.controller.handle([.windows(41, [snapshot(other, x: 500)])])
        settleWrites(harness)

        XCTAssertEqual(harness.environment.delays, [FrameLedger.retryDelay])
        applied = half
        harness.controller.handle([.frameObserved(slow, half)])
        harness.environment.runDelayed()
        settleWrites(harness)

        XCTAssertNil(AppMinimumSizes(url: url).value(for: "com.example.slow"))
        let frames = Dictionary(harness.windowSystem.writes.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
        XCTAssertEqual(frames[slow], half)
        XCTAssertEqual(frames[other], CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    func testTabsShowOnlyTheActiveTabAndPublishTheTabBar() {
        let harness = makeHarness()
        var bars: [TabBarModel?] = []
        var workspaces: [[StatusWorkspace]] = []
        harness.controller.onTabBar = { bars.append($0) }
        harness.controller.onWorkspaces = { workspaces.append($0) }
        harness.windowSystem.writeResult = { _, frame in AXFrameWriteResult(observed: frame, succeeded: true) }
        let warp = WindowToken(pid: 40, id: 1)
        let edge = WindowToken(pid: 41, id: 2)
        harness.controller.start()
        harness.controller.handle([.windows(40, [snapshot(warp, x: 0, title: "zsh")])])
        harness.controller.handle([.windows(41, [snapshot(edge, x: 500, title: "New Tab")])])
        settleWrites(harness)
        harness.windowSystem.writes.removeAll()

        harness.controller.execute(.layout(.tabs))
        settleWrites(harness)

        let content = CGRect(x: 0, y: 38, width: 1000, height: 562)
        XCTAssertEqual(harness.windowSystem.writes.last { $0.0 == edge }?.1, content)
        XCTAssertLessThan(harness.windowSystem.writes.last { $0.0 == warp }!.1.maxX, bounds.minX + 2)
        XCTAssertEqual(bars.last??.frame, CGRect(x: 0, y: 0, width: 1000, height: 32))
        XCTAssertEqual(bars.last??.tabs, [
            TabBarTab(window: warp, title: "zsh", isActive: false),
            TabBarTab(window: edge, title: "New Tab", isActive: true),
        ])
        XCTAssertEqual(workspaces.last, [StatusWorkspace(number: 1, glyph: .tabsTop, isVisible: true)])

        harness.controller.selectTab(warp)
        settleWrites(harness)
        XCTAssertEqual(harness.windowSystem.focused.last, warp)
        XCTAssertEqual(harness.windowSystem.writes.last { $0.0 == warp }?.1, content)
        XCTAssertEqual(bars.last??.tabs.first(where: \.isActive)?.window, warp)

        harness.environment.frontmostPID = 40
        var borders: [FocusBorderTarget?] = []
        harness.controller.onFocusBorder = { borders.append($0) }
        harness.controller.execute(.layout(.autotile))
        XCTAssertNotNil(borders.last ?? nil)
        harness.controller.execute(.layout(.tabs))
        XCTAssertEqual(borders.last, .some(nil))

        harness.controller.handle([.titleObserved(warp, "vim")])
        XCTAssertEqual(bars.last??.tabs.first?.title, "vim")

        harness.controller.handle([.windows(41, [])])
        settleWrites(harness)
        XCTAssertEqual(bars.last, .some(nil))
        XCTAssertEqual(harness.windowSystem.writes.last { $0.0 == warp }?.1, bounds)

        harness.controller.disable()
        XCTAssertEqual(workspaces.last, [])
    }

    func testTabBarFollowsConfiguredPositionAndHidesInFullscreen() throws {
        let harness = makeHarness()
        try FileManager.default.createDirectory(at: harness.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "tabs position left\ntabs size 40\n".write(to: harness.configURL, atomically: true, encoding: .utf8)
        var bars: [TabBarModel?] = []
        harness.controller.onTabBar = { bars.append($0) }
        harness.windowSystem.writeResult = { _, frame in AXFrameWriteResult(observed: frame, succeeded: true) }
        let first = WindowToken(pid: 40, id: 1)
        let second = WindowToken(pid: 41, id: 2)
        harness.controller.start()
        harness.controller.handle([.windows(40, [snapshot(first, x: 0)])])
        harness.controller.handle([.windows(41, [snapshot(second, x: 500)])])
        harness.controller.execute(.layout(.tabs))
        settleWrites(harness)

        XCTAssertEqual(bars.last??.frame, CGRect(x: 0, y: 0, width: 40, height: 600))
        XCTAssertEqual(harness.windowSystem.writes.last { $0.0 == second }?.1, CGRect(x: 46, y: 0, width: 954, height: 600))

        harness.windowSystem.liveFocused = second
        harness.environment.frontmostPID = 41
        harness.controller.execute(.fullscreen)
        XCTAssertEqual(bars.last, .some(nil))
        harness.controller.execute(.fullscreen)
        XCTAssertEqual(bars.last??.settings.position, .left)
    }

    private func settleWrites(_ harness: ControllerHarness) {
        while !harness.windowSystem.results.isEmpty {
            harness.controller.handle(harness.windowSystem.takeResults())
        }
    }

    private func makeHarness(
        trusted: Bool = true,
        journal: CrashJournal? = nil,
        appMinimumSizes: AppMinimumSizes = AppMinimumSizes(url: nil)
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
            ),
            appMinimumSizes: appMinimumSizes
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
        width: CGFloat = 400,
        title: String? = nil,
        focused: Bool = false,
        isOnScreen: Bool = true,
        disposition: WindowDisposition = .tiled,
        bundleID: String = "com.example.app"
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            token: token,
            bundleID: bundleID,
            title: title ?? "\(token.id)",
            frame: CGRect(x: x, y: 0, width: width, height: 300),
            disposition: disposition,
            isFocused: focused,
            isOnScreen: isOnScreen,
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
    var onReorder: (() -> Void)?
    var onTitle: ((WindowToken, String) -> Void)?
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
    /// When set, write results are held for the test to hand to the controller.
    var writeResult: ((WindowToken, CGRect) -> AXFrameWriteResult)?
    var results: [WMEvent] = []

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
        guard let writeResult else {
            completion(AXFrameWriteResult(observed: frame, succeeded: true))
            return
        }
        results.append(.frameWriteResult(token, frame, writeResult(token, frame)))
    }

    func takeResults() -> [WMEvent] {
        defer { results.removeAll() }
        return results
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
    var openedTextFiles: [URL] = []
    var shellError: Error?
    var configChanged: (@MainActor () -> Void)?
    var delays: [TimeInterval] = []
    var now = Date(timeIntervalSinceReferenceDate: 0)
    private var delayed: [@MainActor () -> Void] = []
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
            openTextFile: { self.openedTextFiles.append($0) },
            openAccessibilitySettings: { self.accessibilityOpenCount += 1 },
            terminate: { self.terminateCount += 1 },
            watchConfig: { _, onChange in
                self.configChanged = onChange
                return NSObject()
            },
            after: { delay, work in
                self.delays.append(delay)
                self.delayed.append(work)
            },
            now: { self.now }
        )
    }

    func runDelayed() {
        let work = delayed
        delayed.removeAll()
        for item in work { item() }
    }
}

private enum TestControllerError: Error {
    case expected
}
