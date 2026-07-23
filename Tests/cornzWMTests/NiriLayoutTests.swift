import CoreGraphics
import XCTest
@testable import cornzWM

final class NiriLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let gaps = LayoutGaps()

    func testNewWindowsCreateColumnsWithoutShrinkingExistingColumns() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        let frames = layout.frames(in: bounds, gaps: gaps)
        XCTAssertEqual(frames[token(1)]?.width, 500)
        XCTAssertEqual(frames[token(2)]?.width, 500)
        XCTAssertEqual(frames[token(2)]?.minX, 500)
    }

    func testConsumeStacksAndExpelCreatesNewColumn() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.consume(.left)
        XCTAssertEqual(layout.columns.map(\.windows), [[token(1), token(2)]])
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(2)]?.height, 300)

        layout.expel(.right)
        XCTAssertEqual(layout.columns.map(\.windows), [[token(1)], [token(2)]])
    }

    func testExpelLeftAfterConsumeProducesAdjacentNonOverlappingColumns() {
        var layout = NiriLayout()
        for id in 1...4 { layout.insert(token(CGWindowID(id))) }
        layout.focus(token(4))
        layout.move(.left)
        layout.consume(.left)
        layout.expel(.left)
        layout.revealFocused(in: bounds, gaps: gaps)

        let frames = layout.frames(in: bounds, gaps: gaps)
        let focused = frames[token(4)]!
        let neighbour = frames[token(2)]!
        XCTAssertEqual(focused.maxX, neighbour.minX)
        XCTAssertFalse(focused.intersects(neighbour))
    }

    func testVerticalFocusAndMoveRemainInsideColumn() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.consume(.left)
        layout.focus(.up)
        XCTAssertEqual(layout.focused, token(1))
        layout.move(.down)
        XCTAssertEqual(layout.columns[0].windows, [token(2), token(1)])
    }

    func testHorizontalMoveMovesSingleColumnAndExpelsStackedWindow() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.move(.left)
        XCTAssertEqual(layout.columns.map(\.windows), [[token(2)], [token(1)]])

        layout.consume(.right)
        layout.move(.left)
        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.columns[0].windows, [token(2)])
    }

    func testPresetAndPixelWidthsAreClamped() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.setFocusedWidth(0.75)
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(1)]?.width, 750)
        layout.resizeFocused(by: 1000, viewportWidth: 1000)
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(1)]?.width, 1000)
        layout.resizeFocused(by: -5000, viewportWidth: 1000)
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(1)]?.width, 100)
    }

    func testVerticalPixelResizeMovesSharedStackBoundary() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.consume(.left)

        layout.resizeFocusedVertically(.up, by: -60, viewportHeight: 600)
        var frames = layout.frames(in: bounds, gaps: gaps)
        XCTAssertEqual(frames[token(1)]?.height, 360)
        XCTAssertEqual(frames[token(2)]?.height, 240)
        XCTAssertEqual(frames[token(1)]?.maxY, frames[token(2)]?.minY)

        layout.resizeFocusedVertically(.up, by: 60, viewportHeight: 600)
        frames = layout.frames(in: bounds, gaps: gaps)
        XCTAssertEqual(frames[token(1)]?.height, 300)
        XCTAssertEqual(frames[token(2)]?.height, 300)
    }

    func testRevealAndCenterUpdateViewportWithoutChangingColumnWidths() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.insert(token(3))
        layout.revealFocused(in: bounds, gaps: gaps)
        XCTAssertEqual(layout.viewportOffset, 500)
        layout.centerFocused(in: bounds, gaps: gaps)
        XCTAssertEqual(layout.viewportOffset, 750)
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(3)]?.width, 500)
    }

    func testCenterPlacesFirstAndLastColumnsInViewportCenter() {
        var layout = NiriLayout()
        for id in 1...3 { layout.insert(token(CGWindowID(id))) }

        layout.focus(token(1))
        layout.centerFocused(in: bounds, gaps: gaps)
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(1)]?.midX, bounds.midX)

        layout.focus(token(3))
        layout.centerFocused(in: bounds, gaps: gaps)
        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(3)]?.midX, bounds.midX)
    }

    func testCenterKeepsOversizedColumnCentered() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.centerFocused(
            in: bounds,
            gaps: gaps,
            minimumSizes: [token(1): CGSize(width: 1200, height: 1)]
        )

        let frame = layout.frames(
            in: bounds,
            gaps: gaps,
            minimumSizes: [token(1): CGSize(width: 1200, height: 1)]
        )[token(1)]
        XCTAssertEqual(frame?.width, 1200)
        XCTAssertEqual(frame?.midX, bounds.midX)
    }

    func testBoundaryNoOpsDoNotCancelExplicitCentering() {
        var layout = NiriLayout()
        for id in 1...3 { layout.insert(token(CGWindowID(id))) }
        layout.focus(token(1))
        layout.centerFocused(in: bounds, gaps: gaps)

        layout.focus(.left)
        layout.move(.left)
        layout.consume(.left)
        layout.expel(.left)
        layout.setFocusedWidth(0.5)
        layout.resizeFocused(by: 0, viewportWidth: bounds.width)

        XCTAssertEqual(layout.frames(in: bounds, gaps: gaps)[token(1)]?.midX, bounds.midX)
    }

    func testOddViewportAndThreeRowStackQuantizeSharedEdgesWithoutOverlap() {
        let oddBounds = CGRect(x: 0, y: 0, width: 1001, height: 1001)
        let oddGaps = LayoutGaps(inner: 3, outer: 0)
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.consume(.left)
        layout.insert(token(3))
        layout.consume(.left)
        layout.insert(token(4))
        layout.focus(token(1))
        layout.centerFocused(in: oddBounds, gaps: oddGaps)

        let frames = layout.frames(in: oddBounds, gaps: oddGaps)
        XCTAssertEqual(frames[token(1)]!.maxY + oddGaps.inner, frames[token(2)]!.minY)
        XCTAssertEqual(frames[token(2)]!.maxY + oddGaps.inner, frames[token(3)]!.minY)
        XCTAssertEqual(frames[token(3)]!.maxY, oddBounds.maxY)
        XCTAssertEqual(frames[token(1)]!.maxX + oddGaps.inner, frames[token(4)]!.minX)
        XCTAssertFalse(frames[token(1)]!.intersects(frames[token(2)]!))
        XCTAssertFalse(frames[token(1)]!.intersects(frames[token(4)]!))
    }

    func testRemovingLastWindowClearsViewport() {
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.centerFocused(in: bounds, gaps: gaps)
        layout.remove(token(1))
        XCTAssertTrue(layout.columns.isEmpty)
        XCTAssertNil(layout.focused)
        XCTAssertEqual(layout.viewportOffset, 0)
    }

    func testRemovingColumnsClampsEffectiveViewportToRemainingContent() {
        var layout = NiriLayout()
        for id in 1...4 { layout.insert(token(CGWindowID(id))) }
        layout.centerFocused(in: bounds, gaps: gaps)
        layout.remove(token(4))
        layout.remove(token(3))
        let frames = layout.frames(in: bounds, gaps: gaps)
        XCTAssertTrue(frames[token(1)]!.intersects(bounds))
        XCTAssertTrue(frames[token(2)]!.intersects(bounds))
    }

    func testMinimumSizesDistributeStackAndExpandColumnWithoutOverlap() {
        let tallBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.consume(.left)
        let frames = layout.frames(
            in: tallBounds,
            gaps: gaps,
            minimumSizes: [
                token(1): CGSize(width: 1, height: 100),
                token(2): CGSize(width: 1200, height: 600),
            ]
        )
        XCTAssertEqual(frames[token(1)], CGRect(x: -200, y: 0, width: 1200, height: 400))
        XCTAssertEqual(frames[token(2)], CGRect(x: -200, y: 400, width: 1200, height: 600))
        XCTAssertEqual(frames[token(1)]?.maxY, frames[token(2)]?.minY)
        XCTAssertEqual(frames[token(2)]?.maxX, tallBounds.maxX)
    }

    func testImpossibleStackMinimumsOverflowWithoutOverlapping() {
        let shortBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        var layout = NiriLayout()
        layout.insert(token(1))
        layout.insert(token(2))
        layout.consume(.left)
        let frames = layout.frames(
            in: shortBounds,
            gaps: gaps,
            minimumSizes: [
                token(1): CGSize(width: 1, height: 400),
                token(2): CGSize(width: 1, height: 300),
            ]
        )

        XCTAssertEqual(frames[token(1)]?.height, 400)
        XCTAssertEqual(frames[token(2)]?.height, 300)
        XCTAssertEqual(frames[token(1)]?.maxY, frames[token(2)]?.minY)
    }
}

private func token(_ id: CGWindowID) -> WindowToken { WindowToken(pid: 42, id: id) }
