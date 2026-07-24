import XCTest
import ServiceManagement
@testable import cornzWM

final class ConfigTests: XCTestCase {
    func testXCTestHostNeverStartsWindowManagerRuntime() {
        XCTAssertTrue(RuntimeEnvironment.shouldStartWindowManager([:]))
        XCTAssertFalse(RuntimeEnvironment.shouldStartWindowManager(["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        XCTAssertFalse(RuntimeEnvironment.shouldStartWindowManager(["XCTestBundlePath": "/tmp/cornzWMTests.xctest"]))
        XCTAssertFalse(RuntimeEnvironment.shouldStartWindowManager(["XCInjectBundleInto": "/tmp/cornzWM"]))
    }

    func testLoginItemPlannerHandlesNotFoundWithoutFalseUnregister() {
        XCTAssertEqual(LoginItemPlanner.action(startAtLogin: false, status: .notFound), .none)
        XCTAssertEqual(LoginItemPlanner.action(startAtLogin: false, status: .notRegistered), .none)
        XCTAssertEqual(LoginItemPlanner.action(startAtLogin: false, status: .enabled), .unregister)
        XCTAssertEqual(LoginItemPlanner.action(startAtLogin: true, status: .notFound), .register)
        XCTAssertEqual(LoginItemPlanner.action(startAtLogin: true, status: .notRegistered), .register)
        XCTAssertEqual(LoginItemPlanner.action(startAtLogin: true, status: .requiresApproval), .none)
    }

    func testParsesSupportedConfigurationAndMergesRules() throws {
        let config = try ConfigParser.parse("""
        set $mod alt
        workspace-count 10
        gaps inner 4
        gaps outer 8
        autotile split-ratio 1.1
        focus-follows-mouse true
        start-at-login false
        border color 0x3366CC80
        border width 3
        border radius 12
        bindsym $mod+j focus left
        mode resize {
            bindsym h resize left -50
            bindsym escape mode default
        }
        assign [app_id="com.apple.Safari"] workspace 1
        for_window [app_id="com.apple.Safari"] floating disable
        """)
        XCTAssertEqual(config.gaps, .init(inner: 4, outer: 8))
        XCTAssertEqual(config.splitRatio, 1.1)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertEqual(config.border, BorderStyle(color: .rgba(0x33, 0x66, 0xcc, 0x80), width: 3, radius: 12))
        XCTAssertEqual(config.bindings["default"]?.first, Binding(chord: "alt+j", command: .focus(.left)))
        XCTAssertEqual(config.bindings["resize"]?.count, 2)
        XCTAssertEqual(config.rules, [AppRule(bundleID: "com.apple.Safari", workspace: 1, floating: false)])
    }

    func testCommentInsideQuotedExecIsNotStripped() throws {
        let config = try ConfigParser.parse("bindsym alt+x exec echo \"#keep\" # remove")
        XCTAssertEqual(config.bindings["default"]?.first?.command, .execute("echo #keep"))
    }

    func testParsesAllCommandFamilies() throws {
        let cases: [(String, WMCommand)] = [
            ("focus next", .focusNext), ("move right", .move(.right)), ("resize up -50", .resize(.up, -50)),
            ("workspace 10", .workspace(10)), ("move-to-workspace 2 follow", .moveToWorkspace(2, follow: true)),
            ("layout niri", .layout(.niri)), ("split vertical", .split(.vertical)), ("balance-sizes", .balance),
            ("consume left", .consume(.left)), ("expel right", .expel(.right)), ("center-column", .centerColumn),
            ("set-column-width 75", .setColumnWidth(0.75)), ("floating toggle", .floating(.toggle)),
            ("fullscreen", .fullscreen), ("mode resize", .mode("resize")), ("reload", .reload),
            ("launch open -a Warp", .execute("open -a Warp")), ("nop", .nop),
        ]
        for (source, expected) in cases { XCTAssertEqual(try ConfigParser.parseCommand(source), expected, source) }
    }

    func testRejectsUnknownDirectiveWithLineNumber() {
        XCTAssertThrowsError(try ConfigParser.parse("gaps inner 2\nmagic on")) { error in
            XCTAssertEqual(error as? ConfigError, .line(2, "unsupported directive magic"))
        }
    }

    func testRejectsUnterminatedMode() {
        XCTAssertThrowsError(try ConfigParser.parse("mode resize {\nbindsym h resize left -50"))
    }

    @MainActor
    func testBuiltInConfigurationParsesAndAllChordsAreRegisterable() throws {
        let config = try ConfigParser.parse(WMController.defaultConfig)
        try ConfigValidator.validate(config)
        for bindings in config.bindings.values {
            for binding in bindings { _ = try HotKeyPlanner.plan(binding) }
        }
        XCTAssertEqual(config.workspaceCount, 10)
        XCTAssertTrue(config.focusFollowsMouse)
        XCTAssertEqual(config.border, BorderStyle(color: .accent, width: 2, radius: 9))
    }

    func testValidationRejectsDuplicateChordsMissingModesAndOutOfRangeWorkspaces() throws {
        var duplicate = try ConfigParser.parse("bindsym alt+j focus left\nbindsym ALT+J focus right")
        XCTAssertThrowsError(try ConfigValidator.validate(duplicate))

        duplicate = try ConfigParser.parse("bindsym alt+r mode resize")
        XCTAssertThrowsError(try ConfigValidator.validate(duplicate))

        duplicate = try ConfigParser.parse("workspace-count 2\nbindsym alt+3 workspace 3")
        XCTAssertThrowsError(try ConfigValidator.validate(duplicate))

        duplicate = try ConfigParser.parse("bindsym alt+j focus left\nbindsym option+j focus right")
        XCTAssertThrowsError(try ConfigValidator.validate(duplicate))

        XCTAssertThrowsError(try ConfigValidator.validate(try ConfigParser.parse("workspace-count 9")))
    }

    func testRejectsMalformedModesQuotesAndCommandArguments() {
        for source in [
            "}",
            "mode resize {\nmode nested {\n}",
            "bindsym alt+x exec echo \"unterminated",
            "bindsym alt+x move-to-workspace 2 later",
            "bindsym alt+x consume up",
            "bindsym alt+x set-column-width 33",
            "bindsym alt+x fullscreen now",
            "bindsym alt+x exec",
            "border color blue",
            "border color 0x12345",
            "border width -1",
            "border radius nan",
            "border opacity 1",
        ] {
            XCTAssertThrowsError(try ConfigParser.parse(source), source)
        }
    }

    func testBorderColorsAcceptAccentRGBAndRGBA() throws {
        XCTAssertEqual(try ConfigParser.parse("border color accent").border.color, .accent)
        XCTAssertEqual(try ConfigParser.parse("border color A1B2C3").border.color, .rgba(0xa1, 0xb2, 0xc3, 0xff))
        XCTAssertEqual(try ConfigParser.parse("border color \"#01020304\"").border.color, .rgba(1, 2, 3, 4))
    }

    func testRuleMergingUsesCaseInsensitiveExactBundleIDs() throws {
        let config = try ConfigParser.parse("""
        assign [app_id="COM.APP"] workspace 2
        for_window [app_id="com.app"] floating enable
        """)
        XCTAssertEqual(config.rules, [AppRule(bundleID: "COM.APP", workspace: 2, floating: true)])
    }
}
