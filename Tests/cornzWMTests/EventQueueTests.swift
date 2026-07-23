import XCTest
@testable import cornzWM

final class EventQueueTests: XCTestCase {
    private let a = WindowToken(pid: 1, id: 1)
    private let b = WindowToken(pid: 2, id: 2)

    func testCoalescesWindowUpdatesPerProcessAndMouseMoves() {
        var buffer = EventBuffer()
        buffer.insert(.windows(7, []))
        buffer.insert(.mouse(a))
        buffer.insert(.windows(7, []))
        buffer.insert(.mouse(b))
        let events = buffer.takeAll()
        XCTAssertEqual(events.count, 2)
        guard case let .windows(pid, _) = events[0], case let .mouse(window) = events[1] else {
            return XCTFail("unexpected event order")
        }
        XCTAssertEqual(pid, 7)
        XCTAssertEqual(window, b)
    }

    func testCommandsAreNeverCoalesced() {
        var buffer = EventBuffer()
        buffer.insert(.command(.workspace(1)))
        buffer.insert(.command(.workspace(2)))
        XCTAssertEqual(buffer.takeAll().count, 2)
        XCTAssertTrue(buffer.events.isEmpty)
    }

    func testCoalescesConsecutiveMouseResizeSteps() {
        var buffer = EventBuffer()
        buffer.insert(.mouseResize(a, .right, 4))
        buffer.insert(.mouseResize(a, .right, 6))
        buffer.insert(.mouseResize(a, .down, 3))
        let events = buffer.takeAll()
        XCTAssertEqual(events.count, 2)
        guard case let .mouseResize(window, direction, pixels) = events[0] else {
            return XCTFail("unexpected event")
        }
        XCTAssertEqual(window, a)
        XCTAssertEqual(direction, .right)
        XCTAssertEqual(pixels, 10)
    }

    func testFrameWriteResultsAreNeverCoalesced() {
        var buffer = EventBuffer()
        let frame = CGRect(x: 1, y: 2, width: 3, height: 4)
        buffer.insert(.frameWriteResult(a, frame, AXFrameWriteResult(observed: nil, succeeded: false)))
        buffer.insert(.frameWriteResult(a, frame, AXFrameWriteResult(observed: frame, succeeded: true)))
        XCTAssertEqual(buffer.takeAll().count, 2)
    }

    func testCoalescesObservedFramesPerWindow() {
        var buffer = EventBuffer()
        let first = CGRect(x: 1, y: 2, width: 3, height: 4)
        let latest = CGRect(x: 5, y: 6, width: 7, height: 8)
        buffer.insert(.frameObserved(a, first))
        buffer.insert(.frameObserved(b, first))
        buffer.insert(.frameObserved(a, latest))
        let events = buffer.takeAll()
        XCTAssertEqual(events.count, 2)
        guard case let .frameObserved(window, frame) = events[0] else {
            return XCTFail("unexpected event")
        }
        XCTAssertEqual(window, a)
        XCTAssertEqual(frame, latest)
    }

    @MainActor
    func testQueueSchedulesOneMainActorDrainForBurst() async {
        let queue = EventQueue()
        let drained = expectation(description: "drained")
        queue.onDrain = { events in
            XCTAssertEqual(events.count, 2)
            guard case let .windows(pid, _) = events[0], case let .command(command) = events[1] else {
                return XCTFail("unexpected events")
            }
            XCTAssertEqual(pid, 7)
            XCTAssertEqual(command, .workspace(2))
            drained.fulfill()
        }
        queue.push(.windows(7, []))
        queue.push(.windows(7, []))
        queue.push(.command(.workspace(2)))
        await fulfillment(of: [drained], timeout: 1)
    }
}
