import CoreGraphics
import XCTest
@testable import cornzWM

final class WorldTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let gaps = LayoutGaps()

    func testWorkspacesKeepIndependentWindowSets() {
        var world = World()
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(2), to: 2, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(Set(world.visibleFrames(bounds: bounds, gaps: gaps).keys), [token(1)])
        world.switchWorkspace(to: 2)
        XCTAssertEqual(Set(world.visibleFrames(bounds: bounds, gaps: gaps).keys), [token(2)])
    }

    func testStatusListsOccupiedWorkspacesAndVisibleEmptyWorkspace() {
        var world = World(workspaceCount: 5)
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(2), to: 2, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(3), to: 5, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.setFullscreen(token(1), enabled: true)
        XCTAssertEqual(world.statusText, "1NF 2A 5A")

        world.switchWorkspace(to: 3)
        XCTAssertEqual(world.statusText, "1NF 2A 3A 5A")
    }

    func testMoveToWorkspaceCanFollowOrStay() {
        var world = World()
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.move(token(1), to: 3, follow: false, currentFrame: bounds, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(world.visibleWorkspace, 1)
        XCTAssertEqual(world.workspace(of: token(1)), 3)
        world.move(token(1), to: 4, follow: true, currentFrame: bounds, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(world.visibleWorkspace, 4)
    }

    func testMoveCommandPrefersNativeFocusFromFrontmostAppAcrossWorkspaces() {
        var world = World(workspaceCount: 3)
        let visible = WindowToken(pid: 7, id: 1)
        let activeHidden = WindowToken(pid: 8, id: 2)
        world.add(visible, to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(activeHidden, to: 2, bounds: bounds, gaps: gaps, splitRatio: 1)

        XCTAssertEqual(
            CommandTargetResolver.resolve(
                frontmostPID: 8,
                nativelyFocused: [visible, activeHidden],
                world: world
            ),
            activeHidden
        )
        XCTAssertEqual(
            CommandTargetResolver.resolve(
                frontmostPID: 9,
                nativelyFocused: [activeHidden],
                world: world
            ),
            visible
        )
    }

    func testFloatingTogglePreservesFrameAndReturnsToLayout() {
        var workspace = WorkspaceState()
        workspace.add(token(1), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        workspace.toggleFloating(token(1), currentFrame: frame, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(workspace.floating[token(1)], frame)
        XCTAssertTrue(workspace.layout.windows.isEmpty)
        workspace.toggleFloating(token(1), currentFrame: frame, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertNil(workspace.floating[token(1)])
        XCTAssertEqual(workspace.layout.windows, [token(1)])
    }

    func testLayoutConversionPreservesCanonicalOrderAndFloatingWindows() {
        var workspace = WorkspaceState()
        workspace.add(token(1), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        workspace.add(token(2), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        workspace.add(token(3), floating: CGRect(x: 1, y: 2, width: 3, height: 4), bounds: bounds, gaps: gaps, splitRatio: 1)
        workspace.changeLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(workspace.layout.windows, [token(1), token(2)])
        XCTAssertNotNil(workspace.floating[token(3)])
        workspace.changeLayout(to: .autotile, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(workspace.layout.windows, [token(1), token(2)])
    }

    func testFullscreenOnlyOverridesFocusedWindowFrame() {
        var workspace = WorkspaceState()
        workspace.add(token(1), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        workspace.add(token(2), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        let tiled = workspace.frames(bounds: bounds, gaps: gaps)
        workspace.fullscreen = token(1)
        XCTAssertEqual(workspace.frames(bounds: bounds, gaps: gaps)[token(1)], bounds)
        XCTAssertEqual(workspace.frames(bounds: bounds, gaps: gaps)[token(2)], tiled[token(2)])
        workspace.fullscreen = nil
        XCTAssertEqual(workspace.frames(bounds: bounds, gaps: gaps), tiled)
    }

    func testDirectionalFocusMoveAndResizeIncludeFloatingWindows() {
        var world = World(workspaceCount: 1)
        world.add(token(1), to: 1, bounds: bounds, gaps: .init(), splitRatio: 1)
        world.add(token(2), to: 1, floating: CGRect(x: 700, y: 100, width: 200, height: 200), bounds: bounds, gaps: .init(), splitRatio: 1)
        world.focus(token(1), bounds: bounds, gaps: .init())
        world.focus(.right, bounds: bounds, gaps: .init())
        XCTAssertEqual(world.visible.focused, token(2))
        world.moveFocused(.left, bounds: bounds, gaps: .init())
        world.resizeFocused(.right, pixels: 50, bounds: bounds)
        XCTAssertEqual(world.visible.floating[token(2)], CGRect(x: 650, y: 100, width: 250, height: 200))
    }

    func testNiriInsertionAndLayoutConversionRevealFocusedColumn() {
        var workspace = WorkspaceState()
        for id in 1...3 { workspace.add(token(CGWindowID(id)), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1) }
        workspace.changeLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertTrue(workspace.frames(bounds: bounds, gaps: gaps)[token(3)]!.intersects(bounds))

        workspace.add(token(4), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(workspace.focused, token(4))
        XCTAssertTrue(workspace.frames(bounds: bounds, gaps: gaps)[token(4)]!.intersects(bounds))
    }

    func testNiriConsumeExpelAndWidthKeepFocusedColumnVisible() {
        var world = World(workspaceCount: 1)
        for id in 1...4 { world.add(token(CGWindowID(id)), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1) }
        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.consume(.left, bounds: bounds, gaps: gaps)
        world.expel(.right, bounds: bounds, gaps: gaps)
        world.setColumnWidth(1, bounds: bounds, gaps: gaps)
        XCTAssertTrue(world.visibleFrames(bounds: bounds, gaps: gaps)[token(4)]!.intersects(bounds))
    }

    func testNiriVerticalResizeChangesFocusedStackRow() {
        var world = World(workspaceCount: 1)
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(2), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.consume(.left, bounds: bounds, gaps: gaps)
        let before = world.visibleFrames(bounds: bounds, gaps: gaps)[token(2)]!
        world.resizeFocused(.up, pixels: -60, bounds: bounds)
        let after = world.visibleFrames(bounds: bounds, gaps: gaps)
        XCTAssertLessThan(after[token(2)]!.height, before.height)
        XCTAssertEqual(after[token(1)]!.maxY, after[token(2)]!.minY)
    }

    func testEveryNiriFocusEntryPointRevealsTheFocusedColumn() {
        var world = World(workspaceCount: 1)
        for id in 1...4 { world.add(token(CGWindowID(id)), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1) }
        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)

        world.focus(token(1), bounds: bounds, gaps: gaps)
        XCTAssertTrue(world.visibleFrames(bounds: bounds, gaps: gaps)[token(1)]!.intersects(bounds))

        world.focusNext(bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(2))
        XCTAssertTrue(world.visibleFrames(bounds: bounds, gaps: gaps)[token(2)]!.intersects(bounds))

        world.focusIfVisible(token(4), bounds: bounds, gaps: gaps)
        XCTAssertTrue(world.visibleFrames(bounds: bounds, gaps: gaps)[token(4)]!.intersects(bounds))
    }

    func testNiriDirectionalFocusUsesColumnsAndRowsRatherThanGlobalGeometry() {
        var world = World(workspaceCount: 1)
        for id in 1...3 { world.add(token(CGWindowID(id)), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1) }
        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.focus(token(2), bounds: bounds, gaps: gaps)
        world.consume(.left, bounds: bounds, gaps: gaps)
        world.focus(token(3), bounds: bounds, gaps: gaps)

        world.focus(.up, bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(3))

        world.focus(.left, bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(1))
        world.focus(.down, bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(2))
    }

    func testRepeatedOrFloatingFocusDoesNotCancelNiriCentering() {
        var world = World(workspaceCount: 1)
        for id in 1...3 { world.add(token(CGWindowID(id)), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1) }
        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.focus(token(1), bounds: bounds, gaps: gaps)
        world.centerColumn(bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visibleFrames(bounds: bounds, gaps: gaps)[token(1)]?.midX, bounds.midX)

        world.focusIfVisible(token(1), bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visibleFrames(bounds: bounds, gaps: gaps)[token(1)]?.midX, bounds.midX)

        world.add(
            token(4),
            to: 1,
            floating: CGRect(x: 100, y: 100, width: 200, height: 200),
            bounds: bounds,
            gaps: gaps,
            splitRatio: 1
        )
        world.focusIfVisible(token(4), bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visibleFrames(bounds: bounds, gaps: gaps)[token(1)]?.midX, bounds.midX)
    }

    func testFocusNextWrapsAndFocusIfVisibleNeverChangesWorkspace() {
        var world = World(workspaceCount: 2)
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(2), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(3), to: 2, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.focus(token(1), bounds: bounds, gaps: gaps)
        world.focusNext(bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(2))
        world.focusNext(bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(1))
        world.focusIfVisible(token(3), bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visibleWorkspace, 1)
        XCTAssertEqual(world.visible.focused, token(1))
    }

    func testNativeApplicationFocusSwitchesToWindowsWorkspace() {
        var world = World(workspaceCount: 3)
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(2), to: 3, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(world.visibleWorkspace, 1)

        world.focus(token(2), bounds: bounds, gaps: gaps)

        XCTAssertEqual(world.visibleWorkspace, 3)
        XCTAssertEqual(world.visible.focused, token(2))
        XCTAssertEqual(Set(world.visibleFrames(bounds: bounds, gaps: gaps).keys), [token(2)])
    }

    func testTiledCommandsCoverBothLayoutsAndRemoval() {
        var world = World(workspaceCount: 1)
        for id in 1...3 { world.add(token(CGWindowID(id)), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1) }
        let before = world.visibleFrames(bounds: bounds, gaps: gaps)
        world.focus(token(1), bounds: bounds, gaps: gaps)
        world.moveFocused(.right, bounds: bounds, gaps: gaps)
        world.resizeFocused(.right, pixels: 100, bounds: bounds)
        world.balanceVisible()
        world.setNextSplit(.vertical)
        XCTAssertNotEqual(world.visibleFrames(bounds: bounds, gaps: gaps), before)

        world.changeVisibleLayout(to: .niri, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.focus(.right, bounds: bounds, gaps: gaps)
        world.moveFocused(.left, bounds: bounds, gaps: gaps)
        world.resizeFocused(.right, pixels: 100, bounds: bounds)
        world.centerColumn(bounds: bounds, gaps: gaps)
        world.remove(token(2))
        XCTAssertNil(world.workspace(of: token(2)))
        XCTAssertEqual(Set(world.visible.windows), [token(1), token(3)])
    }

    func testNoOpCommandsAndFullscreenCleanupAreSafe() {
        var world = World(workspaceCount: 1)
        world.switchWorkspace(to: 99)
        world.focusNext(bounds: bounds, gaps: gaps)
        world.balanceVisible()
        world.consume(.left, bounds: bounds, gaps: gaps)
        world.expel(.right, bounds: bounds, gaps: gaps)
        world.centerColumn(bounds: bounds, gaps: gaps)
        world.setColumnWidth(0.5, bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visibleWorkspace, 1)

        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.setFullscreen(token(1), enabled: true)
        world.remove(token(1))
        XCTAssertNil(world.visible.fullscreen)
    }
}

private func token(_ id: CGWindowID) -> WindowToken { WindowToken(pid: 7, id: id) }
