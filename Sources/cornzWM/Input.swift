@preconcurrency import Carbon
import CoreGraphics
import Foundation

enum HotKeyError: Error, Equatable { case invalidChord(String), unsupportedKey(String), carbon(OSStatus) }

struct HotKeyPlan: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let command: WMCommand
}

enum HotKeyPlanner {
    static func plan(_ binding: Binding) throws -> HotKeyPlan {
        let parts = binding.chord.split(separator: "+").map { $0.lowercased() }
        guard let key = parts.last, !key.isEmpty else { throw HotKeyError.invalidChord(binding.chord) }
        var modifiers: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            default: throw HotKeyError.invalidChord(binding.chord)
            }
        }
        guard let code = keyCodes[String(key)] else { throw HotKeyError.unsupportedKey(String(key)) }
        return HotKeyPlan(keyCode: code, modifiers: modifiers, command: binding.command)
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9), ";": UInt32(kVK_ANSI_Semicolon),
        "comma": UInt32(kVK_ANSI_Comma), "period": UInt32(kVK_ANSI_Period),
        "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return), "escape": UInt32(kVK_Escape), "space": UInt32(kVK_Space),
    ]
}

private func cornzWMHotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: id), nil, &id)
    guard status == noErr else { return status }
    Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().fire(id.id)
    return noErr
}

final class HotKeyManager: @unchecked Sendable {
    var onCommand: (@Sendable (WMCommand) -> Void)?
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var commands: [UInt32: WMCommand] = [:]
    private var plans: [HotKeyPlan] = []
    private var handlerStatus: OSStatus = noErr

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerStatus = InstallEventHandler(GetApplicationEventTarget(), cornzWMHotKeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        references.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ bindings: [Binding]) throws {
        guard handlerStatus == noErr, handler != nil else { throw HotKeyError.carbon(handlerStatus) }
        let requested = try bindings.map(HotKeyPlanner.plan)
        guard requested != plans else { return }
        let previous = plans
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        commands.removeAll()
        do {
            let installed = try install(requested)
            references = installed.0
            commands = installed.1
            plans = requested
        } catch {
            if let restored = try? install(previous) {
                references = restored.0
                commands = restored.1
                plans = previous
            }
            throw error
        }
    }

    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        commands.removeAll()
        plans.removeAll()
    }

    private func install(_ plans: [HotKeyPlan]) throws -> ([EventHotKeyRef], [UInt32: WMCommand]) {
        var newReferences: [EventHotKeyRef] = []
        var newCommands: [UInt32: WMCommand] = [:]
        for (offset, plan) in plans.enumerated() {
            let id = UInt32(offset + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(plan.keyCode, plan.modifiers, EventHotKeyID(signature: 0x43575A32, id: id), GetApplicationEventTarget(), 0, &reference)
            guard status == noErr, let reference else {
                newReferences.forEach { UnregisterEventHotKey($0) }
                throw HotKeyError.carbon(status)
            }
            newReferences.append(reference)
            newCommands[id] = plan.command
        }
        return (newReferences, newCommands)
    }

    fileprivate func fire(_ id: UInt32) {
        if let command = commands[id] { onCommand?(command) }
    }
}

private func cornzWMMouseCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MouseFocusMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenable()
        return Unmanaged.passUnretained(event)
    }
    return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

struct MouseTargetState {
    private var surfaces: [MouseSurface] = []
    private var columnDraggable: Set<WindowToken> = []
    private var last: WindowToken?

    mutating func update(
        _ values: [WindowToken: CGRect],
        frontToBack: [MouseSurface],
        columnDraggable: Set<WindowToken> = []
    ) {
        let ordered = frontToBack.compactMap { surface -> MouseSurface? in
            guard let token = surface.token else { return surface }
            return values[token].map { MouseSurface(token: token, frame: $0) }
        }
        let known = Set(frontToBack.compactMap(\.token))
        surfaces = ordered + values
            .filter { !known.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { MouseSurface(token: $0.key, frame: $0.value) }
        self.columnDraggable = columnDraggable
    }

    mutating func moved(to point: CGPoint) -> WindowToken? {
        let candidate = target(at: point)
        guard candidate != last else { return nil }
        last = candidate
        return candidate
    }

    func target(at point: CGPoint) -> WindowToken? {
        surfaces.first(where: { $0.frame.contains(point) })?.token
    }

    func frame(of window: WindowToken) -> CGRect? {
        surfaces.first(where: { $0.token == window })?.frame
    }

    func columnDragTarget(at point: CGPoint) -> WindowToken? {
        target(at: point).flatMap { columnDraggable.contains($0) ? $0 : nil }
    }

    mutating func reset() {
        surfaces.removeAll()
        columnDraggable.removeAll()
        last = nil
    }
}

struct MouseResizeStep: Equatable, Sendable {
    let direction: Direction
    let pixels: CGFloat
}

enum MouseResizePlanner {
    static func step(for delta: CGPoint) -> MouseResizeStep? {
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return nil }
        if abs(delta.x) >= abs(delta.y) {
            return MouseResizeStep(direction: delta.x < 0 ? .left : .right, pixels: delta.x)
        }
        return MouseResizeStep(direction: delta.y < 0 ? .up : .down, pixels: delta.y)
    }
}

enum MouseColumnDragPlanner {
    static func crossedMidpoint(source: CGRect, target: CGRect, pointer: CGPoint) -> Bool {
        if target.midX > source.midX { return pointer.x >= target.midX }
        if target.midX < source.midX { return pointer.x <= target.midX }
        return false
    }
}

struct MouseSurface: Equatable, Sendable {
    let token: WindowToken?
    let frame: CGRect
}

final class MouseFocusMonitor: @unchecked Sendable {
    var onWindow: (@Sendable (WindowToken) -> Void)?
    var onResize: (@Sendable (WindowToken, Direction, CGFloat) -> Void)?
    var onColumnMove: (@Sendable (WindowToken, WindowToken) -> Void)?
    private let lock = NSLock()
    private var state = MouseTargetState()
    private var resize: (window: WindowToken, point: CGPoint)?
    private var columnDrag: (window: WindowToken, lastTarget: WindowToken?)?
    private var focusesOnMove = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    @discardableResult
    func start(focusesOnMove: Bool) -> Bool {
        lock.withLock { self.focusesOnMove = focusesOnMove }
        guard tap == nil else { return true }
        let events = [
            CGEventType.mouseMoved,
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        ]
            .reduce(CGEventMask()) { $0 | CGEventMask(1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: events, callback: cornzWMMouseCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        lock.withLock { state.reset(); resize = nil; columnDrag = nil }
    }

    func update(
        _ frames: [WindowToken: CGRect],
        frontToBack: [MouseSurface],
        columnDraggable: Set<WindowToken> = []
    ) {
        lock.withLock {
            state.update(frames, frontToBack: frontToBack, columnDraggable: columnDraggable)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved:
            let target = lock.withLock { focusesOnMove ? state.moved(to: event.location) : nil }
            if let target { onWindow?(target) }
            return false
        case .leftMouseDown:
            guard event.flags.contains(.maskAlternate) else { return false }
            let target = lock.withLock { () -> WindowToken? in
                guard let target = state.columnDragTarget(at: event.location) else { return nil }
                columnDrag = (target, nil)
                return target
            }
            if let target { onWindow?(target) }
            return target != nil
        case .leftMouseDragged:
            let move = lock.withLock { () -> (WindowToken, WindowToken)? in
                guard var active = columnDrag,
                      let target = state.columnDragTarget(at: event.location)
                else { return nil }
                guard target != active.window else {
                    active.lastTarget = nil
                    columnDrag = active
                    return nil
                }
                guard target != active.lastTarget,
                      let sourceFrame = state.frame(of: active.window),
                      let targetFrame = state.frame(of: target),
                      MouseColumnDragPlanner.crossedMidpoint(
                        source: sourceFrame,
                        target: targetFrame,
                        pointer: event.location
                      )
                else { return nil }
                active.lastTarget = target
                columnDrag = active
                return (active.window, target)
            }
            if let (window, target) = move { onColumnMove?(window, target) }
            return lock.withLock { columnDrag != nil }
        case .leftMouseUp:
            return lock.withLock {
                let wasDragging = columnDrag != nil
                columnDrag = nil
                return wasDragging
            }
        case .rightMouseDown:
            guard event.flags.contains(.maskAlternate) else { return false }
            let target = lock.withLock { () -> WindowToken? in
                guard let target = state.target(at: event.location) else { return nil }
                resize = (target, event.location)
                return target
            }
            if let target { onWindow?(target) }
            return target != nil
        case .rightMouseDragged:
            let update = lock.withLock { () -> (WindowToken, MouseResizeStep)? in
                guard let active = resize else { return nil }
                let delta = CGPoint(x: event.location.x - active.point.x, y: event.location.y - active.point.y)
                resize = (active.window, event.location)
                return MouseResizePlanner.step(for: delta).map { (active.window, $0) }
            }
            if let (window, step) = update { onResize?(window, step.direction, step.pixels) }
            return update != nil
        case .rightMouseUp:
            return lock.withLock {
                let wasResizing = resize != nil
                resize = nil
                return wasResizing
            }
        default:
            return false
        }
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
