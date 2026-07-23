import Carbon
import XCTest
@testable import cornzWM

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
}
