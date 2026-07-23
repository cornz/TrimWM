import CoreGraphics
import Foundation

struct WindowToken: Hashable, Codable, Sendable, Comparable {
    let pid: pid_t
    let id: CGWindowID

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pid, lhs.id) < (rhs.pid, rhs.id)
    }
}

enum Direction: String, Sendable {
    case left, right, up, down
}

enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct LayoutGaps: Equatable, Sendable {
    var inner: CGFloat = 0
    var outer: CGFloat = 0
}

enum LayoutMode: String, Codable, Sendable {
    case autotile
    case niri
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
