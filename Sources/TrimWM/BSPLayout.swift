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

    /// The tree without every window outside `kept`, as removing them would leave it.
    func keeping(_ kept: Set<WindowToken>) -> BSPNode? {
        switch self {
        case let .leaf(window): kept.contains(window) ? self : nil
        case let .split(axis, ratio, first, second):
            switch (first.keeping(kept), second.keeping(kept)) {
            case (nil, nil): nil
            case let (remaining?, nil), let (nil, remaining?): remaining
            case let (left?, right?): .split(axis: axis, ratio: ratio, first: left, second: right)
            }
        }
    }

    /// The split that holds `window` as a direct child, seen from the window.
    func vacancy(of window: WindowToken) -> BSPVacancy? {
        guard case let .split(axis, ratio, first, second) = self else { return nil }
        if first == .leaf(window) {
            return BSPVacancy(window: window, sibling: Set(second.windows), axis: axis, ratio: ratio, isFirst: true)
        }
        if second == .leaf(window) {
            return BSPVacancy(window: window, sibling: Set(first.windows), axis: axis, ratio: ratio, isFirst: false)
        }
        return first.vacancy(of: window) ?? second.vacancy(of: window)
    }

    /// Splits the smallest node holding every `anchor` back around `window`.
    func placing(_ window: WindowToken, beside anchors: Set<WindowToken>, as vacancy: BSPVacancy) -> BSPNode {
        if case let .split(axis, ratio, first, second) = self {
            if anchors.isSubset(of: first.windows) {
                return .split(axis: axis, ratio: ratio, first: first.placing(window, beside: anchors, as: vacancy), second: second)
            }
            if anchors.isSubset(of: second.windows) {
                return .split(axis: axis, ratio: ratio, first: first, second: second.placing(window, beside: anchors, as: vacancy))
            }
        }
        let leaf = BSPNode.leaf(window)
        return .split(
            axis: vacancy.axis,
            ratio: vacancy.ratio,
            first: vacancy.isFirst ? leaf : self,
            second: vacancy.isFirst ? self : leaf
        )
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

/// A tree `reflowToFit` replaced because its windows did not fit, and the
/// tree it put in its place.
struct BSPReflow: Equatable, Sendable {
    let original: BSPNode
    let fitted: BSPNode
}

/// Where a removed window sat: beside `sibling`, on one side of a split.
struct BSPVacancy: Equatable, Sendable {
    let window: WindowToken
    let sibling: Set<WindowToken>
    let axis: SplitAxis
    let ratio: CGFloat
    let isFirst: Bool
}

struct BSPLayout: Equatable, Sendable {
    private(set) var root: BSPNode?
    private(set) var focused: WindowToken?
    var nextSplit: SplitAxis?
    /// The tree before windows vanished from it. While the remaining windows
    /// still sit as in it, any of them that come back, in any order, return
    /// to exactly where they were.
    private(set) var remembered: BSPNode?
    /// Recently removed windows, newest last, so one that comes back after
    /// the tree changed still returns beside its old neighbours.
    private(set) var vacancies: [BSPVacancy] = []
    static let vacancyLimit = 32
    /// The tree before it was reflowed to fit. Minimums learned from an app
    /// that applied a resize late are forgotten again, so the tree returns
    /// once it fits, unless it changed since the reflow.
    private(set) var reflowed: BSPReflow?

    var windows: [WindowToken] { root?.windows ?? [] }

    /// Inserts `window`, back into the place of the first of `restoring`
    /// that left one, or else by splitting the focused window.
    mutating func insert(
        _ window: WindowToken,
        in bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        restoring: [WindowToken] = []
    ) {
        let present = Set(windows)
        for previous in restoring where !present.contains(previous) {
            guard var memory = remembered, memory.windows.contains(previous) else { continue }
            if previous != window { memory = memory.replacing(previous, with: .leaf(window)) }
            guard memory.keeping(present) == root else { break }
            self.root = memory.keeping(present.union([window]))
            remembered = memory
            focused = window
            vacancies.removeAll { $0.window == previous }
            return
        }
        guard let root else {
            self.root = .leaf(window)
            focused = window
            vacancies.removeAll { restoring.contains($0.window) }
            return
        }
        for previous in restoring {
            guard let index = vacancies.lastIndex(where: { $0.window == previous }) else { continue }
            let vacancy = vacancies.remove(at: index)
            let anchors = vacancy.sibling.intersection(root.windows)
            guard !anchors.isEmpty else { continue }
            self.root = root.placing(window, beside: anchors, as: vacancy)
            focused = window
            return
        }
        let target = focused!
        let targetFrame = frames(in: bounds, gaps: gaps)[target]!
        let automatic: SplitAxis = targetFrame.height > targetFrame.width / max(0.01, splitRatio) ? .vertical : .horizontal
        let axis = nextSplit ?? automatic
        nextSplit = nil
        self.root = root.replacing(target, with: .split(axis: axis, ratio: 0.5, first: .leaf(target), second: .leaf(window)))
        focused = window
    }

    mutating func remove(_ window: WindowToken) {
        if let root, root.windows.contains(window), remembered?.keeping(Set(root.windows)) != root {
            remembered = root
        }
        let vacancy = root?.vacancy(of: window)
        root = root?.removing(window)
        vacancies.removeAll { $0.window == window }
        if let vacancy {
            vacancies.append(vacancy)
            if vacancies.count > Self.vacancyLimit { vacancies.removeFirst() }
        }
        guard focused == window else { return }
        // Focus the window that grows into the freed space, next to it.
        let neighbours = root?.windows.filter(vacancy?.sibling.contains ?? { _ in false }) ?? []
        focused = (vacancy?.isFirst == true ? neighbours.first : neighbours.last) ?? root?.windows.last
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
        let index = windows.firstIndex(of: focused!)!
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
        if let reflowed, reflowed.fitted != root { self.reflowed = nil }
        let order = windows
        guard order.count > 1, let root else { return false }
        guard !Self.fits(root, in: bounds, gaps: gaps, minimumSizes: minimumSizes) else {
            guard let reflowed, Self.fits(reflowed.original, in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            else { return false }
            self.root = reflowed.original
            self.reflowed = nil
            return true
        }
        let original = reflowed?.original ?? root
        defer { if let fitted = self.root, fitted != root { reflowed = BSPReflow(original: original, fitted: fitted) } }

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
                    widths.max()!,
                    heights.reduce(0, +) + gap * CGFloat(max(0, group.count - 1))
                ))
            }
            let neededWidth = columns.reduce(0) { $0 + $1.width }
                + gap * CGFloat(max(0, columns.count - 1))
            guard neededWidth <= usable.width + 4,
                  columns.map(\.height).max()! <= usable.height + 4
            else { continue }
            self.root = Self.chain(columns.map(\.node), lengths: columns.map(\.width), axis: .horizontal, gap: gap)
            return true
        }
        return false
    }

    private static func fits(
        _ node: BSPNode,
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize]
    ) -> Bool {
        var frames: [WindowToken: CGRect] = [:]
        node.frames(
            in: bounds.insetBy(dx: max(0, gaps.outer), dy: max(0, gaps.outer)),
            innerGap: gaps.inner,
            minimumSizes: minimumSizes,
            into: &frames
        )
        return node.windows.allSatisfy { window in
            guard let frame = frames[window] else { return false }
            let minimum = minimumSizes[window] ?? CGSize(width: 1, height: 1)
            return frame.width + 4 >= minimum.width && frame.height + 4 >= minimum.height
        }
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
