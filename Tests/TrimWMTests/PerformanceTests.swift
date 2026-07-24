import CoreGraphics
import XCTest
@testable import TrimWM

final class PerformanceTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 31, width: 2560, height: 1409)

    func testHundredWindowLayoutP99IsBelowTwoMilliseconds() {
        var bsp = BSPLayout()
        var niri = NiriLayout()
        for id in 1...100 {
            let window = WindowToken(pid: 1, id: CGWindowID(id))
            bsp.insert(window, in: bounds, gaps: .init(), splitRatio: 1)
            niri.insert(window)
        }
        XCTAssertLessThan(p99 { _ = bsp.frames(in: bounds, gaps: .init(inner: 4, outer: 4)) }, 0.002)
        XCTAssertLessThan(p99 { _ = niri.frames(in: bounds, gaps: .init(inner: 4, outer: 4)) }, 0.002)
    }

    func testDeterministicStressKeepsEveryWindowExactlyOnce() {
        var bsp = BSPLayout()
        var niri = NiriLayout()
        let windows = (1...100).map { WindowToken(pid: 2, id: CGWindowID($0)) }
        for window in windows { bsp.insert(window, in: bounds, gaps: .init(), splitRatio: 1); niri.insert(window) }
        for index in 0..<500 {
            let window = windows[(index * 37) % windows.count]
            bsp.focus(window)
            bsp.move(index.isMultiple(of: 2) ? .left : .right, in: bounds, gaps: .init())
            bsp.resize(axis: index.isMultiple(of: 3) ? .horizontal : .vertical, delta: index.isMultiple(of: 2) ? 0.01 : -0.01)
            niri.focus(window)
            niri.move(index.isMultiple(of: 2) ? .left : .right)
            niri.consume(index.isMultiple(of: 2) ? .left : .right)
            niri.expel(index.isMultiple(of: 2) ? .right : .left)
        }
        XCTAssertEqual(Set(bsp.windows), Set(windows))
        XCTAssertEqual(bsp.windows.count, windows.count)
        XCTAssertEqual(Set(niri.windows), Set(windows))
        XCTAssertEqual(niri.windows.count, windows.count)
    }

    private func p99(iterations: Int = 300, operation: () -> Void) -> TimeInterval {
        var samples: [TimeInterval] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            operation()
            samples.append(TimeInterval(start.duration(to: .now).components.attoseconds) / 1e18)
        }
        samples.sort()
        return samples[min(samples.count - 1, Int(Double(samples.count) * 0.99))]
    }
}
