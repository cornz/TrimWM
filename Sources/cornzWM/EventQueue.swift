import Darwin
import Foundation

enum WMEvent: Sendable {
    case windows(pid_t, [AXWindowSnapshot])
    case frameObserved(WindowToken, CGRect)
    case command(WMCommand)
    case mouse(WindowToken)
    case frameWriteResult(WindowToken, CGRect, AXFrameWriteResult)
}

struct EventBuffer {
    private(set) var events: [WMEvent] = []

    mutating func insert(_ event: WMEvent) {
        switch event {
        case let .windows(pid, _):
            if let index = events.lastIndex(where: { if case let .windows(existing, _) = $0 { existing == pid } else { false } }) {
                events[index] = event
            } else { events.append(event) }
        case .mouse:
            if let index = events.lastIndex(where: { if case .mouse = $0 { true } else { false } }) {
                events[index] = event
            } else { events.append(event) }
        case let .frameObserved(window, _):
            if let index = events.lastIndex(where: {
                if case let .frameObserved(existing, _) = $0 { existing == window } else { false }
            }) {
                events[index] = event
            } else { events.append(event) }
        case .command, .frameWriteResult:
            events.append(event)
        }
    }

    mutating func takeAll() -> [WMEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

final class EventQueue: @unchecked Sendable {
    var onDrain: (@MainActor @Sendable ([WMEvent]) -> Void)?
    private let lock = NSLock()
    private var buffer = EventBuffer()
    private var scheduled = false

    func push(_ event: WMEvent) {
        let shouldSchedule = lock.withLock {
            buffer.insert(event)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in self?.drain() }
    }

    @MainActor
    private func drain() {
        let events = lock.withLock {
            scheduled = false
            return buffer.takeAll()
        }
        if !events.isEmpty { onDrain?(events) }
    }
}
