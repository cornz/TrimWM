import CoreGraphics
import XCTest
@testable import TrimWM

final class GeometryTests: XCTestCase {
    func testFocusBorderConvertsTopLeftWindowCoordinatesToAppKit() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: -2, y: 28, width: 964, height: 970)
        XCTAssertEqual(
            FocusBorderGeometry.appKitFrame(window, screenFrame: screen),
            CGRect(x: -2, y: 82, width: 964, height: 970)
        )
    }

    func testNearestRequiresCorrectHalfPlaneAndPrefersAlignedWindow() {
        let source = WindowToken(pid: 1, id: 1)
        let aligned = WindowToken(pid: 1, id: 2)
        let diagonal = WindowToken(pid: 1, id: 3)
        let wrongSide = WindowToken(pid: 1, id: 4)
        let frames = [
            source: CGRect(x: 500, y: 500, width: 100, height: 100),
            aligned: CGRect(x: 700, y: 500, width: 100, height: 100),
            diagonal: CGRect(x: 620, y: 800, width: 100, height: 100),
            wrongSide: CGRect(x: 300, y: 500, width: 100, height: 100),
        ]
        XCTAssertEqual(Geometry.nearest(from: source, direction: .right, frames: frames), aligned)
        XCTAssertEqual(Geometry.nearest(from: source, direction: .left, frames: frames), wrongSide)
    }

    func testSideHidingUsesGlobalLeftEdgeWithOnePointReveal() {
        let window = CGRect(x: 100, y: 100, width: 900, height: 700)
        let macBook = CGRect(x: 0, y: 31, width: 2560, height: 1409)
        let hiddenBook = Geometry.sideHiddenFrame(window, mainBounds: macBook, displayBounds: [macBook])
        XCTAssertEqual(hiddenBook.maxX, macBook.minX + 1)

        let main = CGRect(x: 0, y: 25, width: 1920, height: 1055)
        let left = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let hiddenMini = Geometry.sideHiddenFrame(window, mainBounds: main, displayBounds: [main, left])
        XCTAssertEqual(hiddenMini.maxX, left.minX + 1)
        XCTAssertFalse(Geometry.isMeaningfullyVisible(hiddenMini, in: main))
        XCTAssertFalse(Geometry.isMeaningfullyVisible(hiddenMini, in: left))
    }

    func testMeaningfulVisibilityIgnoresParkingEpsilonButKeepsPartialColumns() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertFalse(Geometry.isMeaningfullyVisible(CGRect(x: -499, y: 0, width: 500, height: 700), in: bounds))
        XCTAssertTrue(Geometry.isMeaningfullyVisible(CGRect(x: -498, y: 0, width: 500, height: 700), in: bounds))
    }

    func testJournalClearsOnlyAfterAnIntendedVisibleRestore() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 500, height: 700)
        let parked = CGRect(x: -499, y: 0, width: 500, height: 700)
        XCTAssertFalse(Geometry.shouldClearJournal(observed: visible, desired: parked, bounds: bounds))
        XCTAssertFalse(Geometry.shouldClearJournal(observed: parked, desired: visible, bounds: bounds))
        XCTAssertFalse(Geometry.shouldClearJournal(observed: visible, desired: nil, bounds: bounds))
        XCTAssertTrue(Geometry.shouldClearJournal(observed: visible, desired: visible, bounds: bounds))
    }

    func testRestoredUnmanagedJournalWindowRequestsReconciliation() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let visible = CGRect(x: 0, y: 0, width: 500, height: 700)
        XCTAssertTrue(Geometry.shouldReconcileRestoredWindow(
            isManaged: false,
            hasJournalEntry: true,
            observed: visible,
            bounds: bounds
        ))
        XCTAssertFalse(Geometry.shouldReconcileRestoredWindow(
            isManaged: true,
            hasJournalEntry: true,
            observed: visible,
            bounds: bounds
        ))
    }
}
