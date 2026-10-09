import CoreGraphics
import Darwin
import Foundation

struct SkyLightCapabilities: Equatable, Sendable {
    let spaces: Bool
    let ordering: Bool
    let windowEvents: Bool
}

enum SkyLightEvent {
    static let windowMoved: UInt32 = 806
    static let windowResized: UInt32 = 807
    static let windowReordered: UInt32 = 808
    static let windowEvents = [windowMoved, windowResized, windowReordered]

    // Move, resize, and reorder notifications carry the window id as the first four bytes.
    static func windowID(_ data: UnsafeRawPointer?, length: Int) -> CGWindowID? {
        guard let data, length >= MemoryLayout<CGWindowID>.size else { return nil }
        let id = data.loadUnaligned(as: CGWindowID.self)
        return id == 0 ? nil : id
    }
}

private final class SkyLightWindowEventSink: @unchecked Sendable {
    static let shared = SkyLightWindowEventSink()
    private let lock = NSLock()
    private var handler: (@Sendable (UInt32, CGWindowID) -> Void)?

    func set(_ handler: (@Sendable (UInt32, CGWindowID) -> Void)?) { lock.withLock { self.handler = handler } }

    func deliver(_ type: UInt32, _ id: CGWindowID) { lock.withLock { handler }?(type, id) }
}

private func TrimWMSkyLightNotifyProc(
    _ type: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    context _: UnsafeMutableRawPointer?
) {
    guard let id = SkyLightEvent.windowID(data, length: length) else { return }
    SkyLightWindowEventSink.shared.deliver(type, id)
}

enum ManagedSpaceParser {
    static func mainSpaceID(in value: Any) -> UInt64? {
        guard let displays = value as? [[String: Any]] else { return nil }
        let display = displays.first { ($0["Display Identifier"] as? String) == "Main" } ?? displays.first
        guard let current = display?["Current Space"] as? [String: Any] else { return nil }
        return integer(current["id64"]) ?? integer(current["ManagedSpaceID"])
    }

    static func spaceIDs(in value: Any) -> Set<UInt64> {
        guard let values = value as? [Any] else { return [] }
        return Set(values.compactMap(integer))
    }

    private static func integer(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String { return UInt64(string) }
        return nil
    }
}

final class SkyLight: @unchecked Sendable {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopyManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias OrderWindow = @convention(c) (Int32, CGWindowID, Int32, CGWindowID) -> CGError
    typealias MoveWindow = @convention(c) (Int32, CGWindowID, UnsafePointer<CGPoint>) -> CGError
    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    typealias RegisterNotifyProc = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> CGError
    typealias RequestWindowNotifications = @convention(c) (Int32, UnsafePointer<CGWindowID>?, Int32) -> CGError
    typealias GetWindowBounds = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGRect>) -> CGError
    typealias QueryWindows = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    typealias QueryResultCopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias IteratorAdvance = @convention(c) (CFTypeRef) -> Bool
    typealias IteratorGetCornerRadii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    private let handle: UnsafeMutableRawPointer?
    private let mainConnection: MainConnection?
    private let copyManagedSpaces: CopyManagedSpaces?
    private let copyWindowSpaces: CopyWindowSpaces?
    private let orderWindow: OrderWindow?
    private let moveWindow: MoveWindow?
    private let registerNotifyProc: RegisterNotifyProc?
    private let removeNotifyProc: RegisterNotifyProc?
    private let requestWindowNotifications: RequestWindowNotifications?
    private let getWindowBounds: GetWindowBounds?
    private let queryWindows: QueryWindows?
    private let queryResultCopyWindows: QueryResultCopyWindows?
    private let iteratorAdvance: IteratorAdvance?
    private let iteratorGetCornerRadii: IteratorGetCornerRadii?
    let capabilities: SkyLightCapabilities

    init(path: String = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") {
        handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        mainConnection = Self.symbol("SLSMainConnectionID", handle: handle)
        copyManagedSpaces = Self.symbol("SLSCopyManagedDisplaySpaces", handle: handle)
        copyWindowSpaces = Self.symbol("SLSCopySpacesForWindows", handle: handle)
        orderWindow = Self.symbol("SLSOrderWindow", handle: handle)
        moveWindow = Self.symbol("SLSMoveWindow", handle: handle)
        registerNotifyProc = Self.symbol("SLSRegisterNotifyProc", handle: handle)
        removeNotifyProc = Self.symbol("SLSRemoveNotifyProc", handle: handle)
        requestWindowNotifications = Self.symbol("SLSRequestNotificationsForWindows", handle: handle)
        getWindowBounds = Self.symbol("SLSGetWindowBounds", handle: handle)
        queryWindows = Self.symbol("SLSWindowQueryWindows", handle: handle)
        queryResultCopyWindows = Self.symbol("SLSWindowQueryResultCopyWindows", handle: handle)
        iteratorAdvance = Self.symbol("SLSWindowIteratorAdvance", handle: handle)
        // macOS 26 and later.
        iteratorGetCornerRadii = Self.symbol("SLSWindowIteratorGetCornerRadii", handle: handle)
        capabilities = SkyLightCapabilities(
            spaces: mainConnection != nil && copyManagedSpaces != nil && copyWindowSpaces != nil,
            ordering: mainConnection != nil && orderWindow != nil,
            windowEvents: mainConnection != nil && registerNotifyProc != nil && removeNotifyProc != nil
                && requestWindowNotifications != nil && getWindowBounds != nil
        )
    }

    deinit { if let handle { dlclose(handle) } }

    func currentMainSpaceID() -> UInt64? {
        guard let mainConnection, let copyManagedSpaces,
              let array = copyManagedSpaces(mainConnection())?.takeRetainedValue()
        else { return nil }
        return ManagedSpaceParser.mainSpaceID(in: array as NSArray)
    }

    func windowSpaceIDs(_ window: CGWindowID) -> Set<UInt64>? {
        guard let mainConnection, let copyWindowSpaces else { return nil }
        let windows = [NSNumber(value: window)] as CFArray
        guard let array = copyWindowSpaces(mainConnection(), 0x7, windows)?.takeRetainedValue() else { return nil }
        return ManagedSpaceParser.spaceIDs(in: array as NSArray)
    }

    @discardableResult
    func orderFront(_ window: CGWindowID) -> Bool {
        guard let mainConnection, let orderWindow else { return false }
        return orderWindow(mainConnection(), window, 1, 0) == .success
    }

    func move(_ window: CGWindowID, to point: CGPoint) -> Bool {
        guard let mainConnection, let moveWindow else { return false }
        var point = point
        return moveWindow(mainConnection(), window, &point) == .success
    }

    /// Delivers move, resize, and reorder notifications of the windows passed
    /// to `watchWindows` on the main thread, straight from WindowServer, so a
    /// busy app cannot delay them.
    func startWindowEvents(_ handler: @escaping @Sendable (UInt32, CGWindowID) -> Void) -> Bool {
        guard capabilities.windowEvents, let registerNotifyProc else { return false }
        SkyLightWindowEventSink.shared.set(handler)
        for type in SkyLightEvent.windowEvents where registerNotifyProc(TrimWMSkyLightNotifyProc, type, nil) != .success {
            stopWindowEvents()
            return false
        }
        return true
    }

    func stopWindowEvents() {
        if let removeNotifyProc {
            for type in SkyLightEvent.windowEvents { _ = removeNotifyProc(TrimWMSkyLightNotifyProc, type, nil) }
        }
        SkyLightWindowEventSink.shared.set(nil)
    }

    /// Replaces the windows whose events are delivered.
    func watchWindows(_ windows: [CGWindowID]) {
        guard let mainConnection, let requestWindowNotifications else { return }
        _ = windows.withUnsafeBufferPointer { requestWindowNotifications(mainConnection(), $0.baseAddress, Int32($0.count)) }
    }

    /// Global top-left coordinates, the space Accessibility frames use.
    func bounds(_ window: CGWindowID) -> CGRect? {
        guard let mainConnection, let getWindowBounds else { return nil }
        var bounds = CGRect.zero
        return getWindowBounds(mainConnection(), window, &bounds) == .success ? bounds : nil
    }

    /// The radius WindowServer rounds the window's corners with.
    func cornerRadius(_ window: CGWindowID) -> CGFloat? {
        guard let mainConnection, let queryWindows, let queryResultCopyWindows, let iteratorAdvance,
              let iteratorGetCornerRadii,
              let query = queryWindows(mainConnection(), [NSNumber(value: window)] as CFArray, 1)?.takeRetainedValue(),
              let iterator = queryResultCopyWindows(query)?.takeRetainedValue(),
              iteratorAdvance(iterator),
              let radii = iteratorGetCornerRadii(iterator)?.takeRetainedValue() as? [NSNumber],
              let radius = radii.first
        else { return nil }
        return CGFloat(radius.doubleValue)
    }

    fileprivate static func symbol<T>(_ name: String, handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}

/// A ring drawn by `SkyLightBorder`: `width` points wide around a window of
/// `size`, its inner edge following the window's corners. It reaches
/// `overlap` points into the window to cover the rim macOS draws along every
/// window edge, so the ring meets the window's content without a seam.
struct BorderRing: Equatable, Sendable {
    var size: CGSize
    var width: CGFloat
    var overlap: CGFloat = 0
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    var outerSize: CGSize { CGSize(width: size.width + 2 * width, height: size.height + 2 * width) }

    func path() -> CGPath {
        let bounds = CGRect(origin: .zero, size: outerSize)
        let ring = CGMutablePath()
        let inset = width + overlap
        ring.addRoundedRect(in: bounds, radius: outerRadius)
        ring.addRoundedRect(in: bounds.insetBy(dx: inset, dy: inset), radius: max(0, innerRadius - overlap))
        return ring
    }
}

private extension CGMutablePath {
    // CGPath requires the corner radius to fit the rectangle.
    func addRoundedRect(in rect: CGRect, radius: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = max(0, min(radius, min(rect.width, rect.height) / 2))
        addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }
}

/// The focus border as a WindowServer window of TrimWM's own, kept directly
/// above its target at the target's level, the approach JankyBorders takes.
/// Windows above the target cover the border as they cover the target. Above
/// rather than below, the ring covers the target's own edge stroke instead of
/// showing it as a seam. The window ignores the mouse and has a transparent
/// interior. Main thread only.
final class SkyLightBorder {
    private final class API: @unchecked Sendable {
        typealias MainConnection = @convention(c) () -> Int32
        typealias NewRegionWithRect = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> CGError
        typealias NewWindow = @convention(c) (Int32, Int32, Float, Float, CFTypeRef, UnsafeMutablePointer<CGWindowID>) -> CGError
        typealias ReleaseWindow = @convention(c) (Int32, CGWindowID) -> CGError
        typealias SetWindowTags = @convention(c) (Int32, CGWindowID, UnsafePointer<UInt64>, Int32) -> CGError
        typealias SetWindowShape = @convention(c) (Int32, CGWindowID, Float, Float, CFTypeRef) -> CGError
        typealias SetWindowResolution = @convention(c) (Int32, CGWindowID, Double) -> CGError
        typealias SetWindowOpacity = @convention(c) (Int32, CGWindowID, Bool) -> CGError
        typealias SetShadowProperties = @convention(c) (CGWindowID, CFDictionary) -> CGError
        typealias GetWindowLevel = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int64>) -> CGError
        typealias GetWindowSubLevel = @convention(c) (Int32, CGWindowID) -> Int32
        typealias WindowContextCreate = @convention(c) (Int32, CGWindowID, CFDictionary?) -> Unmanaged<CGContext>?
        typealias FlushWindowContentRegion = @convention(c) (Int32, CGWindowID, UnsafeRawPointer?) -> CGError
        typealias ConnectionUpdate = @convention(c) (Int32) -> CGError
        typealias TransactionCreate = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        typealias TransactionMove = @convention(c) (CFTypeRef, CGWindowID, CGPoint) -> CGError
        typealias TransactionSetLevel = @convention(c) (CFTypeRef, CGWindowID, Int32) -> CGError
        typealias TransactionOrder = @convention(c) (CFTypeRef, CGWindowID, Int32, CGWindowID) -> CGError
        typealias TransactionCommit = @convention(c) (CFTypeRef, Int32) -> Void
        typealias MoveWindowsToSpace = @convention(c) (Int32, CFArray, UInt64) -> Void

        let mainConnection: MainConnection
        let newRegionWithRect: NewRegionWithRect
        let newWindow: NewWindow
        let releaseWindow: ReleaseWindow
        let setWindowTags: SetWindowTags
        let setWindowShape: SetWindowShape
        let setWindowResolution: SetWindowResolution
        let setWindowOpacity: SetWindowOpacity
        let setShadowProperties: SetShadowProperties
        let getWindowLevel: GetWindowLevel
        let getWindowSubLevel: GetWindowSubLevel?
        let windowContextCreate: WindowContextCreate
        let flushWindowContentRegion: FlushWindowContentRegion
        let disableUpdate: ConnectionUpdate
        let reenableUpdate: ConnectionUpdate
        let transactionCreate: TransactionCreate
        let transactionMove: TransactionMove
        let transactionSetLevel: TransactionSetLevel
        let transactionSetSubLevel: TransactionSetLevel?
        let transactionOrder: TransactionOrder
        let transactionCommit: TransactionCommit
        let moveWindowsToSpace: MoveWindowsToSpace?
        private let handle: UnsafeMutableRawPointer

        init?(path: String) {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
            func symbol<T>(_ name: String) -> T? {
                SkyLight.symbol(name, handle: handle) ?? SkyLight.symbol(name, handle: UnsafeMutableRawPointer(bitPattern: -2))
            }
            guard let mainConnection: MainConnection = symbol("SLSMainConnectionID"),
                  let newRegionWithRect: NewRegionWithRect = symbol("CGSNewRegionWithRect"),
                  let newWindow: NewWindow = symbol("SLSNewWindow"),
                  let releaseWindow: ReleaseWindow = symbol("SLSReleaseWindow"),
                  let setWindowTags: SetWindowTags = symbol("SLSSetWindowTags"),
                  let setWindowShape: SetWindowShape = symbol("SLSSetWindowShape"),
                  let setWindowResolution: SetWindowResolution = symbol("SLSSetWindowResolution"),
                  let setWindowOpacity: SetWindowOpacity = symbol("SLSSetWindowOpacity"),
                  let setShadowProperties: SetShadowProperties = symbol("SLSWindowSetShadowProperties"),
                  let getWindowLevel: GetWindowLevel = symbol("SLSGetWindowLevel"),
                  let windowContextCreate: WindowContextCreate = symbol("SLWindowContextCreate"),
                  let flushWindowContentRegion: FlushWindowContentRegion = symbol("SLSFlushWindowContentRegion"),
                  let disableUpdate: ConnectionUpdate = symbol("SLSDisableUpdate"),
                  let reenableUpdate: ConnectionUpdate = symbol("SLSReenableUpdate"),
                  let transactionCreate: TransactionCreate = symbol("SLSTransactionCreate"),
                  let transactionMove: TransactionMove = symbol("SLSTransactionMoveWindowWithGroup"),
                  let transactionSetLevel: TransactionSetLevel = symbol("SLSTransactionSetWindowLevel"),
                  let transactionOrder: TransactionOrder = symbol("SLSTransactionOrderWindow"),
                  let transactionCommit: TransactionCommit = symbol("SLSTransactionCommit")
            else {
                dlclose(handle)
                return nil
            }
            self.handle = handle
            self.mainConnection = mainConnection
            self.newRegionWithRect = newRegionWithRect
            self.newWindow = newWindow
            self.releaseWindow = releaseWindow
            self.setWindowTags = setWindowTags
            self.setWindowShape = setWindowShape
            self.setWindowResolution = setWindowResolution
            self.setWindowOpacity = setWindowOpacity
            self.setShadowProperties = setShadowProperties
            self.getWindowLevel = getWindowLevel
            getWindowSubLevel = symbol("SLSGetWindowSubLevel")
            self.windowContextCreate = windowContextCreate
            self.flushWindowContentRegion = flushWindowContentRegion
            self.disableUpdate = disableUpdate
            self.reenableUpdate = reenableUpdate
            self.transactionCreate = transactionCreate
            self.transactionMove = transactionMove
            self.transactionSetLevel = transactionSetLevel
            transactionSetSubLevel = symbol("SLSTransactionSetWindowSubLevel")
            self.transactionOrder = transactionOrder
            self.transactionCommit = transactionCommit
            moveWindowsToSpace = symbol("SLSMoveWindowsToManagedSpace")
        }

        deinit { dlclose(handle) }

        func region(_ rect: CGRect) -> CFTypeRef? {
            var rect = rect
            var region: Unmanaged<CFTypeRef>?
            guard newRegionWithRect(&rect, &region) == .success else { return nil }
            return region?.takeRetainedValue()
        }
    }

    private enum Order {
        static let out: Int32 = 0
        static let above: Int32 = 1
    }

    // Floating (bit 1) and ignoring the mouse (bit 9), as in JankyBorders.
    private static let tags: UInt64 = (1 << 1) | (1 << 9)
    private let api: API
    private var id: CGWindowID = 0
    private var scale: CGFloat = 0
    private var spaceID: UInt64?
    private var drawn: BorderRing?
    private var isShown = false

    init?(path: String = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") {
        guard let api = API(path: path) else { return nil }
        self.api = api
    }

    deinit { if id != 0 { _ = api.releaseWindow(api.mainConnection(), id) } }

    /// Draws `ring` around `frame`, the target's frame in global top-left
    /// coordinates, and orders it directly above `target`. Redraws only when
    /// the ring changes; a move just re-places it.
    func show(_ ring: BorderRing, around frame: CGRect, above target: CGWindowID, scale: CGFloat, spaceID: UInt64?) {
        if scale != self.scale { recreate(scale: scale) }
        guard id != 0 else { return }
        let connection = api.mainConnection()
        if let spaceID, spaceID != self.spaceID, let moveWindowsToSpace = api.moveWindowsToSpace {
            // The ring belongs to its target's Space and slides with it.
            moveWindowsToSpace(connection, [NSNumber(value: id)] as CFArray, spaceID)
            self.spaceID = spaceID
        }
        let origin = CGPoint(x: frame.minX - ring.width, y: frame.minY - ring.width)
        if ring == drawn {
            place(above: target, origin: origin, synchronous: false)
        } else {
            guard let shape = api.region(CGRect(origin: .zero, size: ring.outerSize)) else { return }
            // Hold screen updates so the reshaped, redrawn, and moved ring
            // appears at once instead of at its old origin for a frame.
            _ = api.disableUpdate(connection)
            _ = api.setWindowShape(connection, id, 0, 0, shape)
            draw(ring)
            place(above: target, origin: origin, synchronous: true)
            _ = api.reenableUpdate(connection)
            drawn = ring
        }
        isShown = true
    }

    func hide() {
        guard isShown, let transaction = api.transactionCreate(api.mainConnection())?.takeRetainedValue() else { return }
        _ = api.transactionOrder(transaction, id, Order.out, 0)
        api.transactionCommit(transaction, 0)
        isShown = false
    }

    // The resolution is fixed at creation; a display with another scale gets a new window.
    private func recreate(scale: CGFloat) {
        let connection = api.mainConnection()
        if id != 0 { _ = api.releaseWindow(connection, id) }
        id = 0
        drawn = nil
        spaceID = nil
        isShown = false
        self.scale = scale
        guard let region = api.region(CGRect(x: 0, y: 0, width: 1, height: 1)) else { return }
        var created: CGWindowID = 0
        guard api.newWindow(connection, 2, -9999, -9999, region, &created) == .success, created != 0 else { return }
        var tags = Self.tags
        _ = api.setWindowResolution(connection, created, Double(scale))
        _ = api.setWindowTags(connection, created, &tags, 64)
        _ = api.setWindowOpacity(connection, created, false)
        _ = api.setShadowProperties(created, ["com.apple.WindowShadowDensity": 0] as CFDictionary)
        id = created
    }

    // The context is scaled to the window's resolution, so the ring is drawn in points.
    private func draw(_ ring: BorderRing) {
        let connection = api.mainConnection()
        guard let context = api.windowContextCreate(connection, id, nil)?.takeRetainedValue() else { return }
        context.clear(CGRect(origin: .zero, size: ring.outerSize))
        context.setFillColor(red: ring.red, green: ring.green, blue: ring.blue, alpha: ring.alpha)
        context.addPath(ring.path())
        context.fillPath(using: .evenOdd)
        context.flush()
        _ = api.flushWindowContentRegion(connection, id, nil)
    }

    // Moves the ring, copies the target's level and sub-level, and orders it
    // directly above the target, in one transaction.
    private func place(above target: CGWindowID, origin: CGPoint, synchronous: Bool) {
        let connection = api.mainConnection()
        var level: Int64 = 0
        _ = api.getWindowLevel(connection, target, &level)
        guard let transaction = api.transactionCreate(connection)?.takeRetainedValue() else { return }
        _ = api.transactionMove(transaction, id, origin)
        _ = api.transactionSetLevel(transaction, id, Int32(clamping: level))
        if let getWindowSubLevel = api.getWindowSubLevel, let setSubLevel = api.transactionSetSubLevel {
            _ = setSubLevel(transaction, id, getWindowSubLevel(connection, target))
        }
        _ = api.transactionOrder(transaction, id, Order.above, target)
        api.transactionCommit(transaction, synchronous ? 1 : 0)
    }
}
