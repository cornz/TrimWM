import XCTest
import CoreGraphics
@testable import cornzWM

final class SkyLightTests: XCTestCase {
    func testParsesMainDisplayCurrentSpace() {
        let fixture: [[String: Any]] = [
            ["Display Identifier": "secondary", "Current Space": ["id64": NSNumber(value: 8)]],
            ["Display Identifier": "Main", "Current Space": ["id64": NSNumber(value: 42)]],
        ]
        XCTAssertEqual(ManagedSpaceParser.mainSpaceID(in: fixture), 42)
    }

    func testFallsBackToFirstDisplayAndManagedSpaceID() {
        let fixture: [[String: Any]] = [["Current Space": ["ManagedSpaceID": "17"]]]
        XCTAssertEqual(ManagedSpaceParser.mainSpaceID(in: fixture), 17)
    }

    func testParsesWindowSpaceIDs() {
        XCTAssertEqual(ManagedSpaceParser.spaceIDs(in: [NSNumber(value: 2), "5", "bad"]), [2, 5])
    }

    func testUnavailableSkyLightMoveFailsSafely() {
        let skyLight = SkyLight(path: "/missing/SkyLight")
        XCTAssertFalse(skyLight.move(1, to: CGPoint(x: -10_000, y: 0)))
    }

    func testLiveSpaceSymbolsReturnReadableTopologyWhenAvailable() {
        let skyLight = SkyLight()
        guard skyLight.capabilities.spaces else { return }
        XCTAssertNotNil(skyLight.currentMainSpaceID())
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let normalWindowIDs = info?.compactMap { item -> CGWindowID? in
            guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        } ?? []
        if !normalWindowIDs.isEmpty {
            XCTAssertTrue(normalWindowIDs.contains { !(skyLight.windowSpaceIDs($0)?.isEmpty ?? true) })
        }
    }
}
