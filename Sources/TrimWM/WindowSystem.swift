@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum WindowDisposition: Equatable, Sendable { case unmanaged, floating, tiled }

enum MouseSurfaceFilter {
    static func includes(layer: Int, alpha: Double, frame: CGRect) -> Bool {
        layer == 0 && alpha > 0 && frame.width > 0 && frame.height > 0
    }
}

enum WindowInventoryReconciler {
    static func stalePIDs(
        tracked: Set<WindowToken>,
        liveWindowIDs: Set<CGWindowID>
    ) -> Set<pid_t> {
        Set(tracked.lazy.filter { !liveWindowIDs.contains($0.id) }.map(\.pid))
    }
}

struct WindowClassificationInput: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let movable: Bool
    let resizable: Bool
    let minimized: Bool
    let nativeFullscreen: Bool
}

enum WindowClassifier {
    static func classify(_ value: WindowClassificationInput, title: String = "") -> WindowDisposition {
        guard !value.minimized, !value.nativeFullscreen, value.movable else { return .unmanaged }
        guard value.role == (kAXWindowRole as String) else { return .unmanaged }
        if value.subrole == (kAXStandardWindowSubrole as String) {
            if value.resizable { return .tiled }
            return title.isEmpty ? .unmanaged : .floating
        }
        if [
            kAXDialogSubrole as String,
            kAXSystemDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
        ].contains(value.subrole) {
            return .floating
        }
        return .unmanaged
    }
}

enum AXFrameWriteOrder: Equatable, Sendable { case sizeThenPosition, positionThenSize }

enum AXNotificationRoute: Equatable, Sendable { case frame, title, scan }

enum AXNotificationRouter {
    static func route(_ notification: String) -> AXNotificationRoute {
        if notification == kAXWindowMovedNotification || notification == kAXWindowResizedNotification { return .frame }
        if notification == kAXTitleChangedNotification { return .title }
        return .scan
    }
}

struct AXFrameWritePlan: Equatable, Sendable {
    let order: AXFrameWriteOrder
    let writesPosition: Bool
    let writesSize: Bool

    var reassertsPosition: Bool {
        order == .positionThenSize && writesPosition && writesSize
    }
}

struct AXFrameWriteResult: Equatable, Sendable {
    let observed: CGRect?
    let succeeded: Bool
}

/// How far a window may sit from its target and still count as placed. Only
/// rounding noise: a gap change can move a target by a few points, and
/// those few points must still be written.
enum FramePlacement {
    static let tolerance: CGFloat = 1
}

enum AXFrameWriter {
    static func order(current: CGRect?, target: CGRect) -> AXFrameWriteOrder {
        guard let current else { return .sizeThenPosition }
        return target.width > current.width + 0.5 || target.height > current.height + 0.5
            ? .positionThenSize
            : .sizeThenPosition
    }

    static func plan(current: CGRect?, target: CGRect, tolerance: CGFloat = FramePlacement.tolerance) -> AXFrameWritePlan {
        guard let current else {
            return AXFrameWritePlan(order: .sizeThenPosition, writesPosition: true, writesSize: true)
        }
        return AXFrameWritePlan(
            order: order(current: current, target: target),
            writesPosition: abs(current.minX - target.minX) > tolerance || abs(current.minY - target.minY) > tolerance,
            writesSize: abs(current.width - target.width) > tolerance || abs(current.height - target.height) > tolerance
        )
    }
}

struct AXScanGate: Equatable, Sendable {
    private(set) var isQueued = false
    private(set) var isRunning = false
    private var needsRescan = false

    mutating func request() -> Bool {
        guard !isQueued else {
            if isRunning { needsRescan = true }
            return false
        }
        isQueued = true
        return true
    }

    mutating func begin() { isRunning = true }

    mutating func finish() -> Bool {
        let result = needsRescan
        isQueued = false
        isRunning = false
        needsRescan = false
        return result
    }

    mutating func reset() { self = AXScanGate() }
}

/// Frame writes in quick succession share one AXEnhancedUserInterface check.
/// The first write of a burst turns enhanced UI off if the app had it on,
/// because apps animate and fight frame writes while it is on; the end of the
/// burst turns it back on for assistive technology.
struct EnhancedUIBurst: Equatable, Sendable {
    private(set) var isActive = false
    private(set) var isSuspended = false

    /// Whether the app's enhanced UI must be checked before this write.
    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func suspend() { isSuspended = true }

    /// Whether enhanced UI must be turned back on.
    mutating func end() -> Bool {
        defer { self = EnhancedUIBurst() }
        return isSuspended
    }
}

enum FrameWriteDecision: Equatable, Sendable {
    case none
    case write(CGRect)
    /// Writes the frame again after `FrameLedger.retryDelay`: apps that apply
    /// a frame on their own event loop still report the old one right after
    /// a write, which must not count as a refusal.
    case retry(CGRect)
    case refused(CGRect?)
}

enum FrameConstraintLearner {
    static func minimum(target: CGRect, observed: CGRect, tolerance: CGFloat = 4) -> CGSize? {
        let width = observed.width > target.width + tolerance ? observed.width : 1
        let height = observed.height > target.height + tolerance ? observed.height : 1
        return width > 1 || height > 1 ? CGSize(width: width, height: height) : nil
    }
}

struct FrameConstraintCache: Sendable {
    private var entries: [WindowToken: CGSize] = [:]

    func value(for window: WindowToken) -> CGSize? { entries[window] }

    mutating func reset() { entries.removeAll() }
    mutating func remove(_ window: WindowToken) { entries.removeValue(forKey: window) }

    mutating func learn(_ size: CGSize, for window: WindowToken) -> Bool {
        let old = entries[window] ?? CGSize(width: 1, height: 1)
        let updated = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
        entries[window] = updated
        return old != updated
    }

    /// Forgets a learned minimum the window has since been seen below.
    @discardableResult
    mutating func observed(_ size: CGSize, for window: WindowToken, tolerance: CGFloat = 4) -> Bool {
        guard let old = entries[window] else { return false }
        let updated = CGSize(
            width: size.width + tolerance < old.width ? 1 : old.width,
            height: size.height + tolerance < old.height ? 1 : old.height
        )
        entries[window] = updated
        return old != updated
    }
}

/// Minimum sizes apps refused to shrink below, by bundle ID, kept across
/// launches so a new window of a known app is laid out right the first time.
/// A refusal only becomes a minimum once another refusal with a clearly
/// different target lands on the same size: windows that snap to a grid, like
/// Terminal's, land near each target instead. A minimum is forgotten once a
/// window of the app is seen below it.
struct AppMinimumSizes {
    private struct Refusal: Codable, Equatable {
        var target: CGFloat
        var observed: CGFloat
    }

    private struct Entry: Codable, Equatable {
        var width: CGFloat = 1
        var height: CGFloat = 1
        var widthRefusal: Refusal?
        var heightRefusal: Refusal?
    }

    /// Files from 0.8.0 are unversioned and are not read: it confirmed sizes
    /// that windows still had because they had not applied a write yet.
    private struct Store: Codable {
        var version = AppMinimumSizes.version
        var apps: [String: Entry]
    }

    static let version = 2
    static let confirmationDistance: CGFloat = 32
    let url: URL?
    private var entries: [String: Entry] = [:]

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Store.self, from: data),
           decoded.version == Self.version {
            entries = decoded.apps
        }
    }

    func value(for bundleID: String) -> CGSize? {
        guard let entry = entries[bundleID], entry.width > 1 || entry.height > 1 else { return nil }
        return CGSize(width: entry.width, height: entry.height)
    }

    /// Returns whether a confirmed minimum grew.
    mutating func refused(target: CGRect, observed: CGRect, bundleID: String, tolerance: CGFloat = 4) -> Bool {
        var entry = entries[bundleID] ?? Entry()
        let widthGrew = Self.learn(
            target: target.width, observed: observed.width, tolerance: tolerance,
            refusal: &entry.widthRefusal, minimum: &entry.width
        )
        let heightGrew = Self.learn(
            target: target.height, observed: observed.height, tolerance: tolerance,
            refusal: &entry.heightRefusal, minimum: &entry.height
        )
        guard entries[bundleID] != entry else { return false }
        entries[bundleID] = entry
        save()
        return widthGrew || heightGrew
    }

    /// Forgets minimums and pending refusals a window of the app has been
    /// seen below. Returns whether a minimum was forgotten.
    @discardableResult
    mutating func observed(_ size: CGSize, bundleID: String, tolerance: CGFloat = 4) -> Bool {
        guard var entry = entries[bundleID] else { return false }
        let widthForgotten = Self.forget(below: size.width, tolerance: tolerance, refusal: &entry.widthRefusal, minimum: &entry.width)
        let heightForgotten = Self.forget(below: size.height, tolerance: tolerance, refusal: &entry.heightRefusal, minimum: &entry.height)
        guard entries[bundleID] != entry else { return false }
        entries[bundleID] = entry
        save()
        return widthForgotten || heightForgotten
    }

    private static func forget(
        below observed: CGFloat,
        tolerance: CGFloat,
        refusal: inout Refusal?,
        minimum: inout CGFloat
    ) -> Bool {
        if let pending = refusal, observed + tolerance < pending.observed { refusal = nil }
        guard observed + tolerance < minimum else { return false }
        minimum = 1
        return true
    }

    private static func learn(
        target: CGFloat,
        observed: CGFloat,
        tolerance: CGFloat,
        refusal: inout Refusal?,
        minimum: inout CGFloat
    ) -> Bool {
        guard observed > target + tolerance else { return false }
        guard let previous = refusal,
              abs(previous.observed - observed) <= 1,
              abs(previous.target - target) >= confirmationDistance
        else {
            refusal = Refusal(target: target, observed: observed)
            return false
        }
        refusal = nil
        guard observed > minimum else { return false }
        minimum = observed
        return true
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Store(apps: entries)).write(to: url, options: .atomic)
        } catch {}
    }
}

struct FrameLedger: Sendable {
    static let retryDelay: TimeInterval = 0.25

    private struct Entry: Sendable {
        var observed: CGRect?
        var desired: CGRect?
        var inFlight: CGRect?
        var retries = 0
        var target: CGRect?
        var wasAtTarget = false
        var overrides = 0
        var lastOverrideFrame: CGRect?
        var lastOverrideAt: TimeInterval?
        var suppressesOverrides = false
    }
    private var entries: [WindowToken: Entry] = [:]

    func isWritingFrame(for window: WindowToken) -> Bool {
        entries[window]?.inFlight != nil
    }

    mutating func needsWrite(_ frame: CGRect, for window: WindowToken, tolerance: CGFloat = FramePlacement.tolerance) -> Bool {
        var entry = entries[window] ?? Entry()
        if entry.target?.approximatelyEquals(frame, tolerance: tolerance) != true {
            entry.target = frame
            entry.wasAtTarget = entry.observed?.approximatelyEquals(frame, tolerance: tolerance) == true
            entry.overrides = 0
            entry.lastOverrideFrame = nil
            entry.lastOverrideAt = nil
            entry.suppressesOverrides = false
        }
        if entry.suppressesOverrides {
            entries[window] = entry
            return false
        }
        if entry.desired?.approximatelyEquals(frame, tolerance: tolerance) == true {
            return false
        }
        if entry.observed?.approximatelyEquals(frame, tolerance: tolerance) == true {
            entry.desired = nil
            entry.retries = 0
            entry.wasAtTarget = true
            entries[window] = entry
            return false
        }
        entry.desired = frame
        entry.retries = 0
        guard entry.inFlight == nil else {
            entries[window] = entry
            return false
        }
        entry.inFlight = frame
        entries[window] = entry
        return true
    }

    mutating func observed(
        _ frame: CGRect,
        for window: WindowToken,
        tolerance: CGFloat = FramePlacement.tolerance,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        var entry = entries[window] ?? Entry()
        entry.observed = frame
        if let target = entry.target {
            let isAtTarget = target.approximatelyEquals(frame, tolerance: tolerance)
            if entry.wasAtTarget, !isAtTarget {
                if let lastOverrideAt = entry.lastOverrideAt,
                   timestamp - lastOverrideAt <= 3,
                   entry.lastOverrideFrame?.approximatelyEquals(frame, tolerance: tolerance) == true {
                    entry.overrides += 1
                } else {
                    entry.overrides = 1
                }
                entry.lastOverrideFrame = frame
                entry.lastOverrideAt = timestamp
                if entry.overrides >= 2 {
                    entry.suppressesOverrides = true
                    entry.desired = nil
                    entry.retries = 0
                }
            }
            entry.wasAtTarget = isAtTarget
        }
        if entry.desired?.approximatelyEquals(frame, tolerance: tolerance) == true {
            entry.desired = nil
            entry.retries = 0
            entry.wasAtTarget = true
        }
        entries[window] = entry
    }

    mutating func completed(
        _ frame: CGRect,
        for window: WindowToken,
        result: AXFrameWriteResult,
        tolerance: CGFloat = FramePlacement.tolerance
    ) -> FrameWriteDecision {
        guard var entry = entries[window],
              entry.inFlight?.approximatelyEquals(frame, tolerance: tolerance) == true
        else { return .none }
        entry.inFlight = nil
        if let observed = result.observed {
            entry.observed = observed
            entry.wasAtTarget = entry.target?.approximatelyEquals(observed, tolerance: tolerance) == true
        }
        if let desired = entry.desired,
           !desired.approximatelyEquals(frame, tolerance: tolerance) {
            if entry.observed?.approximatelyEquals(desired, tolerance: tolerance) == true {
                entry.desired = nil
                entry.retries = 0
                entry.wasAtTarget = true
                entries[window] = entry
                return .none
            }
            entry.inFlight = desired
            entry.retries = 0
            entries[window] = entry
            return .write(desired)
        }
        guard entry.desired?.approximatelyEquals(frame, tolerance: tolerance) == true else {
            entries[window] = entry
            return .none
        }
        if result.succeeded || result.observed?.approximatelyEquals(frame, tolerance: tolerance) == true {
            entry.desired = nil
            entry.retries = 0
            entry.wasAtTarget = true
            entries[window] = entry
            return .none
        }
        if entry.retries == 0 {
            entry.retries = 1
            entry.inFlight = frame
            entries[window] = entry
            return .retry(frame)
        }
        entries[window] = entry
        return .refused(result.observed)
    }

    mutating func remove(_ window: WindowToken) { entries.removeValue(forKey: window) }
    mutating func reset() { entries.removeAll() }
}

final class AXWindowSnapshot: @unchecked Sendable {
    let token: WindowToken
    let bundleID: String
    var title: String
    var frame: CGRect
    let disposition: WindowDisposition
    let isFocused: Bool
    let isOnScreen: Bool
    let isOnCurrentSpace: Bool
    let minimumSize: CGSize
    fileprivate let element: AXUIElement

    init(
        token: WindowToken,
        bundleID: String,
        title: String,
        frame: CGRect,
        disposition: WindowDisposition,
        isFocused: Bool,
        isOnScreen: Bool,
        isOnCurrentSpace: Bool,
        minimumSize: CGSize,
        element: AXUIElement
    ) {
        self.token = token
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.disposition = disposition
        self.isFocused = isFocused
        self.isOnScreen = isOnScreen
        self.isOnCurrentSpace = isOnCurrentSpace
        self.minimumSize = minimumSize
        self.element = element
    }
}

private final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

private final class AXWindowIDResolver: @unchecked Sendable {
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let function: Function?

    init() {
        function = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
            .map { unsafeBitCast($0, to: Function.self) }
    }

    func id(for element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id: CGWindowID = 0
        return function(element, &id) == .success && id != 0 ? id : nil
    }
}

private func TrimWMObserverCallback(
    _: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<AXContext>.fromOpaque(refcon).takeUnretainedValue()
    switch AXNotificationRouter.route(notification as String) {
    case .frame: context.refreshFrame(element)
    case .title: context.refreshTitle(element)
    case .scan: context.scan()
    }
}

private final class AXContext: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String
    private let application: AXUIElement
    private let queue: DispatchQueue
    private let resolver = AXWindowIDResolver()
    private let skyLight: SkyLight
    private let onScan: @Sendable (pid_t, [AXWindowSnapshot]) -> Void
    private let onFrame: @Sendable (WindowToken, CGRect) -> Void
    private let onTitle: @Sendable (WindowToken, String) -> Void
    private let observesFrames: Bool
    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var observedWindows: Set<CGWindowID> = []
    private let stateLock = NSLock()
    private var stopped = false
    private var scanGate = AXScanGate()
    private var enhancedUI = EnhancedUIBurst()
    private var enhancedUIRestore: DispatchWorkItem?
    private static let enhancedUIKey = "AXEnhancedUserInterface" as CFString
    private static let enhancedUIRestoreDelay: DispatchTimeInterval = .seconds(1)

    init(
        pid: pid_t,
        bundleID: String,
        skyLight: SkyLight,
        observesFrames: Bool,
        onScan: @escaping @Sendable (pid_t, [AXWindowSnapshot]) -> Void,
        onFrame: @escaping @Sendable (WindowToken, CGRect) -> Void,
        onTitle: @escaping @Sendable (WindowToken, String) -> Void
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.skyLight = skyLight
        self.observesFrames = observesFrames
        self.onScan = onScan
        self.onFrame = onFrame
        self.onTitle = onTitle
        application = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "de.cornz.TrimWM.ax.\(pid)", qos: .userInteractive)
        AXUIElementSetMessagingTimeout(application, 0.5)
    }

    func start() {
        stateLock.withLock { stopped = false }
        var created: AXObserver?
        guard AXObserverCreate(pid, TrimWMObserverCallback, &created) == .success, let created else {
            scan()
            return
        }
        stateLock.withLock { observer = created }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, application, notification as CFString, refcon)
        }
        let source = AXObserverGetRunLoopSource(created)
        observerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        scan()
    }

    func stop(restoringEnhancedUI: Bool = true) {
        let suspended = stateLock.withLock {
            stopped = true
            scanGate.reset()
            observedWindows.removeAll()
            observer = nil
            return enhancedUI.isSuspended
        }
        if let observerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes) }
        observerSource = nil
        if suspended, restoringEnhancedUI { queue.sync { restoreEnhancedUI() } }
    }

    func scan() {
        let shouldSchedule = stateLock.withLock {
            guard !stopped else { return false }
            return scanGate.request()
        }
        guard shouldSchedule else { return }
        queue.async { [self] in
            guard stateLock.withLock({ () -> Bool in
                guard !stopped else { scanGate.reset(); return false }
                scanGate.begin()
                return true
            }) else { return }
            performScan()
            let again = stateLock.withLock { scanGate.finish() && !stopped }
            if again { scan() }
        }
    }

    func focusedWindow() -> WindowToken? {
        queue.sync {
            guard stateLock.withLock({ !stopped }),
                  let value = copy(application, kAXFocusedWindowAttribute as String),
                  CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let id = resolver.id(for: unsafeDowncast(value, to: AXUIElement.self))
            else { return nil }
            return WindowToken(pid: pid, id: id)
        }
    }

    func refreshFrame(_ element: AXUIElement) {
        let box = AXElementBox(element)
        queue.async { [self] in
            guard stateLock.withLock({ !stopped }),
                  let id = resolver.id(for: box.element),
                  let frame = Self.readFrame(box.element)
            else { return }
            onFrame(WindowToken(pid: pid, id: id), frame)
        }
    }

    func refreshTitle(_ element: AXUIElement) {
        let box = AXElementBox(element)
        queue.async { [self] in
            guard stateLock.withLock({ !stopped }), let id = resolver.id(for: box.element) else { return }
            onTitle(WindowToken(pid: pid, id: id), string(box.element, kAXTitleAttribute as String) ?? "")
        }
    }

    private func performScan() {
            guard let elements = elementArray(application, kAXWindowsAttribute as String) else { return }
            let onScreen = Self.onScreenWindowIDs()
            let currentSpace = skyLight.currentMainSpaceID()
            let focusedValue = copy(application, kAXFocusedWindowAttribute as String)
            let focusedID = focusedValue.flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID()
                    ? resolver.id(for: unsafeDowncast($0, to: AXUIElement.self))
                    : nil
            }
            var result: [AXWindowSnapshot] = []
            for element in elements {
                guard let id = resolver.id(for: element), let frame = frame(of: element) else { continue }
                let title = string(element, kAXTitleAttribute as String) ?? ""
                let input = WindowClassificationInput(
                    role: string(element, kAXRoleAttribute as String),
                    subrole: string(element, kAXSubroleAttribute as String),
                    movable: settable(element, kAXPositionAttribute as String),
                    resizable: settable(element, kAXSizeAttribute as String),
                    minimized: boolean(element, kAXMinimizedAttribute as String) ?? false,
                    nativeFullscreen: boolean(element, "AXFullScreen") ?? false
                )
                let disposition = WindowClassifier.classify(input, title: title)
                guard disposition != .unmanaged else { continue }
                let spaces = skyLight.windowSpaceIDs(id)
                let onCurrentSpace = currentSpace.flatMap { active in spaces.flatMap { $0.isEmpty ? nil : $0.contains(active) } }
                    ?? onScreen.contains(id)
                result.append(AXWindowSnapshot(
                    token: WindowToken(pid: pid, id: id),
                    bundleID: bundleID,
                    title: title,
                    frame: frame,
                    disposition: disposition,
                    isFocused: id == focusedID,
                    isOnScreen: onScreen.contains(id),
                    isOnCurrentSpace: onCurrentSpace,
                    minimumSize: size(element, "AXMinSize") ?? CGSize(width: 1, height: 1),
                    element: element
                ))
                observe(element, id: id)
            }
            let scannedIDs = Set(result.map { $0.token.id })
            stateLock.withLock { observedWindows.formIntersection(scannedIDs) }
            if stateLock.withLock({ !stopped }) { onScan(pid, result) }
    }

    func setFrame(
        _ frame: CGRect,
        currentFrameHint: CGRect?,
        for element: AXUIElement,
        completion: @escaping @Sendable (AXFrameWriteResult) -> Void
    ) {
        let box = AXElementBox(element)
        queue.async { [self] in completion(apply(frame, currentFrameHint: currentFrameHint, to: box.element)) }
    }

    func setFrameSync(_ frame: CGRect, currentFrameHint: CGRect?, for element: AXUIElement) -> Bool {
        let box = AXElementBox(element)
        return queue.sync { apply(frame, currentFrameHint: currentFrameHint, to: box.element).succeeded }
    }

    func focus(_ element: AXUIElement) {
        let box = AXElementBox(element)
        queue.async { [self] in
            AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, box.element)
            AXUIElementPerformAction(box.element, kAXRaiseAction as CFString)
        }
    }

    private func observe(_ element: AXUIElement, id: CGWindowID) {
        guard let observer = stateLock.withLock({ () -> AXObserver? in
            guard !stopped, observedWindows.insert(id).inserted else { return nil }
            return self.observer
        }) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notifications = [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXTitleChangedNotification,
        ]
        if observesFrames { notifications += [kAXWindowMovedNotification, kAXWindowResizedNotification] }
        for notification in notifications {
            AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
    }

    // Runs on `queue` before every frame write.
    private func suspendEnhancedUI() {
        if stateLock.withLock({ enhancedUI.begin() }),
           Self.readValue(application, Self.enhancedUIKey as String) as? Bool == true {
            AXUIElementSetAttributeValue(application, Self.enhancedUIKey, kCFBooleanFalse)
            stateLock.withLock { enhancedUI.suspend() }
        }
        enhancedUIRestore?.cancel()
        let restore = DispatchWorkItem { [weak self] in self?.restoreEnhancedUI() }
        enhancedUIRestore = restore
        queue.asyncAfter(deadline: .now() + Self.enhancedUIRestoreDelay, execute: restore)
    }

    // Runs on `queue`.
    private func restoreEnhancedUI() {
        enhancedUIRestore?.cancel()
        enhancedUIRestore = nil
        if stateLock.withLock({ enhancedUI.end() }) {
            AXUIElementSetAttributeValue(application, Self.enhancedUIKey, kCFBooleanTrue)
        }
    }

    private func apply(_ frame: CGRect, currentFrameHint: CGRect?, to element: AXUIElement) -> AXFrameWriteResult {
        suspendEnhancedUI()
        var size = frame.size, point = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &point) else {
            return AXFrameWriteResult(observed: Self.readFrame(element), succeeded: false)
        }
        let current = currentFrameHint ?? Self.readFrame(element)
        let plan = AXFrameWriter.plan(current: current, target: frame)
        var sizeError = AXError.success
        var positionError = AXError.success
        func setSize() {
            if plan.writesSize {
                sizeError = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            }
        }
        func setPosition() {
            if plan.writesPosition {
                positionError = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
            }
        }
        switch plan.order {
        case .sizeThenPosition:
            setSize()
            setPosition()
        case .positionThenSize:
            setPosition()
            setSize()
            if plan.reassertsPosition { setPosition() }
        }
        let observed: CGRect?
        if let current, plan.writesPosition, !plan.writesSize, let observedPosition = Self.readPosition(element) {
            observed = CGRect(origin: observedPosition, size: current.size)
        } else if let current, plan.writesSize, !plan.writesPosition, let observedSize = Self.readSize(element) {
            observed = CGRect(origin: current.origin, size: observedSize)
        } else if !plan.writesPosition, !plan.writesSize {
            observed = current
        } else {
            observed = Self.readFrame(element)
        }
        return AXFrameWriteResult(
            observed: observed,
            succeeded: sizeError == .success && positionError == .success
                && observed?.approximatelyEquals(frame, tolerance: FramePlacement.tolerance) == true
        )
    }

    private static func readFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = readPosition(element), let size = readSize(element) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func readPosition(_ element: AXUIElement) -> CGPoint? {
        guard let value = readValue(element, kAXPositionAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }

    private static func readSize(_ element: AXUIElement) -> CGSize? {
        guard let value = readValue(element, kAXSizeAttribute as String),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }

    private static func readValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func elementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success:
            return value as? [AXUIElement]
        case .noValue:
            return []
        default:
            return nil
        }
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? { copy(element, attribute) as? String }
    private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? { copy(element, attribute) as? Bool }

    private func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }

    private func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &value) == .success && value.boolValue
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute as String), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = copy(element, kAXSizeAttribute as String), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions)
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }
}

@MainActor
final class WindowSystem: NSObject {
    var onUpdate: ((pid_t, [AXWindowSnapshot]) -> Void)?
    var onFrame: ((WindowToken, CGRect) -> Void)?
    var onApplicationActivated: ((pid_t) -> Void)?
    var onReorder: (() -> Void)?
    var onTitle: ((WindowToken, String) -> Void)?
    private var contexts: [pid_t: AXContext] = [:]
    private var windows: [WindowToken: AXWindowSnapshot] = [:]
    private let skyLight = SkyLight()
    private var reconcileTimer: Timer?
    private var observesWindowEvents = false
    private var watchedWindows: [CGWindowID] = []
    private var cachedMouseSurfaces: [MouseSurface]?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static var mainScreenBounds: CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        let frame = screen.frame, visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: frame.maxY - visible.maxY, width: visible.width, height: visible.height).integral
    }

    static var displayBounds: [CGRect] { NSScreen.screens.map(\.frame) }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDeactivated), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observesWindowEvents = skyLight.startWindowEvents { [weak self] type, id in
            // SkyLight delivers on the main thread, from the AppKit event loop.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.windowEvent(type, id) }
            } else {
                Task { @MainActor [weak self] in self?.windowEvent(type, id) }
            }
        }
        for application in NSWorkspace.shared.runningApplications { add(application) }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(reconcileClosedWindows), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        if observesWindowEvents { skyLight.stopWindowEvents() }
        observesWindowEvents = false
        watchedWindows.removeAll()
        contexts.values.forEach { $0.stop() }
        contexts.removeAll()
        windows.removeAll()
        cachedMouseSurfaces = nil
    }

    func rescan() { contexts.values.forEach { $0.scan() } }

    func frontmostFocusedWindow() -> WindowToken? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let token = contexts[pid]?.focusedWindow(),
              windows[token] != nil
        else { return nil }
        return token
    }

    func setFrame(
        _ frame: CGRect,
        for token: WindowToken,
        completion: @escaping @Sendable (AXFrameWriteResult) -> Void
    ) {
        guard let window = windows[token], let context = contexts[token.pid] else {
            completion(AXFrameWriteResult(observed: nil, succeeded: false))
            return
        }
        context.setFrame(frame, currentFrameHint: window.frame, for: window.element, completion: completion)
    }

    func setFrameSync(_ frame: CGRect, for token: WindowToken) -> Bool {
        guard let window = windows[token], let context = contexts[token.pid] else { return false }
        return context.setFrameSync(frame, currentFrameHint: window.frame, for: window.element)
    }

    func focus(_ token: WindowToken) {
        guard let window = windows[token] else { return }
        NSRunningApplication(processIdentifier: token.pid)?.activate(options: [.activateAllWindows])
        skyLight.orderFront(token.id)
        contexts[token.pid]?.focus(window.element)
        cachedMouseSurfaces = nil
    }

    func contains(_ token: WindowToken, bundleID: String) -> Bool {
        windows[token]?.bundleID == bundleID
    }

    /// Fetched at most once per main-actor turn: one drain of events can lay
    /// out many times, and the window list is a WindowServer round trip.
    var mouseSurfaces: [MouseSurface] {
        if let cachedMouseSurfaces { return cachedMouseSurfaces }
        let surfaces = loadMouseSurfaces()
        cachedMouseSurfaces = surfaces
        Task { @MainActor [weak self] in self?.cachedMouseSurfaces = nil }
        return surfaces
    }

    private func loadMouseSurfaces() -> [MouseSurface] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { item in
            // TrimWM's own border sits at its target's level but never takes the mouse.
            guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  MouseSurfaceFilter.includes(
                    layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                    alpha: (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                    frame: frame
                  )
            else { return nil }
            let token = WindowToken(pid: pid, id: id)
            return MouseSurface(token: windows[token] == nil ? nil : token, frame: frame)
        }
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { add(application) }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = application.processIdentifier
        contexts.removeValue(forKey: pid)?.stop(restoringEnhancedUI: false)
        windows = windows.filter { $0.key.pid != pid }
        cachedMouseSurfaces = nil
        watchWindowEvents()
        onUpdate?(pid, [])
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onApplicationActivated?(application.processIdentifier)
        contexts[application.processIdentifier]?.scan()
    }

    @objc private func applicationDeactivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        contexts[application.processIdentifier]?.scan()
    }

    @objc private func activeSpaceChanged() { rescan() }
    @objc private func screenParametersChanged() { rescan() }

    @objc private func reconcileClosedWindows() {
        guard !windows.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return }
        let liveWindowIDs = Set(list.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
        let stalePIDs = WindowInventoryReconciler.stalePIDs(
            tracked: Set(windows.values.lazy.filter(\.isOnScreen).map(\.token)),
            liveWindowIDs: liveWindowIDs
        )
        for pid in stalePIDs { contexts[pid]?.scan() }
    }

    private func add(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular,
              contexts[pid] == nil,
              let bundleID = application.bundleIdentifier
        else { return }
        let context = AXContext(
            pid: pid,
            bundleID: bundleID,
            skyLight: skyLight,
            observesFrames: !observesWindowEvents,
            onScan: { [weak self] pid, scanned in
                Task { @MainActor [weak self] in self?.accept(pid: pid, scanned: scanned) }
            },
            onFrame: { [weak self] token, frame in
                Task { @MainActor [weak self] in self?.accept(frame: frame, for: token) }
            },
            onTitle: { [weak self] token, title in
                Task { @MainActor [weak self] in self?.accept(title: title, for: token) }
            }
        )
        contexts[pid] = context
        context.start()
    }

    private func accept(pid: pid_t, scanned: [AXWindowSnapshot]) {
        windows = windows.filter { $0.key.pid != pid }
        for window in scanned { windows[window.token] = window }
        cachedMouseSurfaces = nil
        watchWindowEvents()
        onUpdate?(pid, scanned)
    }

    private func watchWindowEvents() {
        guard observesWindowEvents else { return }
        let ids = windows.keys.map(\.id).sorted()
        guard ids != watchedWindows else { return }
        watchedWindows = ids
        skyLight.watchWindows(ids)
    }

    private func windowEvent(_ type: UInt32, _ id: CGWindowID) {
        if type == SkyLightEvent.windowReordered {
            cachedMouseSurfaces = nil
            onReorder?()
            return
        }
        guard let token = windows.keys.first(where: { $0.id == id }), let frame = skyLight.bounds(id) else { return }
        accept(frame: frame, for: token)
    }

    private func accept(frame: CGRect, for token: WindowToken) {
        guard let window = windows[token] else { return }
        window.frame = frame
        onFrame?(token, frame)
    }

    private func accept(title: String, for token: WindowToken) {
        guard let window = windows[token], window.title != title else { return }
        window.title = title
        onTitle?(token, title)
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
