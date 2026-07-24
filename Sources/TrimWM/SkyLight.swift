import CoreGraphics
import Darwin
import Foundation

struct SkyLightCapabilities: Equatable, Sendable {
    let spaces: Bool
    let ordering: Bool
    let eventNotifications: Bool
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

    private let handle: UnsafeMutableRawPointer?
    private let mainConnection: MainConnection?
    private let copyManagedSpaces: CopyManagedSpaces?
    private let copyWindowSpaces: CopyWindowSpaces?
    private let orderWindow: OrderWindow?
    private let moveWindow: MoveWindow?
    let capabilities: SkyLightCapabilities

    init(path: String = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") {
        handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        mainConnection = Self.symbol("SLSMainConnectionID", handle: handle)
        copyManagedSpaces = Self.symbol("SLSCopyManagedDisplaySpaces", handle: handle)
        copyWindowSpaces = Self.symbol("SLSCopySpacesForWindows", handle: handle)
        orderWindow = Self.symbol("SLSOrderWindow", handle: handle)
        moveWindow = Self.symbol("SLSMoveWindow", handle: handle)
        capabilities = SkyLightCapabilities(
            spaces: mainConnection != nil && copyManagedSpaces != nil && copyWindowSpaces != nil,
            ordering: mainConnection != nil && orderWindow != nil,
            eventNotifications: handle.flatMap { dlsym($0, "SLSRegisterConnectionNotifyProc") } != nil
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

    private static func symbol<T>(_ name: String, handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
