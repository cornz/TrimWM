import CoreGraphics

enum Geometry {
    static func sideHiddenFrame(_ frame: CGRect, mainBounds: CGRect, displayBounds: [CGRect]) -> CGRect {
        let farthestLeft = displayBounds.map(\.minX).min() ?? mainBounds.minX
        let y = min(max(mainBounds.minY, frame.minY), max(mainBounds.minY, mainBounds.maxY - frame.height))
        // macOS rejects a window placed exactly outside the global screen edge,
        // but accepts the same placement with a one-point reveal.
        return CGRect(x: farthestLeft - frame.width + 1, y: y, width: frame.width, height: frame.height)
    }

    static func isMeaningfullyVisible(_ frame: CGRect, in bounds: CGRect) -> Bool {
        let intersection = frame.intersection(bounds)
        return !intersection.isNull && intersection.width > 1 && intersection.height > 1
    }

    static func shouldClearJournal(observed: CGRect, desired: CGRect?, bounds: CGRect) -> Bool {
        guard let desired, isMeaningfullyVisible(desired, in: bounds) else { return false }
        return isMeaningfullyVisible(observed, in: bounds)
    }

    static func shouldReconcileRestoredWindow(
        isManaged: Bool,
        hasJournalEntry: Bool,
        observed: CGRect,
        bounds: CGRect
    ) -> Bool {
        !isManaged && hasJournalEntry && isMeaningfullyVisible(observed, in: bounds)
    }

    static func nearest(
        from source: WindowToken,
        direction: Direction,
        frames: [WindowToken: CGRect]
    ) -> WindowToken? {
        guard let origin = frames[source] else { return nil }
        return frames.lazy
            .filter { $0.key != source && isCandidate($0.value.center, from: origin.center, direction: direction) }
            .min { score($0.value, origin, direction) < score($1.value, origin, direction) }?
            .key
    }

    private static func isCandidate(_ point: CGPoint, from origin: CGPoint, direction: Direction) -> Bool {
        switch direction {
        case .left: point.x < origin.x
        case .right: point.x > origin.x
        case .up: point.y < origin.y
        case .down: point.y > origin.y
        }
    }

    private static func score(_ candidate: CGRect, _ origin: CGRect, _ direction: Direction) -> CGFloat {
        let dx = abs(candidate.midX - origin.midX)
        let dy = abs(candidate.midY - origin.midY)
        let primary = direction == .left || direction == .right ? dx : dy
        let secondary = direction == .left || direction == .right ? dy : dx
        return primary + secondary * 2
    }
}
