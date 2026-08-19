import ApplicationServices
import CoreGraphics
import XCTest
@testable import TrimWM

final class WindowSystemTests: XCTestCase {
    func testWindowInventoryReconcilerReturnsOnlyPIDsWithMissingWindows() {
        let first = WindowToken(pid: 10, id: 100)
        let second = WindowToken(pid: 10, id: 101)
        let third = WindowToken(pid: 20, id: 200)

        XCTAssertEqual(
            WindowInventoryReconciler.stalePIDs(
                tracked: [first, second, third],
                liveWindowIDs: [100, 200]
            ),
            [10]
        )
        XCTAssertTrue(
            WindowInventoryReconciler.stalePIDs(
                tracked: [first, third],
                liveWindowIDs: [100, 200]
            ).isEmpty
        )
    }

    func testOnlyMoveAndResizeNotificationsUseTargetedFrameRefresh() {
        XCTAssertEqual(AXNotificationRouter.route(kAXWindowMovedNotification as String), .frame)
        XCTAssertEqual(AXNotificationRouter.route(kAXWindowResizedNotification as String), .frame)
        for notification in [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
        ] {
            XCTAssertEqual(AXNotificationRouter.route(notification as String), .scan)
        }
    }

    func testMouseSurfaceFilterUsesOnlyVisibleNormalWindows() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(MouseSurfaceFilter.includes(layer: 0, alpha: 1, frame: frame))
        XCTAssertFalse(MouseSurfaceFilter.includes(layer: 20, alpha: 1, frame: frame))
        XCTAssertFalse(MouseSurfaceFilter.includes(layer: 0, alpha: 0, frame: frame))
        XCTAssertFalse(MouseSurfaceFilter.includes(layer: 0, alpha: 1, frame: .zero))
    }

    func testClassifierTilesOnlyMovableResizableStandardWindows() {
        XCTAssertEqual(WindowClassifier.classify(.init(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            movable: true,
            resizable: true,
            minimized: false,
            nativeFullscreen: false
        )), .tiled)
    }

    func testClassifierFloatsDialogsFloatingWindowsAndFixedSizeWindows() {
        for subrole in [
            kAXDialogSubrole,
            kAXSystemDialogSubrole,
            kAXFloatingWindowSubrole,
        ] {
            XCTAssertEqual(WindowClassifier.classify(.init(
                role: kAXWindowRole as String,
                subrole: subrole as String,
                movable: true,
                resizable: true,
                minimized: false,
                nativeFullscreen: false
            )), .floating)
        }
        XCTAssertEqual(WindowClassifier.classify(.init(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            movable: true,
            resizable: false,
            minimized: false,
            nativeFullscreen: false
        ), title: "Preferences"), .floating)
    }

    func testClassifierIgnoresTransientAndUnknownWindows() {
        for subrole: String? in [
            kAXUnknownSubrole as String,
            kAXSystemFloatingWindowSubrole as String,
            nil,
        ] {
            XCTAssertEqual(WindowClassifier.classify(.init(
                role: kAXWindowRole as String,
                subrole: subrole,
                movable: true,
                resizable: true,
                minimized: false,
                nativeFullscreen: false
            )), .unmanaged)
        }
        XCTAssertEqual(WindowClassifier.classify(.init(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            movable: true,
            resizable: false,
            minimized: false,
            nativeFullscreen: false
        )), .unmanaged)
    }

    func testClassifierIgnoresMinimizedFullscreenAndNonWindowSurfaces() {
        for input in [
            WindowClassificationInput(role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, movable: true, resizable: true, minimized: true, nativeFullscreen: false),
            WindowClassificationInput(role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, movable: true, resizable: true, minimized: false, nativeFullscreen: true),
            WindowClassificationInput(role: kAXMenuRole as String, subrole: nil, movable: true, resizable: true, minimized: false, nativeFullscreen: false),
        ] { XCTAssertEqual(WindowClassifier.classify(input), .unmanaged) }
    }

    func testFrameLedgerSuppressesUnchangedAndQuantizedWrites() {
        let window = WindowToken(pid: 1, id: 2)
        var ledger = FrameLedger()
        let first = CGRect(x: 1, y: 2, width: 300, height: 400)
        let latest = CGRect(x: 6, y: 2, width: 300, height: 400)
        XCTAssertTrue(ledger.needsWrite(first, for: window))
        XCTAssertFalse(ledger.needsWrite(CGRect(x: 1.5, y: 2, width: 300, height: 400), for: window))
        XCTAssertFalse(ledger.needsWrite(latest, for: window))
        XCTAssertEqual(
            ledger.completed(first, for: window, result: .init(observed: first, succeeded: true)),
            .write(latest)
        )
        ledger.remove(window)
        XCTAssertTrue(ledger.needsWrite(latest, for: window))
    }

    func testFrameLedgerDoesNotFightIntermediateNativeEchoes() {
        let window = WindowToken(pid: 1, id: 2)
        let target = CGRect(x: 100, y: 100, width: 600, height: 400)
        let partial = CGRect(x: 10, y: 10, width: 600, height: 400)
        var ledger = FrameLedger()
        ledger.observed(CGRect(x: 10, y: 10, width: 300, height: 200), for: window)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
        ledger.observed(partial, for: window)
        XCTAssertFalse(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: partial, succeeded: false)),
            .write(target)
        )
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: partial, succeeded: false)),
            .refused(partial)
        )
        ledger.observed(partial, for: window)
        XCTAssertFalse(ledger.needsWrite(target, for: window))
        ledger.observed(target, for: window)
        XCTAssertFalse(ledger.needsWrite(target, for: window))
    }

    func testFrameLedgerKeepsRefusedTargetSuppressedAcrossNativeResizeEvents() {
        let window = WindowToken(pid: 1, id: 2)
        let original = CGRect(x: 10, y: 10, width: 300, height: 200)
        let target = CGRect(x: 100, y: 100, width: 600, height: 400)
        var ledger = FrameLedger()
        ledger.observed(original, for: window)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
        let failure = AXFrameWriteResult(observed: original, succeeded: false)
        XCTAssertEqual(ledger.completed(target, for: window, result: failure), .write(target))
        XCTAssertEqual(ledger.completed(target, for: window, result: failure), .refused(original))
        XCTAssertFalse(ledger.needsWrite(target, for: window))

        for step in 1 ... 10 {
            ledger.observed(
                CGRect(x: 10 + step, y: 10, width: 300 + step, height: 200 + step),
                for: window
            )
            XCTAssertFalse(ledger.needsWrite(target, for: window))
        }

        let changedTarget = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertTrue(ledger.needsWrite(changedTarget, for: window))
    }

    func testFrameLedgerStopsFightingRepeatedFastApplicationOverrides() {
        let window = WindowToken(pid: 1, id: 2)
        let original = CGRect(x: 0, y: 0, width: 524, height: 760)
        let target = CGRect(x: 100, y: 0, width: 586, height: 704)
        let applicationFrame = CGRect(x: 100, y: 0, width: 586, height: 356)
        var ledger = FrameLedger()
        ledger.observed(original, for: window, at: 0)

        XCTAssertTrue(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: target, succeeded: true)),
            .none
        )

        ledger.observed(applicationFrame, for: window, at: 1)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: target, succeeded: true)),
            .none
        )

        ledger.observed(applicationFrame, for: window, at: 2)
        XCTAssertFalse(ledger.needsWrite(target, for: window))
        ledger.observed(applicationFrame, for: window, at: 2.5)
        XCTAssertFalse(ledger.needsWrite(target, for: window))

        let changedTarget = CGRect(x: 100, y: 0, width: 700, height: 704)
        XCTAssertTrue(ledger.needsWrite(changedTarget, for: window))
    }

    func testFrameLedgerKeepsCorrectingRapidDifferentManualMoves() {
        let window = WindowToken(pid: 1, id: 2)
        let target = CGRect(x: 100, y: 0, width: 586, height: 704)
        var ledger = FrameLedger()

        XCTAssertTrue(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: target, succeeded: true)),
            .none
        )

        ledger.observed(CGRect(x: 140, y: 30, width: 586, height: 704), for: window, at: 1)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: target, succeeded: true)),
            .none
        )

        ledger.observed(CGRect(x: 180, y: 60, width: 586, height: 704), for: window, at: 2)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
    }

    func testFrameLedgerStillCorrectsUnrelatedSlowApplicationOverrides() {
        let window = WindowToken(pid: 1, id: 2)
        let target = CGRect(x: 100, y: 0, width: 586, height: 704)
        let override = CGRect(x: 100, y: 0, width: 586, height: 356)
        var ledger = FrameLedger()

        XCTAssertTrue(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: target, succeeded: true)),
            .none
        )
        ledger.observed(override, for: window, at: 1)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
        XCTAssertEqual(
            ledger.completed(target, for: window, result: .init(observed: target, succeeded: true)),
            .none
        )
        ledger.observed(override, for: window, at: 10)
        XCTAssertTrue(ledger.needsWrite(target, for: window))
    }

    func testFrameLedgerIgnoresStaleWriteFailure() {
        let window = WindowToken(pid: 1, id: 2)
        var ledger = FrameLedger()
        let old = CGRect(x: 0, y: 0, width: 100, height: 100)
        let current = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertTrue(ledger.needsWrite(old, for: window))
        XCTAssertFalse(ledger.needsWrite(current, for: window))
        XCTAssertEqual(
            ledger.completed(old, for: window, result: .init(observed: old, succeeded: false)),
            .write(current)
        )
        XCTAssertEqual(
            ledger.completed(current, for: window, result: .init(observed: old, succeeded: false)),
            .write(current)
        )
    }

    func testFrameLedgerCoalescesNewTargetWhileWriteIsInFlight() {
        let window = WindowToken(pid: 1, id: 2)
        let original = CGRect(x: 0, y: 0, width: 300, height: 200)
        let intermediate = CGRect(x: 0, y: 0, width: 900, height: 600)
        let latest = CGRect(x: 450, y: 0, width: 450, height: 600)
        var ledger = FrameLedger()
        ledger.observed(original, for: window)

        XCTAssertTrue(ledger.needsWrite(intermediate, for: window))
        XCTAssertFalse(ledger.needsWrite(latest, for: window))
        XCTAssertEqual(
            ledger.completed(
                intermediate,
                for: window,
                result: .init(observed: intermediate, succeeded: true)
            ),
            .write(latest)
        )
        XCTAssertEqual(
            ledger.completed(latest, for: window, result: .init(observed: latest, succeeded: true)),
            .none
        )
        XCTAssertFalse(ledger.needsWrite(latest, for: window))
    }

    func testFrameWriterUsesPositionFirstOnlyWhenGrowing() {
        let current = CGRect(x: 50, y: 50, width: 500, height: 500)
        XCTAssertEqual(
            AXFrameWriter.order(current: current, target: CGRect(x: 0, y: 0, width: 600, height: 400)),
            .positionThenSize
        )
        XCTAssertEqual(
            AXFrameWriter.order(current: current, target: CGRect(x: 0, y: 0, width: 400, height: 400)),
            .sizeThenPosition
        )
        XCTAssertEqual(AXFrameWriter.order(current: nil, target: current), .sizeThenPosition)
    }

    func testFrameWriterSkipsUnchangedAXAttributes() {
        let current = CGRect(x: 50, y: 50, width: 500, height: 400)
        XCTAssertEqual(
            AXFrameWriter.plan(current: current, target: CGRect(x: -499, y: 50, width: 500, height: 400)),
            AXFrameWritePlan(order: .sizeThenPosition, writesPosition: true, writesSize: false)
        )
        XCTAssertEqual(
            AXFrameWriter.plan(current: current, target: CGRect(x: 50, y: 50, width: 600, height: 400)),
            AXFrameWritePlan(order: .positionThenSize, writesPosition: false, writesSize: true)
        )
        XCTAssertEqual(
            AXFrameWriter.plan(current: current, target: current),
            AXFrameWritePlan(order: .sizeThenPosition, writesPosition: false, writesSize: false)
        )
        XCTAssertEqual(
            AXFrameWriter.plan(current: nil, target: current),
            AXFrameWritePlan(order: .sizeThenPosition, writesPosition: true, writesSize: true)
        )
        XCTAssertEqual(
            AXFrameWriter.plan(
                current: CGRect(x: 960, y: 516, width: 740, height: 485),
                target: CGRect(x: 580, y: 516, width: 740, height: 486)
            ),
            AXFrameWritePlan(order: .positionThenSize, writesPosition: true, writesSize: false)
        )
        XCTAssertTrue(
            AXFrameWriter.plan(
                current: CGRect(x: 577, y: 516, width: 740, height: 485),
                target: CGRect(x: 960, y: 516, width: 960, height: 486)
            ).reassertsPosition
        )
        XCTAssertFalse(
            AXFrameWriter.plan(
                current: CGRect(x: 960, y: 516, width: 960, height: 486),
                target: CGRect(x: 960, y: 516, width: 480, height: 486)
            ).reassertsPosition
        )
    }

    func testAXScanGateCoalescesQueuedBurstsAndYieldsBeforeRescan() {
        var gate = AXScanGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        gate.begin()
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.finish())
        XCTAssertTrue(gate.request())
        gate.reset()
        XCTAssertTrue(gate.request())
    }

    func testFrameConstraintLearnerUsesOnlyRefusedLargerAxes() {
        let target = CGRect(x: 0, y: 0, width: 900, height: 400)
        XCTAssertEqual(
            FrameConstraintLearner.minimum(
                target: target,
                observed: CGRect(x: 0, y: 0, width: 480, height: 600)
            ),
            CGSize(width: 1, height: 600)
        )
        XCTAssertNil(FrameConstraintLearner.minimum(target: target, observed: target))
    }

    func testFrameConstraintCacheKeepsLargestRefusedNativeMinimum() {
        let window = WindowToken(pid: 4, id: 5)
        var cache = FrameConstraintCache()
        XCTAssertTrue(cache.learn(CGSize(width: 740, height: 485), for: window))
        XCTAssertEqual(cache.value(for: window), CGSize(width: 740, height: 485))
        XCTAssertFalse(cache.learn(CGSize(width: 600, height: 400), for: window))
        XCTAssertEqual(cache.value(for: window), CGSize(width: 740, height: 485))
        cache.remove(window)
        XCTAssertNil(cache.value(for: window))
    }

    func testFrameConstraintCacheResetForgetsAllWindows() {
        let first = WindowToken(pid: 4, id: 5)
        let second = WindowToken(pid: 6, id: 7)
        var cache = FrameConstraintCache()
        XCTAssertTrue(cache.learn(CGSize(width: 500, height: 400), for: first))
        XCTAssertTrue(cache.learn(CGSize(width: 600, height: 300), for: second))

        cache.reset()

        XCTAssertNil(cache.value(for: first))
        XCTAssertNil(cache.value(for: second))
    }

    func testFrameLedgerResetAndUnknownCompletionAreNoOps() {
        let window = WindowToken(pid: 4, id: 5)
        let target = CGRect(x: 10, y: 20, width: 500, height: 400)
        var ledger = FrameLedger()
        XCTAssertEqual(
            ledger.completed(
                target,
                for: window,
                result: AXFrameWriteResult(observed: target, succeeded: true)
            ),
            .none
        )
        XCTAssertTrue(ledger.needsWrite(target, for: window))

        ledger.reset()

        XCTAssertTrue(ledger.needsWrite(target, for: window))
    }

}
