import CoreGraphics
import XCTest
@testable import TrimWM

final class GeometryTests: XCTestCase {
    func testAutomaticBorderCornersStayAlignedForFocusAndThickerDragBorders() {
        for width: CGFloat in [0, 2, 4, 6] {
            let radius = FocusBorderGeometry.cornerRadius(
                configured: nil, strokeWidth: width, macOSMajorVersion: 27
            )
            XCTAssertEqual(radius - width, 16)
        }
    }

    func testBorderCornersPreserveLegacyAppearanceAndExplicitOverrides() {
        XCTAssertEqual(FocusBorderGeometry.cornerRadius(configured: nil, strokeWidth: 2, macOSMajorVersion: 26), 9)
        for version in [26, 27] {
            for radius: CGFloat in [0, 9, 12] {
                XCTAssertEqual(
                    FocusBorderGeometry.cornerRadius(configured: radius, strokeWidth: 4, macOSMajorVersion: version),
                    radius
                )
            }
        }
    }

    func testRingFollowsTheWindowsOwnCornersUnlessARadiusIsConfigured() {
        let measured = FocusBorderGeometry.ringRadii(configured: nil, windowRadius: 26, strokeWidth: 2, macOSMajorVersion: 27)
        XCTAssertEqual(measured.inner, 26)
        XCTAssertEqual(measured.outer, 28)
        let square = FocusBorderGeometry.ringRadii(configured: nil, windowRadius: 0, strokeWidth: 2, macOSMajorVersion: 27)
        XCTAssertEqual(square.inner, 0)
        XCTAssertEqual(square.outer, 2)
        let unknown = FocusBorderGeometry.ringRadii(configured: nil, windowRadius: nil, strokeWidth: 2, macOSMajorVersion: 27)
        XCTAssertEqual(unknown.inner, 16)
        XCTAssertEqual(unknown.outer, 18)
        let legacy = FocusBorderGeometry.ringRadii(configured: nil, windowRadius: nil, strokeWidth: 2, macOSMajorVersion: 26)
        XCTAssertEqual(legacy.inner, 7)
        XCTAssertEqual(legacy.outer, 9)
        let configured = FocusBorderGeometry.ringRadii(configured: 12, windowRadius: 26, strokeWidth: 4, macOSMajorVersion: 27)
        XCTAssertEqual(configured.inner, 8)
        XCTAssertEqual(configured.outer, 12)
        let squareConfigured = FocusBorderGeometry.ringRadii(configured: 0, windowRadius: 26, strokeWidth: 4, macOSMajorVersion: 27)
        XCTAssertEqual(squareConfigured.inner, 0)
        XCTAssertEqual(squareConfigured.outer, 0)
    }

    func testBorderScreenPointFlipsAroundThePrimaryScreen() {
        XCTAssertEqual(
            FocusBorderGeometry.screenPoint(
                of: CGRect(x: 100, y: 40, width: 200, height: 100),
                primaryScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            CGPoint(x: 200, y: 990)
        )
    }

    func testFocusBorderConvertsTopLeftWindowCoordinatesToAppKit() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: -2, y: 28, width: 964, height: 970)
        XCTAssertEqual(
            FocusBorderGeometry.appKitFrame(window, screenFrame: screen),
            CGRect(x: -2, y: 82, width: 964, height: 970)
        )
    }

    func testDragBorderRemainsVisibleAndScalesConfiguredWidth() {
        XCTAssertEqual(FocusBorderGeometry.strokeWidth(configured: 0, scale: 2, minimum: 4), 4)
        XCTAssertEqual(FocusBorderGeometry.strokeWidth(configured: 3, scale: 2, minimum: 4), 6)
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

    func testSideHidingFallsBackToMainDisplayWhenInventoryIsEmpty() {
        let bounds = CGRect(x: 100, y: 20, width: 1000, height: 700)
        let window = CGRect(x: 300, y: 40, width: 500, height: 400)
        let hidden = Geometry.sideHiddenFrame(
            window,
            mainBounds: bounds,
            displayBounds: []
        )
        XCTAssertEqual(hidden.maxX, bounds.minX + 1)
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
