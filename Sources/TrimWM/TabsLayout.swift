import CoreGraphics

enum TabBarPosition: String, Equatable, Sendable {
    case top, left
}

struct TabBarSettings: Equatable, Sendable {
    var position: TabBarPosition = .top
    /// The bar's height at the top or width on the left; nil uses the default.
    var size: CGFloat?
    /// Whether the bar only appears over the window on demand instead of
    /// taking room from it.
    var autohide = false

    static let defaultTopSize: CGFloat = 32
    static let defaultLeftSize: CGFloat = 44
    /// The gap between the bar and the window it does not cover.
    static let spacing: CGFloat = 6

    var thickness: CGFloat {
        max(1, size ?? (position == .top ? Self.defaultTopSize : Self.defaultLeftSize))
    }
}

/// Every window shares one frame, like tabs in a browser: only the focused
/// window is shown, and the others are hidden like windows on another
/// workspace. A tab bar drawn by TrimWM lists them.
struct TabsLayout: Equatable, Sendable {
    private(set) var windows: [WindowToken] = []
    private(set) var focused: WindowToken?
    var bar = TabBarSettings()

    /// Opens a tab to the right of the focused one.
    mutating func insert(_ window: WindowToken) {
        guard !windows.contains(window) else { return }
        let index = focused.flatMap(windows.firstIndex(of:)).map { $0 + 1 } ?? windows.endIndex
        windows.insert(window, at: index)
        focused = window
    }

    /// Closing the focused tab focuses the one to its right, or the last one.
    mutating func remove(_ window: WindowToken) {
        guard let index = windows.firstIndex(of: window) else { return }
        windows.remove(at: index)
        if focused == window { focused = windows.isEmpty ? nil : windows[min(index, windows.count - 1)] }
    }

    mutating func focus(_ window: WindowToken) {
        if windows.contains(window) { focused = window }
    }

    /// Left and up go to the previous tab, right and down to the next.
    mutating func focus(_ direction: Direction) {
        guard let target = neighbor(direction) else { return }
        focused = windows[target]
    }

    /// Moves the focused tab one place towards the direction.
    mutating func move(_ direction: Direction) {
        guard let focused, let index = windows.firstIndex(of: focused), let target = neighbor(direction) else { return }
        windows.swapAt(index, target)
    }

    /// The bar is shown, and takes room unless it hides, from two tabs on.
    var showsBar: Bool { windows.count > 1 }

    func barFrame(in bounds: CGRect, gaps: LayoutGaps) -> CGRect? {
        guard showsBar else { return nil }
        let usable = Self.usable(bounds, gaps: gaps)
        let thickness = min(bar.thickness, bar.position == .top ? usable.height : usable.width)
        return switch bar.position {
        case .top: CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: thickness)
        case .left: CGRect(x: usable.minX, y: usable.minY, width: thickness, height: usable.height)
        }
    }

    func contentFrame(in bounds: CGRect, gaps: LayoutGaps) -> CGRect {
        let usable = Self.usable(bounds, gaps: gaps)
        guard !bar.autohide, let bar = barFrame(in: bounds, gaps: gaps) else { return usable.integral }
        let spacing = TabBarSettings.spacing
        return switch self.bar.position {
        case .top:
            CGRect(x: usable.minX, y: bar.maxY + spacing, width: usable.width, height: max(1, usable.maxY - bar.maxY - spacing)).integral
        case .left:
            CGRect(x: bar.maxX + spacing, y: usable.minY, width: max(1, usable.maxX - bar.maxX - spacing), height: usable.height).integral
        }
    }

    /// Only the focused tab has a frame; the others are hidden.
    func frames(in bounds: CGRect, gaps: LayoutGaps) -> [WindowToken: CGRect] {
        guard let focused else { return [:] }
        return [focused: contentFrame(in: bounds, gaps: gaps)]
    }

    private func neighbor(_ direction: Direction) -> Int? {
        guard let focused, let index = windows.firstIndex(of: focused) else { return nil }
        let target = index + (direction == .left || direction == .up ? -1 : 1)
        return windows.indices.contains(target) ? target : nil
    }

    private static func usable(_ bounds: CGRect, gaps: LayoutGaps) -> CGRect {
        let outer = max(0, gaps.outer)
        return bounds.insetBy(dx: outer, dy: outer)
    }
}
