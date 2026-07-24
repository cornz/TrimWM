import CoreGraphics

indirect enum BSPNode: Equatable, Sendable {
    case leaf(WindowToken)
    case split(axis: SplitAxis, ratio: CGFloat, first: BSPNode, second: BSPNode)

    var windows: [WindowToken] {
        switch self {
        case let .leaf(window): [window]
        case let .split(_, _, first, second): first.windows + second.windows
        }
    }

    func replacing(_ target: WindowToken, with replacement: BSPNode) -> BSPNode {
        switch self {
        case let .leaf(window): window == target ? replacement : self
        case let .split(axis, ratio, first, second):
            .split(
                axis: axis,
                ratio: ratio,
                first: first.replacing(target, with: replacement),
                second: second.replacing(target, with: replacement)
            )
        }
    }

    func removing(_ target: WindowToken) -> BSPNode? {
        switch self {
        case let .leaf(window): window == target ? nil : self
        case let .split(axis, ratio, first, second):
            switch (first.removing(target), second.removing(target)) {
            case (nil, nil): nil
            case let (remaining?, nil), let (nil, remaining?): remaining
            case let (left?, right?): .split(axis: axis, ratio: ratio, first: left, second: right)
            }
        }
    }

    func swapping(_ firstWindow: WindowToken, _ secondWindow: WindowToken) -> BSPNode {
        switch self {
        case let .leaf(window):
            if window == firstWindow { return .leaf(secondWindow) }
            if window == secondWindow { return .leaf(firstWindow) }
            return self
        case let .split(axis, ratio, first, second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: first.swapping(firstWindow, secondWindow),
                second: second.swapping(firstWindow, secondWindow)
            )
        }
    }

    func balanced() -> BSPNode {
        switch self {
        case .leaf: self
        case let .split(axis, _, first, second):
            .split(axis: axis, ratio: 0.5, first: first.balanced(), second: second.balanced())
        }
    }

    func resizing(window: WindowToken, axis wanted: SplitAxis, delta: CGFloat) -> (node: BSPNode, found: Bool) {
        switch self {
        case .leaf:
            return (self, false)
        case let .split(axis, ratio, first, second):
            if first.windows.contains(window) {
                let child = first.resizing(window: window, axis: wanted, delta: delta)
                if child.found {
                    return (.split(axis: axis, ratio: ratio, first: child.node, second: second), true)
                }
                if axis == wanted {
                    return (.split(axis: axis, ratio: (ratio + delta).clampedSplit, first: first, second: second), true)
                }
            } else if second.windows.contains(window) {
                let child = second.resizing(window: window, axis: wanted, delta: delta)
                if child.found {
                    return (.split(axis: axis, ratio: ratio, first: first, second: child.node), true)
                }
                if axis == wanted {
                    return (.split(axis: axis, ratio: (ratio - delta).clampedSplit, first: first, second: second), true)
                }
            }
            return (self, false)
        }
    }

    func minimumSize(innerGap: CGFloat, minimumSizes: [WindowToken: CGSize]) -> CGSize {
        switch self {
        case let .leaf(window):
            return minimumSizes[window] ?? CGSize(width: 1, height: 1)
        case let .split(axis, _, first, second):
            let firstSize = first.minimumSize(innerGap: innerGap, minimumSizes: minimumSizes)
            let secondSize = second.minimumSize(innerGap: innerGap, minimumSizes: minimumSizes)
            if axis == .horizontal {
                return CGSize(width: firstSize.width + max(0, innerGap) + secondSize.width,
                              height: max(firstSize.height, secondSize.height))
            } else {
                return CGSize(width: max(firstSize.width, secondSize.width),
                              height: firstSize.height + max(0, innerGap) + secondSize.height)
            }
        }
    }

    func frames(
        in rect: CGRect,
        innerGap: CGFloat,
        minimumSizes: [WindowToken: CGSize],
        into result: inout [WindowToken: CGRect]
    ) {
        switch self {
        case let .leaf(window):
            result[window] = rect.integral
        case let .split(axis, ratio, first, second):
            let gap = max(0, innerGap)
            let firstMinimum = first.minimumSize(innerGap: gap, minimumSizes: minimumSizes)
            let secondMinimum = second.minimumSize(innerGap: gap, minimumSizes: minimumSizes)
            if axis == .horizontal {
                let available = max(0, rect.width - gap)
                let widths = Self.constrainedLengths(
                    available * ratio,
                    available: available,
                    firstMinimum: firstMinimum.width,
                    secondMinimum: secondMinimum.width
                )
                first.frames(
                    in: CGRect(x: rect.minX, y: rect.minY, width: widths.first, height: rect.height),
                    innerGap: gap,
                    minimumSizes: minimumSizes,
                    into: &result
                )
                second.frames(
                    in: CGRect(x: rect.minX + widths.first + gap, y: rect.minY, width: widths.second, height: rect.height),
                    innerGap: gap,
                    minimumSizes: minimumSizes,
                    into: &result
                )
            } else {
                let available = max(0, rect.height - gap)
                let heights = Self.constrainedLengths(
                    available * ratio,
                    available: available,
                    firstMinimum: firstMinimum.height,
                    secondMinimum: secondMinimum.height
                )
                first.frames(
                    in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: heights.first),
                    innerGap: gap,
                    minimumSizes: minimumSizes,
                    into: &result
                )
                second.frames(
                    in: CGRect(x: rect.minX, y: rect.minY + heights.first + gap, width: rect.width, height: heights.second),
                    innerGap: gap,
                    minimumSizes: minimumSizes,
                    into: &result
                )
            }
        }
    }

    private static func constrainedLengths(
        _ preferred: CGFloat,
        available: CGFloat,
        firstMinimum: CGFloat,
        secondMinimum: CGFloat
    ) -> (first: CGFloat, second: CGFloat) {
        let first = max(1, firstMinimum)
        let second = max(1, secondMinimum)
        if first + second > available {
            let firstLength = floor(min(max(preferred, 1), max(1, available - 1)))
            return (firstLength, max(1, available - firstLength))
        }
        let firstLength = floor(min(max(preferred, first), available - second))
        return (firstLength, available - firstLength)
    }
}

struct BSPLayout: Equatable, Sendable {
    private(set) var root: BSPNode?
    private(set) var focused: WindowToken?
    var nextSplit: SplitAxis?

    var windows: [WindowToken] { root?.windows ?? [] }

    mutating func insert(_ window: WindowToken, in bounds: CGRect, gaps: LayoutGaps, splitRatio: CGFloat) {
        guard let root else {
            self.root = .leaf(window)
            focused = window
            return
        }
        let target = focused.flatMap { root.windows.contains($0) ? $0 : nil } ?? root.windows.last!
        let targetFrame = frames(in: bounds, gaps: gaps)[target] ?? bounds
        let automatic: SplitAxis = targetFrame.height > targetFrame.width / max(0.01, splitRatio) ? .vertical : .horizontal
        let axis = nextSplit ?? automatic
        nextSplit = nil
        self.root = root.replacing(target, with: .split(axis: axis, ratio: 0.5, first: .leaf(target), second: .leaf(window)))
        focused = window
    }

    mutating func remove(_ window: WindowToken) {
        root = root?.removing(window)
        if focused == window { focused = root?.windows.last }
    }

    mutating func focus(_ window: WindowToken) {
        if windows.contains(window) { focused = window }
    }

    mutating func focus(
        _ direction: Direction,
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let focused,
              let next = Geometry.nearest(
                from: focused,
                direction: direction,
                frames: frames(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
              )
        else { return }
        self.focused = next
    }

    mutating func focusNext() {
        guard !windows.isEmpty else { return }
        guard let focused, let index = windows.firstIndex(of: focused) else {
            self.focused = windows[0]
            return
        }
        self.focused = windows[(index + 1) % windows.count]
    }

    mutating func move(
        _ direction: Direction,
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let focused,
              let target = Geometry.nearest(
                from: focused,
                direction: direction,
                frames: frames(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
              )
        else { return }
        root = root?.swapping(focused, target)
    }

    mutating func swap(_ window: WindowToken, with target: WindowToken) {
        guard window != target, windows.contains(window), windows.contains(target) else { return }
        root = root?.swapping(window, target)
        focused = window
    }

    mutating func resize(axis: SplitAxis, delta: CGFloat) {
        guard let focused, let root else { return }
        self.root = root.resizing(window: focused, axis: axis, delta: delta).node
    }

    mutating func balance() { root = root?.balanced() }

    @discardableResult
    mutating func reflowToFit(
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize]
    ) -> Bool {
        let order = windows
        guard order.count > 1 else { return false }
        let current = frames(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        guard order.contains(where: { window in
            guard let frame = current[window] else { return true }
            let minimum = minimumSizes[window] ?? CGSize(width: 1, height: 1)
            return frame.width + 4 < minimum.width || frame.height + 4 < minimum.height
        }) else { return false }

        let gap = max(0, gaps.inner)
        let usable = bounds.insetBy(dx: max(0, gaps.outer), dy: max(0, gaps.outer))
        for columnCount in Array(2...order.count) + [1] {
            let base = order.count / columnCount
            let extra = order.count % columnCount
            var index = 0
            var columns: [(node: BSPNode, width: CGFloat, height: CGFloat)] = []
            for column in 0..<columnCount {
                let count = base + (column < extra ? 1 : 0)
                let group = Array(order[index..<(index + count)])
                index += count
                let widths = group.map { max(1, minimumSizes[$0]?.width ?? 1) }
                let heights = group.map { max(1, minimumSizes[$0]?.height ?? 1) }
                columns.append((
                    Self.chain(group.map(BSPNode.leaf), lengths: heights, axis: .vertical, gap: gap),
                    widths.max() ?? 1,
                    heights.reduce(0, +) + gap * CGFloat(max(0, group.count - 1))
                ))
            }
            let neededWidth = columns.reduce(0) { $0 + $1.width }
                + gap * CGFloat(max(0, columns.count - 1))
            guard neededWidth <= usable.width + 4,
                  (columns.map(\.height).max() ?? 0) <= usable.height + 4
            else { continue }
            root = Self.chain(columns.map(\.node), lengths: columns.map(\.width), axis: .horizontal, gap: gap)
            return true
        }
        return false
    }

    private static func chain(
        _ nodes: [BSPNode],
        lengths: [CGFloat],
        axis: SplitAxis,
        gap: CGFloat
    ) -> BSPNode {
        guard nodes.count > 1 else { return nodes[0] }
        var node = nodes.last!
        var remaining = lengths.last!
        for index in nodes.indices.dropLast().reversed() {
            let available = max(2, lengths[index] + remaining)
            node = .split(
                axis: axis,
                ratio: (lengths[index] / available).clampedSplit,
                first: nodes[index],
                second: node
            )
            remaining += gap + lengths[index]
        }
        return node
    }

    func frames(
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) -> [WindowToken: CGRect] {
        guard let root else { return [:] }
        let outer = max(0, gaps.outer)
        let usable = bounds.insetBy(dx: outer, dy: outer)
        var result: [WindowToken: CGRect] = [:]
        root.frames(in: usable, innerGap: gaps.inner, minimumSizes: minimumSizes, into: &result)
        return result
    }
}

private extension CGFloat {
    var clampedSplit: CGFloat { Swift.min(0.9, Swift.max(0.1, self)) }
}
