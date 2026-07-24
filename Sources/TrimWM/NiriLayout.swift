import CoreGraphics

struct NiriColumn: Equatable, Sendable {
    var windows: [WindowToken]
    var width: CGFloat
}

struct NiriLayout: Equatable, Sendable {
    private(set) var columns: [NiriColumn] = []
    private(set) var focused: WindowToken?
    private(set) var viewportOffset: CGFloat = 0
    private var centered: WindowToken?
    private var rowFractions: [WindowToken: CGFloat] = [:]

    var windows: [WindowToken] { columns.flatMap(\.windows) }

    mutating func insert(_ window: WindowToken) {
        let index = focused.flatMap(columnIndex(containing:)).map { $0 + 1 } ?? columns.endIndex
        columns.insert(NiriColumn(windows: [window], width: 0.5), at: index)
        rowFractions[window] = 1
        focused = window
        centered = nil
    }

    mutating func remove(_ window: WindowToken) {
        guard let column = columnIndex(containing: window), let row = columns[column].windows.firstIndex(of: window) else { return }
        centered = nil
        columns[column].windows.remove(at: row)
        rowFractions.removeValue(forKey: window)
        if columns[column].windows.isEmpty { columns.remove(at: column) }
        else { resetRowFractions(in: column) }
        if focused == window { focused = columns[safe: min(column, columns.count - 1)]?.windows.first }
        if columns.isEmpty { viewportOffset = 0 }
    }

    mutating func focus(_ window: WindowToken) {
        guard windows.contains(window), focused != window else { return }
        focused = window
        centered = nil
    }

    mutating func focus(_ direction: Direction) {
        guard let position = focused.flatMap(position(of:)) else { return }
        switch direction {
        case .up:
            guard position.row > 0 else { return }
            focused = columns[position.column].windows[position.row - 1]
        case .down:
            guard position.row + 1 < columns[position.column].windows.count else { return }
            focused = columns[position.column].windows[position.row + 1]
        case .left, .right:
            let target = position.column + (direction == .left ? -1 : 1)
            guard columns.indices.contains(target) else { return }
            focused = columns[target].windows[min(position.row, columns[target].windows.count - 1)]
        }
        centered = nil
    }

    mutating func move(_ direction: Direction) {
        guard let window = focused, let position = position(of: window) else { return }
        switch direction {
        case .up, .down:
            let target = position.row + (direction == .up ? -1 : 1)
            guard columns[position.column].windows.indices.contains(target) else { return }
            columns[position.column].windows.swapAt(position.row, target)
        case .left, .right:
            let delta = direction == .left ? -1 : 1
            if columns[position.column].windows.count == 1 {
                let target = position.column + delta
                guard columns.indices.contains(target) else { return }
                columns.swapAt(position.column, target)
            } else {
                columns[position.column].windows.remove(at: position.row)
                resetRowFractions(in: position.column)
                let newIndex = direction == .left ? position.column : position.column + 1
                columns.insert(NiriColumn(windows: [window], width: 0.5), at: newIndex)
                rowFractions[window] = 1
            }
        }
        centered = nil
    }

    mutating func swapColumn(containing window: WindowToken, with target: WindowToken) {
        guard let source = columnIndex(containing: window),
              let destination = columnIndex(containing: target),
              source != destination
        else { return }
        columns.swapAt(source, destination)
        centered = nil
    }

    mutating func consume(_ direction: Direction) {
        guard direction == .left || direction == .right,
              let window = focused,
              let source = columnIndex(containing: window),
              let row = columns[source].windows.firstIndex(of: window)
        else { return }
        let target = source + (direction == .left ? -1 : 1)
        guard columns.indices.contains(target) else { return }
        centered = nil
        columns[source].windows.remove(at: row)
        columns[target].windows.append(window)
        resetRowFractions(in: target)
        if columns[source].windows.isEmpty { columns.remove(at: source) }
        else { resetRowFractions(in: source) }
    }

    mutating func expel(_ direction: Direction) {
        guard direction == .left || direction == .right,
              let window = focused,
              let source = columnIndex(containing: window),
              columns[source].windows.count > 1,
              let row = columns[source].windows.firstIndex(of: window)
        else { return }
        centered = nil
        columns[source].windows.remove(at: row)
        resetRowFractions(in: source)
        let index = direction == .left ? source : source + 1
        columns.insert(NiriColumn(windows: [window], width: 0.5), at: index)
        rowFractions[window] = 1
    }

    mutating func setFocusedWidth(_ fraction: CGFloat) {
        guard let column = focused.flatMap(columnIndex(containing:)) else { return }
        let width = min(1, max(0.1, fraction))
        guard columns[column].width != width else { return }
        centered = nil
        columns[column].width = width
    }

    mutating func resizeFocused(by pixels: CGFloat, viewportWidth: CGFloat) {
        guard viewportWidth > 0, let column = focused.flatMap(columnIndex(containing:)) else { return }
        let width = min(1, max(0.1, columns[column].width + pixels / viewportWidth))
        guard columns[column].width != width else { return }
        centered = nil
        columns[column].width = width
    }

    mutating func resizeFocusedVertically(_ direction: Direction, by pixels: CGFloat, viewportHeight: CGFloat) {
        guard viewportHeight > 0,
              direction == .up || direction == .down,
              let window = focused,
              let position = position(of: window),
              columns[position.column].windows.count > 1
        else { return }
        let neighbourRow = position.row + (direction == .up ? -1 : 1)
        guard columns[position.column].windows.indices.contains(neighbourRow) else { return }
        let neighbour = columns[position.column].windows[neighbourRow]
        let equal = 1 / CGFloat(columns[position.column].windows.count)
        let current = rowFractions[window] ?? equal
        let adjacent = rowFractions[neighbour] ?? equal
        let minimum: CGFloat = 0.05
        let delta = min(max(pixels / viewportHeight, minimum - current), adjacent - minimum)
        guard abs(delta) > 0.0001 else { return }
        rowFractions[window] = current + delta
        rowFractions[neighbour] = adjacent - delta
    }

    mutating func centerFocused(
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let column = focused.flatMap(columnIndex(containing:)) else { return }
        let width = max(0, bounds.width - 2 * max(0, gaps.outer))
        let metrics = columnMetrics(viewportWidth: width, innerGap: gaps.inner, minimumSizes: minimumSizes)
        let contentWidth = metrics.last.map { $0.minX + $0.width } ?? 0
        viewportOffset = Self.clampViewportOffset(
            metrics[column].minX + metrics[column].width / 2 - width / 2,
            viewportWidth: width,
            contentWidth: contentWidth,
            allowsEdgeMargin: true
        )
        centered = focused
    }

    mutating func revealFocused(
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let column = focused.flatMap(columnIndex(containing:)) else { return }
        centered = nil
        let width = max(0, bounds.width - 2 * max(0, gaps.outer))
        let metrics = columnMetrics(viewportWidth: width, innerGap: gaps.inner, minimumSizes: minimumSizes)
        let metric = metrics[column]
        let left = metric.minX - viewportOffset
        let right = left + metric.width
        if left < 0 { viewportOffset = metric.minX }
        if right > width { viewportOffset = metric.minX + metric.width - width }
        let contentWidth = metrics.last.map { $0.minX + $0.width } ?? 0
        viewportOffset = Self.clampViewportOffset(
            viewportOffset,
            viewportWidth: width,
            contentWidth: contentWidth,
            allowsEdgeMargin: false
        )
    }

    func frames(
        in bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) -> [WindowToken: CGRect] {
        let outer = max(0, gaps.outer)
        let usable = bounds.insetBy(dx: outer, dy: outer)
        let metrics = columnMetrics(viewportWidth: usable.width, innerGap: gaps.inner, minimumSizes: minimumSizes)
        let contentWidth = metrics.last.map { $0.minX + $0.width } ?? 0
        var offset = Self.clampViewportOffset(
            viewportOffset,
            viewportWidth: usable.width,
            contentWidth: contentWidth,
            allowsEdgeMargin: centered == focused
        )
        if centered != focused, let column = focused.flatMap(columnIndex(containing:)) {
            if metrics[column].minX - offset < 0 { offset = metrics[column].minX }
            if metrics[column].minX + metrics[column].width - offset > usable.width {
                offset = metrics[column].minX + metrics[column].width - usable.width
            }
            offset = Self.clampViewportOffset(
                offset,
                viewportWidth: usable.width,
                contentWidth: contentWidth,
                allowsEdgeMargin: centered == focused
            )
        }
        var result: [WindowToken: CGRect] = [:]
        for (index, column) in columns.enumerated() {
            let gap = max(0, gaps.inner)
            let totalGap = gap * CGFloat(max(0, column.windows.count - 1))
            let heights = Self.distributedLengths(
                total: max(0, usable.height - totalGap),
                minimums: column.windows.map { minimumSizes[$0]?.height ?? 1 },
                weights: column.windows.map { rowFractions[$0] ?? 1 }
            )
            var y = usable.minY
            for (row, window) in column.windows.enumerated() {
                let minX = (usable.minX + metrics[index].minX - offset).rounded()
                let maxX = (usable.minX + metrics[index].minX + metrics[index].width - offset).rounded()
                let minY = y.rounded()
                let maxY = (y + heights[row]).rounded()
                result[window] = CGRect(
                    x: minX,
                    y: minY,
                    width: max(1, maxX - minX),
                    height: max(1, maxY - minY)
                )
                y += heights[row] + gap
            }
        }
        return result
    }

    private func columnIndex(containing window: WindowToken) -> Int? {
        columns.firstIndex { $0.windows.contains(window) }
    }

    private func position(of window: WindowToken) -> (column: Int, row: Int)? {
        guard let column = columnIndex(containing: window), let row = columns[column].windows.firstIndex(of: window) else { return nil }
        return (column, row)
    }

    private mutating func resetRowFractions(in column: Int) {
        guard columns.indices.contains(column), !columns[column].windows.isEmpty else { return }
        let fraction = 1 / CGFloat(columns[column].windows.count)
        for window in columns[column].windows { rowFractions[window] = fraction }
    }

    private func columnMetrics(
        viewportWidth: CGFloat,
        innerGap: CGFloat,
        minimumSizes: [WindowToken: CGSize]
    ) -> [(minX: CGFloat, width: CGFloat)] {
        var x: CGFloat = 0
        return columns.map { column in
            let minimum = column.windows.map { minimumSizes[$0]?.width ?? 1 }.max() ?? 1
            let width = max(floor(viewportWidth * column.width), minimum)
            defer { x += width + max(0, innerGap) }
            return (x, width)
        }
    }

    private static func distributedLengths(total: CGFloat, minimums: [CGFloat], weights: [CGFloat]) -> [CGFloat] {
        guard !minimums.isEmpty else { return [] }
        let required = minimums.map { max(1, $0) }
        let sum = required.reduce(0, +)
        if sum > total { return required }

        var result = Array(repeating: CGFloat.zero, count: required.count)
        var unresolved = Set(required.indices)
        var remaining = total
        while !unresolved.isEmpty {
            let totalWeight = unresolved.reduce(CGFloat.zero) { $0 + max(0.0001, weights[$1]) }
            let fixed = unresolved.filter {
                required[$0] > remaining * max(0.0001, weights[$0]) / totalWeight
            }
            if fixed.isEmpty {
                for index in unresolved {
                    result[index] = remaining * max(0.0001, weights[index]) / totalWeight
                }
                break
            }
            for index in fixed {
                result[index] = required[index]
                remaining -= required[index]
                unresolved.remove(index)
            }
        }
        return result
    }

    private static func clampViewportOffset(
        _ offset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        allowsEdgeMargin: Bool
    ) -> CGFloat {
        let minimum = allowsEdgeMargin ? -viewportWidth / 2 : 0
        let maximum = allowsEdgeMargin
            ? max(0, contentWidth - viewportWidth / 2)
            : max(0, contentWidth - viewportWidth)
        return min(max(minimum, offset), maximum)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
