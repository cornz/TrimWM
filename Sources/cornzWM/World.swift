import CoreGraphics

enum WorkspaceLayout: Equatable, Sendable {
    case autotile(BSPLayout)
    case niri(NiriLayout)

    var mode: LayoutMode {
        switch self { case .autotile: .autotile; case .niri: .niri }
    }

    var windows: [WindowToken] {
        switch self { case let .autotile(layout): layout.windows; case let .niri(layout): layout.windows }
    }

    var focused: WindowToken? {
        switch self { case let .autotile(layout): layout.focused; case let .niri(layout): layout.focused }
    }

    mutating func insert(
        _ window: WindowToken,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        switch self {
        case var .autotile(layout):
            layout.insert(window, in: bounds, gaps: gaps, splitRatio: splitRatio)
            self = .autotile(layout)
        case var .niri(layout):
            layout.insert(window)
            layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            self = .niri(layout)
        }
    }

    mutating func remove(_ window: WindowToken) {
        switch self {
        case var .autotile(layout): layout.remove(window); self = .autotile(layout)
        case var .niri(layout): layout.remove(window); self = .niri(layout)
        }
    }

    mutating func focus(_ window: WindowToken) {
        switch self {
        case var .autotile(layout): layout.focus(window); self = .autotile(layout)
        case var .niri(layout): layout.focus(window); self = .niri(layout)
        }
    }

    mutating func focus(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        switch self {
        case var .autotile(layout):
            layout.focus(direction, in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            self = .autotile(layout)
        case var .niri(layout):
            layout.focus(direction)
            layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            self = .niri(layout)
        }
    }

    mutating func move(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        switch self {
        case var .autotile(layout):
            layout.move(direction, in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            self = .autotile(layout)
        case var .niri(layout):
            let before = layout
            layout.move(direction)
            if layout != before {
                layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            }
            self = .niri(layout)
        }
    }

    func frames(
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) -> [WindowToken: CGRect] {
        switch self {
        case let .autotile(layout): layout.frames(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        case let .niri(layout): layout.frames(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        }
    }
}

struct WorkspaceState: Equatable, Sendable {
    var layout: WorkspaceLayout = .autotile(BSPLayout())
    var floating: [WindowToken: CGRect] = [:]
    var focused: WindowToken?
    var fullscreen: WindowToken?

    var windows: [WindowToken] { layout.windows + floating.keys.sorted() }

    mutating func add(
        _ window: WindowToken,
        floating frame: CGRect?,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        if let frame { floating[window] = frame }
        else { layout.insert(window, bounds: bounds, gaps: gaps, splitRatio: splitRatio, minimumSizes: minimumSizes) }
        focused = window
    }

    mutating func remove(_ window: WindowToken) {
        layout.remove(window)
        floating.removeValue(forKey: window)
        if focused == window { focused = layout.focused ?? floating.keys.sorted().last }
        if fullscreen == window { fullscreen = nil }
    }

    mutating func setFocus(
        _ window: WindowToken,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard windows.contains(window) else { return }
        let changed = focused != window
        focused = window
        guard layout.windows.contains(window) else { return }
        layout.focus(window)
        if changed, case var .niri(niri) = layout {
            niri.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            layout = .niri(niri)
        }
    }

    mutating func focus(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        if let focused,
           case var .niri(niri) = layout,
           niri.windows.contains(focused) {
            let previous = niri.focused
            niri.focus(direction)
            guard niri.focused != previous else { return }
            niri.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            layout = .niri(niri)
            self.focused = niri.focused
            return
        }
        guard let focused,
              let next = Geometry.nearest(
                from: focused,
                direction: direction,
                frames: frames(bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
              )
        else { return }
        setFocus(next, bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
    }

    mutating func toggleFloating(
        _ window: WindowToken,
        currentFrame: CGRect,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        if floating.removeValue(forKey: window) != nil {
            layout.insert(window, bounds: bounds, gaps: gaps, splitRatio: splitRatio, minimumSizes: minimumSizes)
        } else if layout.windows.contains(window) {
            layout.remove(window)
            floating[window] = currentFrame
        }
        focused = window
    }

    mutating func changeLayout(
        to mode: LayoutMode,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard layout.mode != mode else { return }
        let order = layout.windows
        if mode == .niri {
            var converted = NiriLayout()
            for window in order { converted.insert(window) }
            layout = .niri(converted)
        } else {
            var converted = BSPLayout()
            for window in order { converted.insert(window, in: bounds, gaps: gaps, splitRatio: splitRatio) }
            layout = .autotile(converted)
        }
        if let focused { layout.focus(focused) }
        if case var .niri(converted) = layout {
            converted.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            layout = .niri(converted)
        }
    }

    func frames(
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) -> [WindowToken: CGRect] {
        if let fullscreen, windows.contains(fullscreen) {
            return [fullscreen: bounds]
        }
        var result = layout.frames(bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
        result.merge(floating) { _, floating in floating }
        return result
    }
}

struct World: Equatable, Sendable {
    private(set) var workspaces: [WorkspaceState]
    private(set) var visibleWorkspace = 1

    init(workspaceCount: Int = 10) {
        workspaces = Array(repeating: WorkspaceState(), count: max(1, workspaceCount))
    }

    var visible: WorkspaceState { workspaces[visibleWorkspace - 1] }

    var statusText: String {
        workspaces.enumerated().compactMap { index, workspace in
            let number = index + 1
            guard number == visibleWorkspace || !workspace.windows.isEmpty else { return nil }
            let layout = workspace.layout.mode == .autotile ? "A" : "N"
            let fullscreen = workspace.fullscreen == nil ? "" : "F"
            let label = "\(number)\(layout)\(fullscreen)"
            return number == visibleWorkspace ? "[\(label)]" : label
        }.joined(separator: " ")
    }

    func workspace(of window: WindowToken) -> Int? {
        workspaces.firstIndex { $0.windows.contains(window) }.map { $0 + 1 }
    }

    mutating func add(
        _ window: WindowToken,
        to workspace: Int,
        floating frame: CGRect? = nil,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard workspaces.indices.contains(workspace - 1), self.workspace(of: window) == nil else { return }
        workspaces[workspace - 1].add(
            window,
            floating: frame,
            bounds: bounds,
            gaps: gaps,
            splitRatio: splitRatio,
            minimumSizes: minimumSizes
        )
    }

    mutating func remove(_ window: WindowToken) {
        guard let workspace = workspace(of: window) else { return }
        workspaces[workspace - 1].remove(window)
    }

    mutating func switchWorkspace(to workspace: Int) {
        if workspaces.indices.contains(workspace - 1) { visibleWorkspace = workspace }
    }

    mutating func move(
        _ window: WindowToken,
        to target: Int,
        follow: Bool,
        currentFrame: CGRect,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let source = workspace(of: window), workspaces.indices.contains(target - 1), source != target else {
            if follow { switchWorkspace(to: target) }
            return
        }
        let wasFloating = workspaces[source - 1].floating[window] != nil
        workspaces[source - 1].remove(window)
        workspaces[target - 1].add(
            window,
            floating: wasFloating ? currentFrame : nil,
            bounds: bounds,
            gaps: gaps,
            splitRatio: splitRatio,
            minimumSizes: minimumSizes
        )
        if follow { visibleWorkspace = target }
    }

    mutating func changeVisibleLayout(
        to mode: LayoutMode,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        workspaces[visibleWorkspace - 1].changeLayout(
            to: mode,
            bounds: bounds,
            gaps: gaps,
            splitRatio: splitRatio,
            minimumSizes: minimumSizes
        )
    }

    func visibleFrames(
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) -> [WindowToken: CGRect] {
        visible.frames(bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
    }

    mutating func focus(
        _ window: WindowToken,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let workspace = workspace(of: window) else { return }
        visibleWorkspace = workspace
        workspaces[workspace - 1].setFocus(window, bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
    }

    mutating func focusIfVisible(
        _ window: WindowToken,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard workspace(of: window) == visibleWorkspace else { return }
        workspaces[visibleWorkspace - 1].setFocus(
            window,
            bounds: bounds,
            gaps: gaps,
            minimumSizes: minimumSizes
        )
    }

    mutating func focus(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        var workspace = workspaces[visibleWorkspace - 1]
        workspace.focus(direction, bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
        workspaces[visibleWorkspace - 1] = workspace
    }

    mutating func focusNext(
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        let workspace = workspaces[visibleWorkspace - 1]
        let order = workspace.windows
        guard !order.isEmpty else { return }
        let index = workspace.focused.flatMap { order.firstIndex(of: $0) } ?? -1
        workspaces[visibleWorkspace - 1].setFocus(
            order[(index + 1) % order.count],
            bounds: bounds,
            gaps: gaps,
            minimumSizes: minimumSizes
        )
    }

    mutating func moveFocused(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        var workspace = workspaces[visibleWorkspace - 1]
        if let focused = workspace.focused, var frame = workspace.floating[focused] {
            let distance: CGFloat = 50
            switch direction {
            case .left: frame.origin.x -= distance
            case .right: frame.origin.x += distance
            case .up: frame.origin.y -= distance
            case .down: frame.origin.y += distance
            }
            workspace.floating[focused] = frame
        } else {
            workspace.layout.move(direction, bounds: bounds, gaps: gaps, minimumSizes: minimumSizes)
        }
        workspaces[visibleWorkspace - 1] = workspace
    }

    mutating func moveTiledItem(
        containing window: WindowToken,
        to target: WindowToken,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        var workspace = workspaces[visibleWorkspace - 1]
        guard workspace.windows.contains(window),
              workspace.windows.contains(target)
        else { return }
        workspace.focused = window
        switch workspace.layout {
        case var .autotile(layout):
            layout.swap(window, with: target)
            workspace.layout = .autotile(layout)
        case var .niri(layout):
            layout.focus(window)
            layout.swapColumn(containing: window, with: target)
            layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
            workspace.layout = .niri(layout)
        }
        workspaces[visibleWorkspace - 1] = workspace
    }

    mutating func resizeFocused(_ direction: Direction, pixels: CGFloat, bounds: CGRect) {
        var workspace = workspaces[visibleWorkspace - 1]
        if let focused = workspace.focused, var frame = workspace.floating[focused] {
            if direction == .left || direction == .right { frame.size.width = max(100, frame.width + pixels) }
            else { frame.size.height = max(100, frame.height + pixels) }
            workspace.floating[focused] = frame
            workspaces[visibleWorkspace - 1] = workspace
            return
        }
        switch workspace.layout {
        case var .autotile(layout):
            let horizontal = direction == .left || direction == .right
            let dimension = horizontal ? bounds.width : bounds.height
            layout.resize(axis: horizontal ? .horizontal : .vertical, delta: dimension > 0 ? pixels / dimension : 0)
            workspace.layout = .autotile(layout)
        case var .niri(layout):
            if direction == .left || direction == .right {
                layout.resizeFocused(by: pixels, viewportWidth: bounds.width)
            } else {
                layout.resizeFocusedVertically(direction, by: pixels, viewportHeight: bounds.height)
            }
            workspace.layout = .niri(layout)
        }
        workspaces[visibleWorkspace - 1] = workspace
    }

    mutating func setNextSplit(_ axis: SplitAxis) {
        guard case var .autotile(layout) = workspaces[visibleWorkspace - 1].layout else { return }
        layout.nextSplit = axis
        workspaces[visibleWorkspace - 1].layout = .autotile(layout)
    }

    mutating func balanceVisible() {
        guard case var .autotile(layout) = workspaces[visibleWorkspace - 1].layout else { return }
        layout.balance()
        workspaces[visibleWorkspace - 1].layout = .autotile(layout)
    }

    mutating func reflowVisibleToFit(
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize]
    ) {
        guard case var .autotile(layout) = workspaces[visibleWorkspace - 1].layout,
              layout.reflowToFit(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        else { return }
        workspaces[visibleWorkspace - 1].layout = .autotile(layout)
    }

    mutating func consume(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard case var .niri(layout) = workspaces[visibleWorkspace - 1].layout else { return }
        let before = layout
        layout.consume(direction)
        if layout != before {
            layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        }
        workspaces[visibleWorkspace - 1].layout = .niri(layout)
    }

    mutating func expel(
        _ direction: Direction,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard case var .niri(layout) = workspaces[visibleWorkspace - 1].layout else { return }
        let before = layout
        layout.expel(direction)
        if layout != before {
            layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        }
        workspaces[visibleWorkspace - 1].layout = .niri(layout)
    }

    mutating func centerColumn(
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard case var .niri(layout) = workspaces[visibleWorkspace - 1].layout else { return }
        layout.centerFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        workspaces[visibleWorkspace - 1].layout = .niri(layout)
    }

    mutating func setColumnWidth(
        _ width: CGFloat,
        bounds: CGRect,
        gaps: LayoutGaps,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard case var .niri(layout) = workspaces[visibleWorkspace - 1].layout else { return }
        let before = layout
        layout.setFocusedWidth(width)
        if layout != before {
            layout.revealFocused(in: bounds, gaps: gaps, minimumSizes: minimumSizes)
        }
        workspaces[visibleWorkspace - 1].layout = .niri(layout)
    }

    mutating func toggleFloating(
        _ window: WindowToken,
        frame: CGRect,
        bounds: CGRect,
        gaps: LayoutGaps,
        splitRatio: CGFloat,
        minimumSizes: [WindowToken: CGSize] = [:]
    ) {
        guard let workspace = workspace(of: window) else { return }
        workspaces[workspace - 1].toggleFloating(
            window,
            currentFrame: frame,
            bounds: bounds,
            gaps: gaps,
            splitRatio: splitRatio,
            minimumSizes: minimumSizes
        )
    }

    mutating func setFullscreen(_ window: WindowToken, enabled: Bool) {
        guard let workspace = workspace(of: window) else { return }
        workspaces[workspace - 1].fullscreen = enabled ? window : nil
    }
}
