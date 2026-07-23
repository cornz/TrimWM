import CoreGraphics
import XCTest
@testable import cornzWM

final class BSPLayoutTests: XCTestCase {
    private let wide = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let tall = CGRect(x: 0, y: 0, width: 400, height: 900)
    private let gaps = LayoutGaps()

    func testFirstWindowFillsBounds() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: gaps, splitRatio: 1.1)
        XCTAssertEqual(layout.frames(in: wide, gaps: gaps)[token(1)], wide)
    }

    func testAutotilingSplitsWideRegionLeftRight() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.insert(token(2), in: wide, gaps: gaps, splitRatio: 1.1)

        XCTAssertEqual(layout.frames(in: wide, gaps: gaps)[token(1)], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(layout.frames(in: wide, gaps: gaps)[token(2)], CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    func testAutotilingSplitsTallRegionTopBottom() {
        var layout = BSPLayout()
        layout.insert(token(1), in: tall, gaps: gaps, splitRatio: 1.1)
        layout.insert(token(2), in: tall, gaps: gaps, splitRatio: 1.1)

        XCTAssertEqual(layout.frames(in: tall, gaps: gaps)[token(1)], CGRect(x: 0, y: 0, width: 400, height: 450))
        XCTAssertEqual(layout.frames(in: tall, gaps: gaps)[token(2)], CGRect(x: 0, y: 450, width: 400, height: 450))
    }

    func testManualSplitOverridesExactlyOneInsertion() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.nextSplit = .vertical
        layout.insert(token(2), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.insert(token(3), in: wide, gaps: gaps, splitRatio: 1.1)

        guard case let .split(axis, _, _, second)? = layout.root else { return XCTFail("missing root") }
        XCTAssertEqual(axis, .vertical)
        guard case let .split(secondAxis, _, _, _) = second else { return XCTFail("missing automatic split") }
        XCTAssertEqual(secondAxis, .horizontal)
        XCTAssertNil(layout.nextSplit)
    }

    func testRemovingWindowCollapsesSingleChildContainer() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.insert(token(2), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.remove(token(2))
        XCTAssertEqual(layout.root, .leaf(token(1)))
        XCTAssertEqual(layout.focused, token(1))
    }

    func testResizePersistsAndBalanceResetsRatio() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.insert(token(2), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.focus(token(1))
        layout.resize(axis: .horizontal, delta: 0.1)
        XCTAssertEqual(layout.frames(in: wide, gaps: gaps)[token(1)]?.width, 600)
        layout.balance()
        XCTAssertEqual(layout.frames(in: wide, gaps: gaps)[token(1)]?.width, 500)
    }

    func testDirectionalFocusAndMoveUseVisibleGeometry() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.insert(token(2), in: wide, gaps: gaps, splitRatio: 1.1)
        layout.focus(token(1))
        layout.focus(.right, in: wide, gaps: gaps)
        XCTAssertEqual(layout.focused, token(2))

        layout.move(.left, in: wide, gaps: gaps)
        XCTAssertEqual(layout.frames(in: wide, gaps: gaps)[token(2)]?.minX, 0)
    }

    func testInnerAndOuterGapsAreAppliedOnce() {
        var layout = BSPLayout()
        layout.insert(token(1), in: wide, gaps: .init(inner: 10, outer: 20), splitRatio: 1.1)
        layout.insert(token(2), in: wide, gaps: .init(inner: 10, outer: 20), splitRatio: 1.1)
        let frames = layout.frames(in: wide, gaps: .init(inner: 10, outer: 20))
        XCTAssertEqual(frames[token(1)], CGRect(x: 20, y: 20, width: 475, height: 560))
        XCTAssertEqual(frames[token(2)], CGRect(x: 505, y: 20, width: 475, height: 560))
    }

    func testMinimumSizesClampNestedSplitWithoutOverlap() {
        let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var layout = BSPLayout()
        layout.insert(token(1), in: square, gaps: gaps, splitRatio: 1)
        layout.insert(token(2), in: square, gaps: gaps, splitRatio: 1)
        layout.insert(token(3), in: square, gaps: gaps, splitRatio: 1)

        let frames = layout.frames(
            in: square,
            gaps: gaps,
            minimumSizes: [
                token(2): CGSize(width: 1, height: 100),
                token(3): CGSize(width: 1, height: 600),
            ]
        )
        XCTAssertEqual(frames[token(1)], CGRect(x: 0, y: 0, width: 500, height: 1000))
        XCTAssertEqual(frames[token(2)], CGRect(x: 500, y: 0, width: 500, height: 400))
        XCTAssertEqual(frames[token(3)], CGRect(x: 500, y: 400, width: 500, height: 600))
        XCTAssertEqual(frames[token(2)]?.maxY, frames[token(3)]?.minY)
    }

    func testImpossibleMinimumsNeverProduceFramesOutsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        var layout = BSPLayout()
        layout.insert(token(1), in: bounds, gaps: gaps, splitRatio: 1)
        layout.insert(token(2), in: bounds, gaps: gaps, splitRatio: 1)
        let frames = layout.frames(
            in: bounds,
            gaps: gaps,
            minimumSizes: [
                token(1): CGSize(width: 1, height: 400),
                token(2): CGSize(width: 1, height: 300),
            ]
        )

        XCTAssertEqual(frames[token(1)], CGRect(x: 0, y: 0, width: 400, height: 250))
        XCTAssertEqual(frames[token(2)], CGRect(x: 0, y: 250, width: 400, height: 250))
        XCTAssertEqual(frames[token(1)]?.maxY, frames[token(2)]?.minY)
        XCTAssertEqual(frames.values.reduce(CGRect.null) { $0.union($1) }, bounds)
    }

    func testReflowsOnlyAnImpossibleConstrainedTreeIntoNonOverlappingColumns() {
        let windows = (1...5).map { token(CGWindowID($0)) }
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 972)
        let minimums = [
            windows[0]: CGSize(width: 1, height: 1),
            windows[1]: CGSize(width: 574, height: 1),
            windows[2]: CGSize(width: 740, height: 486),
            windows[3]: CGSize(width: 600, height: 400),
            windows[4]: CGSize(width: 715, height: 252),
        ]
        var layout = BSPLayout()
        for window in windows {
            layout.nextSplit = .vertical
            layout.insert(window, in: bounds, gaps: gaps, splitRatio: 1)
        }

        XCTAssertTrue(layout.reflowToFit(in: bounds, gaps: gaps, minimumSizes: minimums))
        let frames = layout.frames(in: bounds, gaps: gaps, minimumSizes: minimums)
        for window in windows {
            XCTAssertGreaterThanOrEqual(frames[window]!.width + 4, minimums[window]!.width)
            XCTAssertGreaterThanOrEqual(frames[window]!.height + 4, minimums[window]!.height)
        }
        for first in windows.indices {
            for second in windows.indices where second > first {
                let intersection = frames[windows[first]]!.intersection(frames[windows[second]]!)
                XCTAssertTrue(intersection.isNull || intersection.width == 0 || intersection.height == 0)
            }
        }
    }
}

private func token(_ id: CGWindowID) -> WindowToken { WindowToken(pid: 42, id: id) }
