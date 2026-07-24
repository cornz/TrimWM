import Carbon
import XCTest
@testable import TrimWM

final class InputTests: XCTestCase {
    func testPlansUserChords() throws {
        let plan = try HotKeyPlanner.plan(Binding(chord: "alt+Shift+;", command: .focus(.right)))
        XCTAssertEqual(plan.keyCode, UInt32(kVK_ANSI_Semicolon))
        XCTAssertEqual(plan.modifiers, UInt32(optionKey | shiftKey))
        XCTAssertEqual(plan.command, .focus(.right))
    }

    func testNormalizesReturnAndControlAliases() throws {
        let plan = try HotKeyPlanner.plan(Binding(chord: "ctrl+enter", command: .nop))
        XCTAssertEqual(plan.keyCode, UInt32(kVK_Return))
        XCTAssertEqual(plan.modifiers, UInt32(controlKey))
    }

    func testPlansConsumeAndExpelPunctuationHotkeys() throws {
        let bindings = [
            Binding(chord: "alt+comma", command: .consume(.left)),
            Binding(chord: "alt+period", command: .consume(.right)),
            Binding(chord: "alt+Shift+comma", command: .expel(.left)),
            Binding(chord: "alt+Shift+period", command: .expel(.right)),
        ]
        let plans = try bindings.map(HotKeyPlanner.plan)
        XCTAssertEqual(plans.map(\.keyCode), [
            UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_Period),
            UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_Period),
        ])
        XCTAssertEqual(plans.map(\.modifiers), [
            UInt32(optionKey), UInt32(optionKey),
            UInt32(optionKey | shiftKey), UInt32(optionKey | shiftKey),
        ])
        XCTAssertEqual(plans.map(\.command), bindings.map(\.command))
    }

    func testRejectsUnsupportedModifierAndKey() {
        XCTAssertThrowsError(try HotKeyPlanner.plan(Binding(chord: "hyper+j", command: .nop)))
        XCTAssertThrowsError(try HotKeyPlanner.plan(Binding(chord: "alt+f24", command: .nop)))
    }

    func testMouseBoundaryFocusesExactlyOnceAndUsesFrontmostOverlap() {
        let back = WindowToken(pid: 1, id: 1)
        let front = WindowToken(pid: 2, id: 2)
        var state = MouseTargetState()
        state.update([
            back: CGRect(x: 0, y: 0, width: 200, height: 200),
            front: CGRect(x: 100, y: 0, width: 200, height: 200),
        ], frontToBack: [
            MouseSurface(token: front, frame: CGRect(x: 100, y: 0, width: 200, height: 200)),
            MouseSurface(token: back, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
        ])
        XCTAssertEqual(state.moved(to: CGPoint(x: 150, y: 50)), front)
        XCTAssertNil(state.moved(to: CGPoint(x: 160, y: 50)))
        XCTAssertNil(state.moved(to: CGPoint(x: 500, y: 500)))
        XCTAssertEqual(state.moved(to: CGPoint(x: 50, y: 50)), back)
    }

    func testLayoutRefreshTargetsWindowUnderStationaryPointerExactlyOnce() {
        let old = WindowToken(pid: 1, id: 1)
        let new = WindowToken(pid: 2, id: 2)
        let pointer = CGPoint(x: 100, y: 100)
        var state = MouseTargetState()

        state.update([old: CGRect(x: 0, y: 0, width: 200, height: 200)], frontToBack: [])
        XCTAssertEqual(state.moved(to: pointer), old)

        state.update([new: CGRect(x: 0, y: 0, width: 200, height: 200)], frontToBack: [])
        XCTAssertEqual(state.refreshed(at: pointer), new)
        XCTAssertNil(state.moved(to: CGPoint(x: 101, y: 100)))
    }

    func testUnmanagedFrontSurfaceBlocksManagedWindowUnderMouse() {
        let managed = WindowToken(pid: 1, id: 1)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        var state = MouseTargetState()
        state.update([managed: frame], frontToBack: [
            MouseSurface(token: nil, frame: CGRect(x: 100, y: 0, width: 100, height: 200)),
            MouseSurface(token: managed, frame: frame),
        ])

        XCTAssertEqual(state.moved(to: CGPoint(x: 50, y: 50)), managed)
        XCTAssertNil(state.moved(to: CGPoint(x: 150, y: 50)))
        XCTAssertEqual(state.moved(to: CGPoint(x: 50, y: 50)), managed)
    }

    func testMouseResizeUsesDominantDragAxisAndSignedPixels() {
        XCTAssertEqual(
            MouseResizePlanner.step(for: CGPoint(x: 40, y: 10)),
            MouseResizeStep(direction: .right, pixels: 40)
        )
        XCTAssertEqual(
            MouseResizePlanner.step(for: CGPoint(x: -5, y: -30)),
            MouseResizeStep(direction: .up, pixels: -30)
        )
        XCTAssertNil(MouseResizePlanner.step(for: CGPoint(x: 0.2, y: -0.2)))
    }

    func testMouseResizeTargetHonoursFrontmostSurface() {
        let managed = WindowToken(pid: 1, id: 1)
        var state = MouseTargetState()
        state.update([managed: CGRect(x: 0, y: 0, width: 200, height: 200)], frontToBack: [
            MouseSurface(token: nil, frame: CGRect(x: 100, y: 0, width: 100, height: 200)),
            MouseSurface(token: managed, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
        ])
        XCTAssertEqual(state.target(at: CGPoint(x: 50, y: 50)), managed)
        XCTAssertNil(state.target(at: CGPoint(x: 150, y: 50)))
    }

    func testColumnDragRequiresNiriWindowAndCrossesTargetMidpoint() {
        let source = WindowToken(pid: 1, id: 1)
        let target = WindowToken(pid: 2, id: 2)
        let frames = [
            source: CGRect(x: 0, y: 0, width: 500, height: 600),
            target: CGRect(x: 500, y: 0, width: 500, height: 600),
        ]
        var state = MouseTargetState()
        state.update(frames, frontToBack: [], columnDraggable: [source, target])
        XCTAssertEqual(state.columnDragTarget(at: CGPoint(x: 100, y: 100)), source)

        state.update(frames, frontToBack: [], columnDraggable: [])
        XCTAssertNil(state.columnDragTarget(at: CGPoint(x: 100, y: 100)))
        XCTAssertFalse(MouseColumnDragPlanner.crossedMidpoint(
            source: frames[source]!,
            target: frames[target]!,
            pointer: CGPoint(x: 740, y: 100)
        ))
        XCTAssertTrue(MouseColumnDragPlanner.crossedMidpoint(
            source: frames[source]!,
            target: frames[target]!,
            pointer: CGPoint(x: 750, y: 100)
        ))
        XCTAssertTrue(MouseColumnDragPlanner.crossedMidpoint(
            source: CGRect(x: 0, y: 0, width: 500, height: 300),
            target: CGRect(x: 0, y: 300, width: 500, height: 300),
            pointer: CGPoint(x: 100, y: 450)
        ))
    }

    func testMouseMonitorRoutesFocusColumnDragAndResizeEvents() throws {
        let source = WindowToken(pid: 1, id: 1)
        let target = WindowToken(pid: 2, id: 2)
        let recorder = MouseEventRecorder()
        let monitor = MouseFocusMonitor()
        monitor.onWindow = { recorder.recordFocus($0) }
        monitor.onColumnMove = { recorder.recordMove($0, $1) }
        monitor.onResize = { recorder.recordResize($0, $1, $2) }
        monitor.update([
            source: CGRect(x: 0, y: 0, width: 500, height: 600),
            target: CGRect(x: 500, y: 0, width: 500, height: 600),
        ], frontToBack: [], columnDraggable: [source, target])

        XCTAssertFalse(monitor.handle(
            type: .mouseMoved,
            event: try mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 100))
        ))
        XCTAssertEqual(recorder.focused, [source])

        XCTAssertTrue(monitor.handle(
            type: .leftMouseDown,
            event: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), alternate: true)
        ))
        XCTAssertTrue(monitor.handle(
            type: .leftMouseDragged,
            event: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 750, y: 100), alternate: true)
        ))
        XCTAssertEqual(recorder.moves, [MouseMove(source: source, target: target)])
        XCTAssertTrue(monitor.handle(
            type: .leftMouseUp,
            event: try mouseEvent(.leftMouseUp, at: CGPoint(x: 750, y: 100), alternate: true)
        ))

        XCTAssertFalse(monitor.handle(
            type: .rightMouseDown,
            event: try mouseEvent(.rightMouseDown, at: CGPoint(x: 100, y: 100))
        ))
        XCTAssertTrue(monitor.handle(
            type: .rightMouseDown,
            event: try mouseEvent(.rightMouseDown, at: CGPoint(x: 100, y: 100), alternate: true)
        ))
        XCTAssertTrue(monitor.handle(
            type: .rightMouseDragged,
            event: try mouseEvent(.rightMouseDragged, at: CGPoint(x: 140, y: 110), alternate: true)
        ))
        XCTAssertEqual(
            recorder.resizes,
            [MouseResize(window: source, direction: .right, pixels: 40)]
        )
        XCTAssertTrue(monitor.handle(
            type: .rightMouseUp,
            event: try mouseEvent(.rightMouseUp, at: CGPoint(x: 140, y: 110), alternate: true)
        ))

        monitor.stop()
        XCTAssertFalse(monitor.handle(
            type: .mouseMoved,
            event: try mouseEvent(.mouseMoved, at: CGPoint(x: 600, y: 100))
        ))
        XCTAssertEqual(recorder.focused, [source, source, source])
    }

    private func mouseEvent(
        _ type: CGEventType,
        at point: CGPoint,
        alternate: Bool = false
    ) throws -> CGEvent {
        let button: CGMouseButton = switch type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: .right
        default: .left
        }
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ))
        if alternate { event.flags = [.maskAlternate] }
        return event
    }
}

private struct MouseMove: Equatable {
    let source: WindowToken
    let target: WindowToken
}

private struct MouseResize: Equatable {
    let window: WindowToken
    let direction: Direction
    let pixels: CGFloat
}

private final class MouseEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFocused: [WindowToken] = []
    private var storedMoves: [MouseMove] = []
    private var storedResizes: [MouseResize] = []

    var focused: [WindowToken] { lock.withLock { storedFocused } }
    var moves: [MouseMove] { lock.withLock { storedMoves } }
    var resizes: [MouseResize] { lock.withLock { storedResizes } }

    func recordFocus(_ window: WindowToken) {
        lock.withLock { storedFocused.append(window) }
    }

    func recordMove(_ source: WindowToken, _ target: WindowToken) {
        lock.withLock { storedMoves.append(MouseMove(source: source, target: target)) }
    }

    func recordResize(_ window: WindowToken, _ direction: Direction, _ pixels: CGFloat) {
        lock.withLock {
            storedResizes.append(MouseResize(window: window, direction: direction, pixels: pixels))
        }
    }
}
