import CoreGraphics
import Foundation

enum ToggleValue: String, Equatable, Sendable { case toggle, enable, disable }

enum WMCommand: Equatable, Sendable {
    case focus(Direction), focusNext, move(Direction)
    case resize(Direction, CGFloat)
    case workspace(Int), moveToWorkspace(Int, follow: Bool)
    case layout(LayoutMode), split(SplitAxis), balance
    case consume(Direction), expel(Direction), centerColumn, setColumnWidth(CGFloat)
    case floating(ToggleValue), fullscreen
    case mode(String), reload, execute(String), nop
}

struct Binding: Equatable, Sendable {
    let chord: String
    let command: WMCommand
}

struct AppRule: Equatable, Sendable {
    let bundleID: String
    var workspace: Int?
    var floating: Bool?
}

enum BorderColor: Equatable, Sendable {
    case accent
    case rgba(UInt8, UInt8, UInt8, UInt8)
}

struct BorderStyle: Equatable, Sendable {
    var color: BorderColor = .accent
    var width: CGFloat = 2
    var radius: CGFloat = 9
}

struct WMConfig: Equatable, Sendable {
    var workspaceCount = 10
    var gaps = LayoutGaps()
    var splitRatio: CGFloat = 1.0
    var focusFollowsMouse = true
    var startAtLogin = true
    var border = BorderStyle()
    var bindings: [String: [Binding]] = ["default": []]
    var rules: [AppRule] = []
}

enum ConfigValidationError: Error, Equatable, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case let .message(value): value } }
}

enum ConfigValidator {
    static func validate(_ config: WMConfig) throws {
        guard config.workspaceCount == 10 else {
            throw ConfigValidationError.message("workspace-count must be 10")
        }
        for rule in config.rules {
            if let workspace = rule.workspace, !(1...config.workspaceCount).contains(workspace) {
                throw ConfigValidationError.message("workspace \(workspace) for \(rule.bundleID) is out of range")
            }
        }
        for (mode, bindings) in config.bindings {
            var chords: Set<String> = []
            for binding in bindings {
                let plan = try HotKeyPlanner.plan(binding)
                let chord = "\(plan.modifiers):\(plan.keyCode)"
                guard chords.insert(chord).inserted else {
                    throw ConfigValidationError.message("duplicate binding \(binding.chord) in mode \(mode)")
                }
                switch binding.command {
                case let .workspace(index), let .moveToWorkspace(index, _):
                    guard (1...config.workspaceCount).contains(index) else {
                        throw ConfigValidationError.message("workspace \(index) in binding \(binding.chord) is out of range")
                    }
                case let .mode(name):
                    guard config.bindings[name] != nil else {
                        throw ConfigValidationError.message("binding \(binding.chord) references missing mode \(name)")
                    }
                default: break
                }
            }
        }
    }
}

enum ConfigError: Error, Equatable, CustomStringConvertible {
    case line(Int, String)

    var description: String {
        switch self { case let .line(number, message): "line \(number): \(message)" }
    }
}

enum ConfigParser {
    static func parse(_ source: String) throws -> WMConfig {
        var config = WMConfig()
        var variables: [String: String] = [:]
        var mode = "default"

        for (offset, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            var line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.filter({ $0 == "\"" }).count.isMultiple(of: 2) else {
                throw ConfigError.line(number, "unterminated quote")
            }
            for key in variables.keys.sorted(by: { $0.count > $1.count }) {
                line = line.replacingOccurrences(of: key, with: variables[key]!)
            }
            if line == "}" {
                guard mode != "default" else { throw ConfigError.line(number, "unexpected }") }
                mode = "default"
                continue
            }
            if line.hasPrefix("mode "), line.hasSuffix("{") {
                guard mode == "default" else { throw ConfigError.line(number, "nested modes are unsupported") }
                let name = line.dropFirst(5).dropLast().trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name != "default" else { throw ConfigError.line(number, "invalid mode name") }
                mode = name
                config.bindings[name, default: []] = []
                continue
            }

            let fields = words(line)
            guard let directive = fields.first else { continue }
            switch directive {
            case "set":
                guard fields.count >= 3, fields[1].hasPrefix("$") else { throw ConfigError.line(number, "expected set $name value") }
                variables[fields[1]] = fields.dropFirst(2).joined(separator: " ")
            case "workspace-count":
                guard fields.count == 2, let count = Int(fields[1]), count > 0 else { throw ConfigError.line(number, "invalid workspace count") }
                config.workspaceCount = count
            case "gaps":
                guard fields.count == 3, let value = Double(fields[2]), value.isFinite, value >= 0 else { throw ConfigError.line(number, "invalid gaps") }
                if fields[1] == "inner" { config.gaps.inner = value }
                else if fields[1] == "outer" { config.gaps.outer = value }
                else { throw ConfigError.line(number, "gaps must be inner or outer") }
            case "autotile":
                guard fields.count == 3, fields[1] == "split-ratio", let value = Double(fields[2]), value.isFinite, value > 0 else { throw ConfigError.line(number, "invalid split ratio") }
                config.splitRatio = value
            case "focus-follows-mouse":
                config.focusFollowsMouse = try boolean(fields, line: number)
            case "start-at-login":
                config.startAtLogin = try boolean(fields, line: number)
            case "border":
                guard fields.count == 3 else { throw ConfigError.line(number, "expected border color, width, or radius") }
                switch fields[1] {
                case "color":
                    config.border.color = try borderColor(fields[2], line: number)
                case "width":
                    guard let value = Double(fields[2]), value.isFinite, value >= 0 else {
                        throw ConfigError.line(number, "invalid border width")
                    }
                    config.border.width = value
                case "radius":
                    guard let value = Double(fields[2]), value.isFinite, value >= 0 else {
                        throw ConfigError.line(number, "invalid border radius")
                    }
                    config.border.radius = value
                default:
                    throw ConfigError.line(number, "border must configure color, width, or radius")
                }
            case "bindsym":
                guard fields.count >= 3 else { throw ConfigError.line(number, "binding needs chord and command") }
                let commandText = fields.dropFirst(2).joined(separator: " ")
                config.bindings[mode, default: []].append(Binding(chord: fields[1], command: try parseCommand(commandText, line: number)))
            case "assign":
                let bundle = try bundleID(in: line, line: number)
                guard let workspaceWord = fields.last, let workspace = Int(workspaceWord), line.contains("] workspace ") else { throw ConfigError.line(number, "invalid assignment") }
                mergeRule(bundle, into: &config.rules) { $0.workspace = workspace }
            case "for_window":
                let bundle = try bundleID(in: line, line: number)
                guard let value = fields.last, value == "enable" || value == "disable", line.contains("] floating ") else { throw ConfigError.line(number, "invalid floating rule") }
                mergeRule(bundle, into: &config.rules) { $0.floating = value == "enable" }
            default:
                throw ConfigError.line(number, "unsupported directive \(directive)")
            }
        }
        guard mode == "default" else { throw ConfigError.line(source.split(separator: "\n", omittingEmptySubsequences: false).count, "unterminated mode") }
        return config
    }

    static func parseCommand(_ text: String, line: Int = 1) throws -> WMCommand {
        let fields = words(text)
        guard let name = fields.first else { throw ConfigError.line(line, "command missing") }
        func direction(_ index: Int = 1) throws -> Direction {
            guard fields.indices.contains(index), let value = Direction(rawValue: fields[index]) else { throw ConfigError.line(line, "direction missing") }
            return value
        }
        switch name {
        case "focus": guard fields.count == 2 else { throw ConfigError.line(line, "invalid focus") }; return fields[1] == "next" ? .focusNext : .focus(try direction())
        case "move": guard fields.count == 2 else { throw ConfigError.line(line, "invalid move") }; return .move(try direction())
        case "resize":
            guard fields.count == 3, let amount = Double(fields[2]) else { throw ConfigError.line(line, "invalid resize") }
            return .resize(try direction(), amount)
        case "workspace": guard fields.count == 2, let value = Int(fields[1]) else { throw ConfigError.line(line, "invalid workspace") }; return .workspace(value)
        case "move-to-workspace": guard fields.count == 2 || (fields.count == 3 && fields[2] == "follow"), let value = Int(fields[1]) else { throw ConfigError.line(line, "invalid target workspace") }; return .moveToWorkspace(value, follow: fields.count == 3)
        case "layout": guard fields.count == 2, let value = LayoutMode(rawValue: fields[1]) else { throw ConfigError.line(line, "invalid layout") }; return .layout(value)
        case "split": guard fields.count == 2, let value = SplitAxis(rawValue: fields[1]) else { throw ConfigError.line(line, "invalid split") }; return .split(value)
        case "balance-sizes": guard fields.count == 1 else { throw ConfigError.line(line, "invalid balance-sizes") }; return .balance
        case "consume": guard fields.count == 2 else { throw ConfigError.line(line, "invalid consume") }; let value = try direction(); guard value == .left || value == .right else { throw ConfigError.line(line, "consume direction must be left or right") }; return .consume(value)
        case "expel": guard fields.count == 2 else { throw ConfigError.line(line, "invalid expel") }; let value = try direction(); guard value == .left || value == .right else { throw ConfigError.line(line, "expel direction must be left or right") }; return .expel(value)
        case "center-column": guard fields.count == 1 else { throw ConfigError.line(line, "invalid center-column") }; return .centerColumn
        case "set-column-width":
            guard fields.count == 2, let raw = Double(fields[1]), raw.isFinite else { throw ConfigError.line(line, "invalid column width") }
            let value = raw > 1 ? raw / 100 : raw
            guard [0.25, 0.5, 0.75, 1].contains(value) else { throw ConfigError.line(line, "column width must be 25, 50, 75, or 100 percent") }
            return .setColumnWidth(value)
        case "floating": guard fields.count == 2, let value = ToggleValue(rawValue: fields[1]) else { throw ConfigError.line(line, "invalid floating value") }; return .floating(value)
        case "fullscreen": guard fields.count == 1 else { throw ConfigError.line(line, "invalid fullscreen") }; return .fullscreen
        case "mode": guard fields.count == 2 else { throw ConfigError.line(line, "mode missing") }; return .mode(fields[1])
        case "reload": guard fields.count == 1 else { throw ConfigError.line(line, "invalid reload") }; return .reload
        case "exec", "launch": guard fields.count > 1 else { throw ConfigError.line(line, "command missing") }; return .execute(fields.dropFirst().joined(separator: " "))
        case "nop": guard fields.count == 1 else { throw ConfigError.line(line, "invalid nop") }; return .nop
        default: throw ConfigError.line(line, "unsupported command \(name)")
        }
    }

    private static func boolean(_ fields: [String], line: Int) throws -> Bool {
        guard fields.count == 2, fields[1] == "true" || fields[1] == "false" else { throw ConfigError.line(line, "expected true or false") }
        return fields[1] == "true"
    }

    private static func borderColor(_ raw: String, line: Int) throws -> BorderColor {
        if raw.caseInsensitiveCompare("accent") == .orderedSame { return .accent }
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        else if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        guard (hex.count == 6 || hex.count == 8), let value = UInt32(hex, radix: 16) else {
            throw ConfigError.line(line, "border color must be accent, RRGGBB, or RRGGBBAA")
        }
        let alpha: UInt8 = hex.count == 8 ? UInt8(value & 0xff) : 0xff
        let rgb = hex.count == 8 ? value >> 8 : value
        return .rgba(UInt8(rgb >> 16), UInt8((rgb >> 8) & 0xff), UInt8(rgb & 0xff), alpha)
    }

    private static func bundleID(in line: String, line number: Int) throws -> String {
        guard let start = line.range(of: "[app_id=\"")?.upperBound,
              let end = line[start...].firstIndex(of: "\"")
        else { throw ConfigError.line(number, "exact app_id selector required") }
        let value = String(line[start..<end])
        guard !value.isEmpty else { throw ConfigError.line(number, "app_id cannot be empty") }
        return value
    }

    private static func mergeRule(_ bundle: String, into rules: inout [AppRule], update: (inout AppRule) -> Void) {
        let index = rules.firstIndex { $0.bundleID.caseInsensitiveCompare(bundle) == .orderedSame } ?? rules.endIndex
        if index == rules.endIndex { rules.append(AppRule(bundleID: bundle)); update(&rules[rules.count - 1]) }
        else { update(&rules[index]) }
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == "#" && !quoted { return String(line[..<index]) }
        }
        return line
    }

    private static func words(_ line: String) -> [String] {
        var result: [String] = [], word = "", quoted = false
        for character in line {
            if character == "\"" { quoted.toggle(); continue }
            if character.isWhitespace && !quoted {
                if !word.isEmpty { result.append(word); word = "" }
            } else { word.append(character) }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
