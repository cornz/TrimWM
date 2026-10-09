import XCTest
import CoreGraphics
@testable import TrimWM

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

    func testReadsWindowIDFromFrameEventPayload() {
        var payload: [UInt8] = [0, 0x2A, 0x01, 0, 0, 0xFF]
        payload.withUnsafeBytes { bytes in
            let unaligned = bytes.baseAddress!.advanced(by: 1)
            XCTAssertEqual(SkyLightEvent.windowID(unaligned, length: 4), 0x12A)
            XCTAssertNil(SkyLightEvent.windowID(unaligned, length: 3))
            XCTAssertNil(SkyLightEvent.windowID(bytes.baseAddress!, length: 0))
        }
        payload = [0, 0, 0, 0]
        payload.withUnsafeBytes { XCTAssertNil(SkyLightEvent.windowID($0.baseAddress!, length: 4)) }
        XCTAssertNil(SkyLightEvent.windowID(nil, length: 4))
    }

    func testUnavailableSkyLightWindowEventsAndBordersFailSafely() {
        let skyLight = SkyLight(path: "/missing/SkyLight")
        XCTAssertFalse(skyLight.capabilities.windowEvents)
        XCTAssertFalse(skyLight.startWindowEvents { _, _ in })
        XCTAssertNil(skyLight.bounds(1))
        XCTAssertNil(skyLight.cornerRadius(1))
        skyLight.watchWindows([1])
        skyLight.stopWindowEvents()
        XCTAssertNil(SkyLightBorder(path: "/missing/SkyLight"))
    }

    func testBorderRingHugsTheWindowAndClampsRadii() {
        let ring = BorderRing(
            size: CGSize(width: 100, height: 40), width: 4, innerRadius: 16, outerRadius: 30,
            red: 0, green: 0, blue: 1, alpha: 1
        )
        XCTAssertEqual(ring.outerSize, CGSize(width: 108, height: 48))
        let path = ring.path()
        XCTAssertEqual(path.boundingBoxOfPath.width, 108, accuracy: 0.001)
        XCTAssertEqual(path.boundingBoxOfPath.height, 48, accuracy: 0.001)
        XCTAssertTrue(path.contains(CGPoint(x: 54, y: 2), using: .evenOdd))
        XCTAssertFalse(path.contains(CGPoint(x: 54, y: 24), using: .evenOdd))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1), using: .evenOdd))
        XCTAssertFalse(path.contains(CGPoint(x: 54, y: 4.5), using: .evenOdd))

        var covering = ring
        covering.overlap = 1
        let coveringPath = covering.path()
        XCTAssertTrue(coveringPath.contains(CGPoint(x: 54, y: 4.5), using: .evenOdd))
        XCTAssertFalse(coveringPath.contains(CGPoint(x: 54, y: 5.5), using: .evenOdd))
        XCTAssertEqual(covering.outerSize, ring.outerSize)
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
