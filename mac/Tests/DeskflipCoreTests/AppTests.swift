import XCTest
@testable import DeskflipCore

final class AppTests: XCTestCase {
    private var store: FakeStore!
    private var lock: FakeLock!
    private var locator: FakeLocator!
    private var tools: FakeTools!
    private var clock: FakeClock!
    private var keyboard: FakeFollower!
    private var mouse: FakeFollower!
    private var output: [String] = []

    override func setUp() {
        store = FakeStore()
        store.config = TestData.configText
        lock = FakeLock()
        locator = FakeLocator()
        keyboard = locator.add(TestData.keyboard)
        mouse = locator.add(TestData.mouse)
        tools = FakeTools()
        clock = FakeClock()
        output = []
    }

    private func run(_ arguments: String...) -> Int32 {
        App(store: store, lock: lock, locator: locator, tools: tools, clock: clock, processId: 42) { [unowned self] in
            self.output.append($0)
        }.run(arguments)
    }

    private func lastReport() throws -> RunReport {
        try JSONDecoder().decode(RunReport.self, from: Data(XCTUnwrap(store.lastResult).utf8))
    }
    private var sends: Int { keyboard.sends.count + mouse.sends.count }

    func testButtonSwitchesMonitorOnceThenKeyboardThenMouse() throws {
        tools.onSwitch = { [unowned self] in XCTAssertEqual(self.sends, 0, "monitor before devices") }
        XCTAssertEqual(run(), ExitCodes.success)
        XCTAssertEqual(tools.switchCalls, [["display", TestData.displayId, "set", "input", "5"]])
        XCTAssertEqual(tools.calls.last?.0, "/opt/homebrew/bin/m1ddc")
        XCTAssertEqual(locator.sendOrder, ["keyboard", "mouse"])
        let report = try lastReport()
        XCTAssertEqual(report.outcome, "Completed")
        XCTAssertEqual(report.monitor, MonitorRecord(attempted: true, accepted: true, exitStatus: 0))
        XCTAssertEqual(report.followers.map(\.observation), ["Left", "Left"])
        XCTAssertEqual(store.logs.count, 1)
        XCTAssertFalse(store.lastResult!.contains("pc-host"), "host names stay out of results")
        XCTAssertFalse(lock.held)
    }

    func testPreflightFailureMeansNoMonitorCommandAndNoSend() throws {
        mouse.slot = HostSlot(channel: 2, paired: true, hostName: "re-paired")
        XCTAssertEqual(run(), ExitCodes.followIncomplete)
        XCTAssertEqual(tools.switchCalls, [])
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(try lastReport().outcome, "PreflightRefused")
    }

    func testMonitorFailureOrTimeoutSendsNothing() throws {
        for timedOut in [false, true] {
            setUp()
            if timedOut { tools.switchTimedOut = true } else { tools.switchStatus = 1 }
            XCTAssertEqual(run(), ExitCodes.monitorFailed)
            XCTAssertEqual(tools.switchCalls.count, 1)
            XCTAssertEqual(sends, 0)
            XCTAssertEqual(keyboard.closeCount, 1)
            XCTAssertEqual(mouse.closeCount, 1)
        }
    }

    func testDisplayMissingAmbiguousOrListFailureRefusesBeforeDevices() {
        for output in ["[1] Built-in (AAAA)\n", "[1] \(TestData.displayId)\n[2] \(TestData.displayId)\n", ""] {
            setUp()
            tools.listOutput = output
            if output.isEmpty { tools.listStatus = 1 }
            XCTAssertEqual(run(), ExitCodes.displayUnavailable)
            XCTAssertEqual(tools.switchCalls, [])
            XCTAssertEqual(locator.opened, 0)
        }
    }

    func testLockHeldExitsBusyWithoutTouchingAnything() {
        lock.held = true
        XCTAssertEqual(run(), ExitCodes.busyOrCooldown)
        XCTAssertEqual(tools.calls.count, 0)
        XCTAssertEqual(locator.opened, 0)
        XCTAssertNil(store.lastResult)
    }

    func testCooldownExitsWithoutTouchingAnythingAndDoesNotExtendIt() throws {
        XCTAssertEqual(run(), ExitCodes.success)
        let finished = try lastReport().finishedAtMs
        tools.calls = []
        locator.opened = 0
        clock.delay(ms: 1_000)
        XCTAssertEqual(run(), ExitCodes.busyOrCooldown)
        XCTAssertEqual(tools.calls.count, 0)
        XCTAssertEqual(locator.opened, 0)
        XCTAssertEqual(try lastReport().finishedAtMs, finished)
        clock.delay(ms: 2_000)
        keyboard.sends = []; mouse.sends = []
        XCTAssertEqual(run(), ExitCodes.success)
        XCTAssertEqual(sends, 2)
    }

    func testClockGoingBackwardsDoesNotBlock() {
        store.lastResult = "{\"finishedAtMs\": \(clock.wallClockMs + 60_000)}"
        XCTAssertEqual(run(), ExitCodes.success)
    }

    func testAlreadyOnPCStillSwitchesMonitorOnce() {
        keyboard.state = HostState(slotCount: 3, currentChannel: 2)
        mouse.state = HostState(slotCount: 3, currentChannel: 2)
        XCTAssertEqual(run(), ExitCodes.success)
        XCTAssertEqual(tools.switchCalls.count, 1)
        XCTAssertEqual(sends, 0)
    }

    func testDevicesThatStayAreFollowIncomplete() throws {
        mouse.observation = "StillHere"
        XCTAssertEqual(run(), ExitCodes.followIncomplete)
        XCTAssertEqual(try lastReport().outcome, "FollowIncomplete")
        XCTAssertEqual(sends, 2)
    }

    func testDryRunNeverSwitchesOrSendsAndIgnoresCooldown() throws {
        store.lastResult = "{\"finishedAtMs\": \(clock.wallClockMs)}"
        XCTAssertEqual(run("--dry-run"), ExitCodes.success)
        XCTAssertEqual(tools.switchCalls, [])
        XCTAssertEqual(sends, 0)
        let report = try lastReport()
        XCTAssertEqual(report.outcome, "DryRun")
        XCTAssertEqual(report.followers.map(\.observation), ["WouldSend", "WouldSend"])
    }

    func testMissingOrInvalidConfigIsExit10() {
        store.config = nil
        XCTAssertEqual(run(), ExitCodes.invalidConfiguration)
        store.config = "{}"
        clock.delay(ms: AppInfo.cooldownMs)
        XCTAssertEqual(run(), ExitCodes.invalidConfiguration)
        XCTAssertEqual(tools.calls.count, 0)
    }

    func testFollowSendsOnlySelectedDeviceAndNeverTouchesMonitor() {
        XCTAssertEqual(run("follow", "--device", "mouse"), ExitCodes.success)
        XCTAssertEqual(mouse.sends, [2])
        XCTAssertEqual(keyboard.sends, [])
        XCTAssertEqual(tools.calls.count, 0)
        XCTAssertEqual(run("follow", "--device", "printer"), ExitCodes.invalidConfiguration)
    }

    func testFollowersInventoryNeverSends() {
        XCTAssertEqual(run("followers"), ExitCodes.success)
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(output.joined().contains("\"enrolledName\" : \"keyboard\""))
        XCTAssertEqual(tools.calls.count, 0)
        let summary = output.filter { $0.hasPrefix("SUMMARY") || $0.hasPrefix("  ") }
        XCTAssertEqual(summary.first, "SUMMARY fake; HID devices visible: 3; Logitech: 2; followers found: 2")
        XCTAssertTrue(summary.contains("  LOGI B359 Bluetooth Low Energy primary 0001:0002 pairs 0001:0002,FF43:0202 in/out 20/20 HIDPP"))
        XCTAssertTrue(summary.contains { $0.hasPrefix("  FOLLOWER B031") && $0.contains("channel=1") && $0.contains("problem=none") })
        XCTAssertFalse(summary.joined().contains("pc-host"), "summary carries no host names")
    }

    func testProbeTouchesNoDevice() {
        XCTAssertEqual(run("probe-trigger"), ExitCodes.success)
        XCTAssertEqual(store.probes.count, 1)
        XCTAssertTrue(store.probes[0].contains("\"processId\":42"))
        XCTAssertEqual(locator.opened, 0)
        XCTAssertEqual(tools.calls.count, 0)
    }

    // MARK: Enrollment

    func testEnrollCapturesHostNamesAndKeepsBackup() throws {
        let previous = store.config
        XCTAssertEqual(run("enroll", "--display", TestData.displayId, "--keyboard-channel", "2", "--mouse-channel", "2"),
                       ExitCodes.invalidConfiguration, "existing config needs --replace")
        XCTAssertEqual(run("enroll", "--display", TestData.displayId, "--keyboard-channel", "2", "--mouse-channel", "2", "--replace"),
                       ExitCodes.success)
        XCTAssertEqual(store.previousConfig, previous)
        let config = try ConfigParser.parse(XCTUnwrap(store.config))
        XCTAssertEqual(config.devices.map(\.name), ["keyboard", "mouse"])
        XCTAssertEqual(config.devices.map(\.targetHostName), ["pc-host", "pc-host"])
        XCTAssertEqual(config.devices[0].identityHash, TestData.keyboard.identityHash)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(tools.switchCalls, [])
    }

    func testEnrollRefusals() {
        store.config = nil
        // Current channel is the Mac's own.
        XCTAssertEqual(run("enroll", "--display", TestData.displayId, "--keyboard-channel", "1", "--mouse-channel", "2"),
                       ExitCodes.invalidConfiguration)
        mouse.slot = HostSlot(channel: 2, paired: false, hostName: nil)
        XCTAssertEqual(run("enroll", "--display", TestData.displayId, "--keyboard-channel", "2", "--mouse-channel", "2"),
                       ExitCodes.invalidConfiguration)
        XCTAssertEqual(run("enroll", "--display", "NOT-LISTED", "--keyboard-channel", "2", "--mouse-channel", "2"),
                       ExitCodes.displayUnavailable)
        locator.present.append(TestData.keyboard.identity)
        mouse.slot = HostSlot(channel: 2, paired: true, hostName: "pc-host")
        XCTAssertEqual(run("enroll", "--display", TestData.displayId, "--keyboard-channel", "2", "--mouse-channel", "2"),
                       ExitCodes.invalidConfiguration)
        XCTAssertNil(store.config)
        XCTAssertEqual(sends, 0)
    }

    func testCommandLineRejectsUnknownAndMalformedInput() {
        for arguments in [["bogus"], ["--dry-run", "x"], ["follow", "--device"], ["enroll", "--display", "X"],
                          ["enroll", "--display", "X", "--keyboard-channel", "4", "--mouse-channel", "1"],
                          ["enroll", "--display", "<id>", "--keyboard-channel", "1", "--mouse-channel", "1"],
                          ["displays", "--m1ddc", "a", "--m1ddc", "b"]] {
            XCTAssertThrowsError(try CommandLineParser.parse(arguments), "\(arguments)")
        }
        XCTAssertEqual(try CommandLineParser.parse([]), .button(dryRun: false))
        XCTAssertEqual(try CommandLineParser.parse(["follow"]), .follow(device: nil))
    }

    func testBundleCommandOnlySelectsProbeWhenLaunchedWithoutArguments() {
        XCTAssertEqual(CommandLineParser.launchArguments([], bundleCommand: "probe-trigger"), ["probe-trigger"])
        XCTAssertEqual(CommandLineParser.launchArguments(["-psn_0_12345"], bundleCommand: "probe-trigger"), ["probe-trigger"])
        XCTAssertEqual(CommandLineParser.launchArguments([], bundleCommand: nil), [])
        XCTAssertEqual(CommandLineParser.launchArguments([], bundleCommand: "follow"), [], "no other bundle command")
        XCTAssertEqual(CommandLineParser.launchArguments(["--dry-run"], bundleCommand: "probe-trigger"), ["--dry-run"])
    }

    func testM1ddcArgumentsAndDisplayMatching() throws {
        XCTAssertEqual(try M1ddc.switchToPCArguments(displayId: "ABC"), ["display", "ABC", "set", "input", "5"])
        XCTAssertThrowsError(try M1ddc.switchToPCArguments(displayId: "a b"))
        let list = "[1] LU28R55 (ABC-1)\n[2] Other (ABC-12)\n"
        XCTAssertEqual(M1ddc.countMatches(listOutput: list, displayId: "ABC-1"), 1)
        XCTAssertEqual(M1ddc.countMatches(listOutput: list, displayId: "ABC"), 0)
    }
}

final class ConfigTests: XCTestCase {
    func testRoundTripAndHashlessDevice() throws {
        XCTAssertEqual(try ConfigParser.parse(TestData.configText), TestData.config)
        var config = TestData.config
        config.devices[0].identityHash = nil
        XCTAssertEqual(try ConfigParser.parse(ConfigParser.encode(config)), config)
    }

    func testRejectsUnknownMissingAndInvalidFields() throws {
        let base = try JSONSerialization.jsonObject(with: Data(TestData.configText.utf8)) as! [String: Any]
        func mutate(_ change: (inout [String: Any]) -> Void) -> String {
            var copy = base
            change(&copy)
            return String(decoding: try! JSONSerialization.data(withJSONObject: copy), as: UTF8.self)
        }
        func device(_ change: @escaping (inout [String: Any]) -> Void) -> String {
            mutate { root in
                var devices = root["devices"] as! [[String: Any]]
                change(&devices[0])
                root["devices"] = devices
            }
        }
        let invalid = [
            mutate { $0["extra"] = 1 },
            mutate { $0["schemaVersion"] = 2 },
            mutate { $0.removeValue(forKey: "monitor") },
            mutate { $0["monitor"] = ["m1ddcPath": "m1ddc", "displayId": TestData.displayId] },
            mutate { $0["monitor"] = ["m1ddcPath": "/opt/homebrew/bin/m1ddc", "displayId": "<display>"] },
            mutate { $0["monitor"] = ["m1ddcPath": "/opt/homebrew/bin/m1ddc", "displayId": TestData.displayId, "vcp": 96] },
            mutate { $0["devices"] = [] },
            device { $0["extra"] = true },
            device { $0["targetChannel"] = 4 },
            device { $0["targetChannel"] = 0 },
            device { $0["productId"] = "XYZ1" },
            device { $0["identityHash"] = "ABC" },
            device { $0["targetHostName"] = "<captured during enrollment>" },
            device { $0["targetHostName"] = " " },
            device { $0["name"] = "bad name" },
            device { $0.removeValue(forKey: "targetHostName") },
            mutate { root in
                var devices = root["devices"] as! [[String: Any]]
                devices[1]["name"] = devices[0]["name"]
                root["devices"] = devices
            },
            mutate { root in
                var devices = root["devices"] as! [[String: Any]]
                devices[1]["productId"] = devices[0]["productId"]
                devices[1]["identityHash"] = NSNull()
                root["devices"] = devices
            },
            "not json",
        ]
        for text in invalid { XCTAssertThrowsError(try ConfigParser.parse(text), text) }
    }
}
