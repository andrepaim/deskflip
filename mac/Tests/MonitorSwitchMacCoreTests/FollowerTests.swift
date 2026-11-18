import XCTest
@testable import MonitorSwitchMacCore

final class FollowerTests: XCTestCase {
    private var locator: FakeLocator!
    private var keyboard: FakeFollower!
    private var mouse: FakeFollower!

    override func setUp() {
        locator = FakeLocator()
        keyboard = locator.add(TestData.keyboard)
        mouse = locator.add(TestData.mouse)
    }

    private func operate(dryRun: Bool = false, devices: [FollowerConfig] = [TestData.mouse, TestData.keyboard]) -> FollowerOperation {
        let operation = FollowerOperation(devices: devices)
        operation.preflight(locator: locator)
        if dryRun { operation.markDryRun() } else { operation.sendAll() }
        operation.close()
        return operation
    }

    func testAllPreflightBeforeKeyboardThenMouseAndCloseAll() {
        keyboard.onSend = { [unowned self] in
            XCTAssertEqual(self.mouse.hostCalls, 1)
            XCTAssertEqual(self.keyboard.hostCalls, 1)
            self.locator.sendOrder.append("keyboard")
        }
        let operation = operate()
        XCTAssertTrue(operation.succeeded)
        XCTAssertEqual(locator.sendOrder, ["keyboard", "mouse"])
        XCTAssertEqual(keyboard.sends, [2])
        XCTAssertEqual(mouse.sends, [2])
        XCTAssertTrue(operation.results.allSatisfy { $0.commandSent && $0.sendResult == "Accepted" })
        XCTAssertEqual(keyboard.closeCount, 1)
        XCTAssertEqual(mouse.closeCount, 1)
    }

    func testAnyFailedPreflightBlocksEverySend() {
        for problem in ["missing", "ambiguous", "unreachable", "unpaired", "host", "slots", "current"] {
            for failMouse in [false, true] {
                setUp()
                let device: FakeFollower = failMouse ? mouse : keyboard
                let config = failMouse ? TestData.mouse : TestData.keyboard
                switch problem {
                case "missing": locator.present.removeAll { $0 == config.identity }
                case "ambiguous": locator.present.append(config.identity)
                case "unreachable": device.throwRead = true
                case "unpaired": device.slot = HostSlot(channel: 2, paired: false, hostName: nil)
                case "host": device.slot = HostSlot(channel: 2, paired: true, hostName: "different-pairing")
                case "slots": device.state = HostState(slotCount: 1, currentChannel: 1)
                default: device.state = HostState(slotCount: 3, currentChannel: 0)
                }
                let operation = operate()
                XCTAssertFalse(operation.allReady, problem)
                XCTAssertFalse(operation.succeeded, problem)
                XCTAssertEqual(keyboard.sends, [], problem)
                XCTAssertEqual(mouse.sends, [], problem)
            }
        }
    }

    func testDryRunQueriesButDoesNotSend() {
        let operation = operate(dryRun: true)
        XCTAssertEqual(keyboard.sends, [])
        XCTAssertEqual(mouse.sends, [])
        XCTAssertTrue(operation.results.allSatisfy { $0.observation == "WouldSend" && !$0.commandSent })
    }

    func testAlreadyThereSkipsHostQueryAndSend() {
        keyboard.state = HostState(slotCount: 3, currentChannel: 2)
        let operation = operate()
        XCTAssertTrue(operation.succeeded)
        XCTAssertEqual(keyboard.sends, [])
        XCTAssertEqual(keyboard.hostCalls, 0)
        XCTAssertEqual(mouse.sends, [2])
        XCTAssertEqual(operation.results.first { $0.name == "keyboard" }?.observation, "AlreadyThere")
    }

    func testThrowingSendIsUnverifiedAndNeverRetried() {
        keyboard.throwSend = true
        keyboard.observation = "StillHere"
        let operation = operate()
        XCTAssertFalse(operation.succeeded)
        XCTAssertEqual(keyboard.sends, [2])
        XCTAssertEqual(mouse.sends, [2])
        let result = operation.results.first { $0.name == "keyboard" }!
        XCTAssertTrue(result.commandSent)
        XCTAssertEqual(result.sendResult, "Unverified")
        XCTAssertEqual(result.problem, "io(0x00000005)")
    }

    func testRejectionOverridesLaterDeparture() {
        keyboard.diagnostics.changeHostError = 8
        let operation = operate()
        XCTAssertEqual(operation.results.first { $0.name == "keyboard" }?.sendResult, "Rejected")
        XCTAssertFalse(operation.succeeded)
    }

    func testObservationMappingAndSecondSendAllIsIgnored() {
        mouse.observation = "something-else"
        let operation = FollowerOperation(devices: [TestData.mouse, TestData.keyboard])
        operation.preflight(locator: locator)
        operation.sendAll()
        operation.sendAll()
        XCTAssertEqual(operation.results.first { $0.name == "mouse" }?.observation, "Unknown")
        XCTAssertEqual(mouse.sends, [2])
        XCTAssertEqual(keyboard.sends, [2])
    }

    func testHashlessEnrollmentMatchesProductOnlyAndRefusesTwo() throws {
        let enrolled = FollowerIdentity(productId: "B359", identityHash: nil)
        XCTAssertEqual(try FollowerSelection.unique([FollowerIdentity(productId: "b359", identityHash: "x"),
                                                     FollowerIdentity(productId: "B031", identityHash: nil)], for: enrolled), 0)
        XCTAssertThrowsError(try FollowerSelection.unique([FollowerIdentity(productId: "B359", identityHash: "x"),
                                                           FollowerIdentity(productId: "B359", identityHash: "y")], for: enrolled))
        let hashed = FollowerIdentity(productId: "B359", identityHash: "x")
        XCTAssertThrowsError(try FollowerSelection.unique([FollowerIdentity(productId: "B359", identityHash: "y")], for: hashed))
    }
}
