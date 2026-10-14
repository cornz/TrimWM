import CoreGraphics
import XCTest
@testable import TrimWM

final class TabsLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 30, width: 1000, height: 600)

    func testInsertOpensTabsRightOfTheFocusedOneAndFocusesThem() {
        var layout = TabsLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.focus(token(1))
        layout.insert(token(3))
        layout.insert(token(3))

        XCTAssertEqual(layout.windows, [token(1), token(3), token(2)])
        XCTAssertEqual(layout.focused, token(3))
    }

    func testRemovingTheFocusedTabFocusesItsRightNeighborOrTheLastTab() {
        var layout = tabs(1, 2, 3)
        layout.focus(token(2))
        layout.remove(token(2))
        XCTAssertEqual(layout.focused, token(3))
        layout.remove(token(3))
        XCTAssertEqual(layout.focused, token(1))
        layout.remove(token(1))
        XCTAssertNil(layout.focused)
        XCTAssertTrue(layout.windows.isEmpty)
    }

    func testRemovingAnotherTabKeepsFocus() {
        var layout = tabs(1, 2, 3)
        layout.remove(token(1))
        XCTAssertEqual(layout.focused, token(3))
        XCTAssertEqual(layout.windows, [token(2), token(3)])
    }

    func testDirectionsStepThroughTabsWithoutWrapping() {
        var layout = tabs(1, 2, 3)
        layout.focus(.right)
        XCTAssertEqual(layout.focused, token(3))
        layout.focus(.left)
        XCTAssertEqual(layout.focused, token(2))
        layout.focus(.up)
        XCTAssertEqual(layout.focused, token(1))
        layout.focus(.up)
        XCTAssertEqual(layout.focused, token(1))
        layout.focus(.down)
        XCTAssertEqual(layout.focused, token(2))
    }

    func testMoveReordersTheFocusedTab() {
        var layout = tabs(1, 2, 3)
        layout.move(.left)
        XCTAssertEqual(layout.windows, [token(1), token(3), token(2)])
        layout.move(.up)
        XCTAssertEqual(layout.windows, [token(3), token(1), token(2)])
        layout.move(.left)
        XCTAssertEqual(layout.windows, [token(3), token(1), token(2)])
        XCTAssertEqual(layout.focused, token(3))
    }

    func testOnlyTheFocusedTabHasAFrame() {
        let layout = tabs(1, 2)
        XCTAssertEqual(
            layout.frames(in: bounds, gaps: LayoutGaps()),
            [token(2): CGRect(x: 0, y: 68, width: 1000, height: 562)]
        )
    }

    func testASingleTabHasNoBarAndTheWholeScreen() {
        let layout = tabs(1)
        XCTAssertNil(layout.barFrame(in: bounds, gaps: LayoutGaps()))
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: LayoutGaps()), bounds)
    }

    func testTopBarTakesItsHeightFromTheWindow() {
        let layout = tabs(1, 2)
        let gaps = LayoutGaps(inner: 6, outer: 10)
        XCTAssertEqual(layout.barFrame(in: bounds, gaps: gaps), CGRect(x: 10, y: 40, width: 980, height: 32))
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: gaps), CGRect(x: 10, y: 78, width: 980, height: 542))
    }

    func testLeftBarTakesItsWidthFromTheWindow() {
        var layout = tabs(1, 2)
        layout.bar.position = .left
        XCTAssertEqual(layout.barFrame(in: bounds, gaps: LayoutGaps()), CGRect(x: 0, y: 30, width: 44, height: 600))
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: LayoutGaps()), CGRect(x: 50, y: 30, width: 950, height: 600))
        layout.bar.size = 48
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: LayoutGaps()), CGRect(x: 54, y: 30, width: 946, height: 600))
    }

    func testBottomAndRightBarsTakeRoomFromTheirSide() {
        var layout = tabs(1, 2)
        let gaps = LayoutGaps(inner: 0, outer: 10)
        layout.bar.position = .bottom
        XCTAssertEqual(layout.bar.thickness, 32)
        XCTAssertEqual(layout.barFrame(in: bounds, gaps: gaps), CGRect(x: 10, y: 588, width: 980, height: 32))
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: gaps), CGRect(x: 10, y: 40, width: 980, height: 542))
        layout.bar.position = .right
        XCTAssertEqual(layout.bar.thickness, 44)
        XCTAssertEqual(layout.barFrame(in: bounds, gaps: gaps), CGRect(x: 946, y: 40, width: 44, height: 580))
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: gaps), CGRect(x: 10, y: 40, width: 930, height: 580))
    }

    func testAutohidingBarLeavesTheWholeScreenToTheWindow() {
        var layout = tabs(1, 2)
        layout.bar.autohide = true
        XCTAssertEqual(layout.barFrame(in: bounds, gaps: LayoutGaps()), CGRect(x: 0, y: 30, width: 1000, height: 32))
        XCTAssertEqual(layout.contentFrame(in: bounds, gaps: LayoutGaps()), bounds)
    }

    func testTopTabsShareTheWidthUpToAMaximum() {
        let size = CGSize(width: 1000, height: 32)
        let two = TabBarGeometry.tabFrames(count: 2, position: .top, size: size, thickness: 32)
        XCTAssertEqual(two.map(\.width), [220, 220])
        XCTAssertEqual(two.map(\.minX), [4, 226])
        let many = TabBarGeometry.tabFrames(count: 10, position: .top, size: size, thickness: 32)
        XCTAssertEqual(many.first?.width, 97)
        XCTAssertLessThanOrEqual(many.last!.maxX, 996)
        XCTAssertEqual(many.first?.minY, 4)
        XCTAssertEqual(many.first?.maxY, 28)
    }

    func testLeftTabsStackAsSquaresThatWidenWhenExpanded() {
        let collapsed = TabBarGeometry.tabFrames(count: 3, position: .left, size: CGSize(width: 44, height: 600), thickness: 44)
        XCTAssertEqual(collapsed.map(\.minY), [6, 44, 82])
        XCTAssertEqual(collapsed.first?.size, CGSize(width: 32, height: 32))
        let expanded = TabBarGeometry.tabFrames(count: 3, position: .left, size: CGSize(width: 240, height: 600), thickness: 44)
        XCTAssertEqual(expanded.map(\.minY), [6, 44, 82])
        XCTAssertEqual(expanded.first?.size, CGSize(width: 228, height: 32))
        XCTAssertEqual(TabBarGeometry.index(at: CGPoint(x: 100, y: 50), in: expanded), 1)
        XCTAssertNil(TabBarGeometry.index(at: CGPoint(x: 100, y: 200), in: expanded))
    }

    func testRailsExpandAwayFromTheirScreenEdge() {
        let left = CGRect(x: 0, y: 0, width: 44, height: 600)
        XCTAssertEqual(TabBarGeometry.expandedFrame(left, position: .left), CGRect(x: 0, y: 0, width: 240, height: 600))
        let right = CGRect(x: 956, y: 0, width: 44, height: 600)
        XCTAssertEqual(TabBarGeometry.expandedFrame(right, position: .right), CGRect(x: 760, y: 0, width: 240, height: 600))
        let top = CGRect(x: 0, y: 0, width: 1000, height: 32)
        XCTAssertEqual(TabBarGeometry.expandedFrame(top, position: .top), top)
        XCTAssertEqual(
            TabBarGeometry.tabFrames(count: 2, position: .right, size: CGSize(width: 44, height: 600), thickness: 44),
            TabBarGeometry.tabFrames(count: 2, position: .left, size: CGSize(width: 44, height: 600), thickness: 44)
        )
    }

    func testPointerAgainstTheScreenEdgeStaysOnTheBar() {
        let rail = CGRect(x: 0, y: 0, width: 240, height: 600)
        XCTAssertTrue(TabBarGeometry.contains(rail, pointer: CGPoint(x: 0, y: 300)))
        XCTAssertTrue(TabBarGeometry.contains(rail, pointer: CGPoint(x: -0.5, y: 300)))
        XCTAssertTrue(TabBarGeometry.contains(rail, pointer: CGPoint(x: 240, y: 600)))
        XCTAssertFalse(TabBarGeometry.contains(rail, pointer: CGPoint(x: 242, y: 300)))
        XCTAssertFalse(TabBarGeometry.contains(rail, pointer: CGPoint(x: 100, y: 602)))
    }

    func testBarCornersFollowTheWindowUpToACapsule() {
        XCTAssertEqual(TabBarGeometry.cornerRadius(windowRadius: 16, thickness: 32), 16)
        XCTAssertEqual(TabBarGeometry.cornerRadius(windowRadius: 26, thickness: 32), 16)
        XCTAssertEqual(TabBarGeometry.cornerRadius(windowRadius: 10, thickness: 44), 10)
        XCTAssertEqual(TabBarGeometry.cornerRadius(windowRadius: nil, thickness: 44), 16)
    }

    func testHiddenBarIsRevealedOnlyAtItsOuterEdge() {
        // AppKit coordinates: the top bar's outer edge is its maximum y.
        let top = CGRect(x: 0, y: 568, width: 1000, height: 32)
        XCTAssertTrue(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 500, y: 599), bar: top, position: .top))
        XCTAssertFalse(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 500, y: 590), bar: top, position: .top))
        XCTAssertFalse(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 1100, y: 599), bar: top, position: .top))
        let left = CGRect(x: 0, y: 0, width: 44, height: 600)
        XCTAssertTrue(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 1, y: 300), bar: left, position: .left))
        XCTAssertFalse(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 20, y: 300), bar: left, position: .left))
        let bottom = CGRect(x: 0, y: 0, width: 1000, height: 32)
        XCTAssertTrue(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 500, y: 0), bar: bottom, position: .bottom))
        XCTAssertFalse(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 500, y: 10), bar: bottom, position: .bottom))
        let right = CGRect(x: 956, y: 0, width: 44, height: 600)
        XCTAssertTrue(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 999, y: 300), bar: right, position: .right))
        XCTAssertFalse(TabBarGeometry.revealsHiddenBar(pointer: CGPoint(x: 970, y: 300), bar: right, position: .right))
    }

    func testStatusGlyphsFollowLayoutTabBarPositionAndFullscreen() {
        var world = World(workspaceCount: 4)
        let gaps = LayoutGaps()
        world.add(token(1), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(2), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.changeVisibleLayout(to: .tabs, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(3), to: 2, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.add(token(4), to: 4, bounds: bounds, gaps: gaps, splitRatio: 1)
        world.setFullscreen(token(4), enabled: true)

        XCTAssertEqual(world.statusText, "[1B] 2T 4TF")
        XCTAssertEqual(world.statusWorkspaces, [
            StatusWorkspace(number: 1, glyph: .tabsTop, isVisible: true),
            StatusWorkspace(number: 2, glyph: .autotile, isVisible: false),
            StatusWorkspace(number: 4, glyph: .fullscreen, isVisible: false),
        ])

        world.setTabBar(TabBarSettings(position: .bottom))
        XCTAssertEqual(world.statusWorkspaces.first?.glyph, .tabsBottom)
        world.setTabBar(TabBarSettings(position: .right))
        XCTAssertEqual(world.statusWorkspaces.first?.glyph, .tabsRight)
        world.setTabBar(TabBarSettings(position: .left))
        XCTAssertEqual(world.statusWorkspaces.first?.glyph, .tabsLeft)
        guard case let .tabs(layout) = world.visible.layout else { return XCTFail("expected tabs") }
        XCTAssertEqual(layout.bar.position, .left)
    }

    func testFocusBorderOnlyMarksAWindowAmongSeveral() {
        let gaps = LayoutGaps()
        var workspace = WorkspaceState()
        XCTAssertFalse(workspace.showsFocusBorder(singleWindow: true))
        workspace.add(token(1), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertTrue(workspace.showsFocusBorder(singleWindow: true))
        XCTAssertFalse(workspace.showsFocusBorder(singleWindow: false))
        workspace.add(token(2), floating: nil, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertTrue(workspace.showsFocusBorder(singleWindow: false))

        workspace.fullscreen = token(2)
        XCTAssertFalse(workspace.showsFocusBorder(singleWindow: true))
        workspace.fullscreen = nil

        workspace.changeLayout(to: .tabs, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertFalse(workspace.showsFocusBorder(singleWindow: true))
        workspace.add(token(3), floating: CGRect(x: 100, y: 100, width: 300, height: 200), bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertTrue(workspace.showsFocusBorder(singleWindow: false))
    }

    func testConvertingToTabsKeepsOrderAndFocusAndBack() {
        var world = World()
        let gaps = LayoutGaps()
        world.setTabBar(TabBarSettings(position: .left, size: 40, autohide: true))
        for id: CGWindowID in 1...3 { world.add(token(id), to: 1, bounds: bounds, gaps: gaps, splitRatio: 1) }
        world.focus(token(2), bounds: bounds, gaps: gaps)

        world.changeVisibleLayout(to: .tabs, bounds: bounds, gaps: gaps, splitRatio: 1)
        guard case let .tabs(layout) = world.visible.layout else { return XCTFail("expected tabs") }
        XCTAssertEqual(layout.windows, [token(1), token(2), token(3)])
        XCTAssertEqual(layout.focused, token(2))
        XCTAssertEqual(layout.bar, TabBarSettings(position: .left, size: 40, autohide: true))
        XCTAssertEqual(Array(world.visibleFrames(bounds: bounds, gaps: gaps).keys), [token(2)])

        world.focus(.right, bounds: bounds, gaps: gaps)
        XCTAssertEqual(world.visible.focused, token(3))
        world.resizeFocused(.right, pixels: 50, bounds: bounds)
        XCTAssertEqual(world.visible.layout.mode, .tabs)

        world.changeVisibleLayout(to: .autotile, bounds: bounds, gaps: gaps, splitRatio: 1)
        XCTAssertEqual(world.visible.layout.windows, [token(1), token(2), token(3)])
        XCTAssertEqual(world.visibleFrames(bounds: bounds, gaps: gaps).count, 3)
    }

    private func tabs(_ ids: CGWindowID...) -> TabsLayout {
        var layout = TabsLayout()
        for id in ids { layout.insert(token(id)) }
        return layout
    }
}

private func token(_ id: CGWindowID) -> WindowToken { WindowToken(pid: 7, id: id) }
