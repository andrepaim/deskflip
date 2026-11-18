import XCTest
@testable import MonitorSwitchMacCore

final class HidppTests: XCTestCase {
    private let clock = FakeClock()

    func testFixedSurfaceUsesLongReportsAndZeroBasedHost() throws {
        let cases: [([UInt8], [UInt8])] = [
            (HidppPackets.feature(.changeHost), [0x11, 0xFF, 0, 0x0B, 0x18, 0x14]),
            (HidppPackets.feature(.hostsInfo), [0x11, 0xFF, 0, 0x0B, 0x18, 0x15]),
            (try HidppPackets.state(0xA), [0x11, 0xFF, 0xA, 0x0B]),
            (try HidppPackets.changeHost(0xA, channel: 3), [0x11, 0xFF, 0xA, 0x1B, 2]),
            (try HidppPackets.hostsSummary(0xB), [0x11, 0xFF, 0xB, 0x0B]),
            (try HidppPackets.hostInfo(0xB, channel: 2), [0x11, 0xFF, 0xB, 0x1B, 1]),
            (try HidppPackets.hostName(0xB, channel: 2, offset: 14), [0x11, 0xFF, 0xB, 0x3B, 1, 14]),
        ]
        for (packet, prefix) in cases {
            XCTAssertEqual(packet.count, 20)
            XCTAssertEqual(Array(packet.prefix(prefix.count)), prefix)
            XCTAssertTrue(packet.dropFirst(prefix.count).allSatisfy { $0 == 0 })
        }
    }

    func testRejectsInvalidFeatureIndexAndChannel() {
        XCTAssertThrowsError(try HidppPackets.state(0))
        XCTAssertThrowsError(try HidppPackets.state(255))
        XCTAssertThrowsError(try HidppPackets.changeHost(10, channel: 0))
        XCTAssertThrowsError(try HidppPackets.changeHost(10, channel: 4))
    }

    func testMatchingIncludesSoftwareIdDeviceIndexReportLengthAndErrorFrame() throws {
        let request = try HidppPackets.state(10)
        XCTAssertEqual(HidppPackets.match(request, reply(request, [3, 0])), .match)
        for index in 0..<4 {
            var other = reply(request, [3, 0])
            other[index] ^= 1
            XCTAssertEqual(HidppPackets.match(request, other), .unrelated)
        }
        XCTAssertEqual(HidppPackets.match(request, [0x11]), .unrelated)
        XCTAssertEqual(HidppPackets.match(request, errorReply(request, 2)), .error)
    }

    func testResolvesIndexesAndReadsUtf8NamesInChunksWithoutChangingHost() throws {
        let transport = FakeTransport(clock: clock)
        let name = "test-long-destination-é"
        let bytes = Array(name.utf8)
        transport.onWrite = { request in
            let response: [UInt8]
            switch (request[2], request[3]) {
            case (0, _): response = reply(request, [request[5] == 0x14 ? 8 : 9])
            case (8, _): response = reply(request, [3, 0])
            case (9, 0x0B): response = reply(request, [1, 0, 3])
            case (9, 0x1B): response = reply(request, [1, 1, 0, 0, UInt8(bytes.count)])
            case (9, 0x3B): response = reply(request, [1, request[5]] + Array(bytes.dropFirst(Int(request[5])).prefix(14)))
            default: XCTFail("Unexpected packet"); return
            }
            transport.replies.append { response }
        }
        let session = HidppSession(transport: transport, clock: clock)
        XCTAssertEqual(try session.readState(), HostState(slotCount: 3, currentChannel: 1))
        XCTAssertEqual(try session.readHost(2), HostSlot(channel: 2, paired: true, hostName: name))
        XCTAssertFalse(transport.writes.contains { $0[2] == 8 && $0[3] == 0x1B })
        XCTAssertEqual(transport.writes.filter { $0[2] == 0 }.count, 2)
    }

    func testInvalidUtf8HostNameFailsClosed() {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { request in
            let response: [UInt8]
            switch (request[2], request[3]) {
            case (0, _): response = reply(request, [request[5] == 0x14 ? 8 : 9])
            case (8, _): response = reply(request, [3, 0])
            case (9, 0x0B): response = reply(request, [1, 0, 3])
            case (9, 0x1B): response = reply(request, [1, 1, 0, 0, 2])
            default: response = reply(request, [1, 0, 0xC3, 0x28])
            }
            transport.replies.append { response }
        }
        let session = HidppSession(transport: transport, clock: clock)
        XCTAssertThrowsError(try session.readHost(2)) { XCTAssertEqual($0 as? HidppError, .invalidHostName) }
    }

    func testDuplicateFeatureReplyCannotTurnHostInfoQueryIntoChangeHost() throws {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { p in transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 0]) } }
        let session = HidppSession(transport: transport, clock: clock)
        _ = try session.readState()
        XCTAssertThrowsError(try session.readHost(2)) { XCTAssertEqual($0 as? HidppError, .ambiguousFeatureIndexes) }
        XCTAssertFalse(transport.writes.contains { $0[3] == 0x1B })
    }

    func testIgnoresNotificationsAndUsesOneRetryOnTimeout() throws {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { p in
            if transport.writes.count == 1 { return } // first root lookup times out
            transport.replies.append { [UInt8](repeating: 0, count: 20) }
            transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 0]) }
        }
        let session = HidppSession(transport: transport, clock: clock)
        XCTAssertEqual(try session.readState().currentChannel, 1)
        XCTAssertEqual(transport.writes.filter { $0[2] == 0 }.count, 2)
        XCTAssertTrue(transport.budgets.allSatisfy { (1...500).contains($0) })
        XCTAssertEqual(session.diagnostics.timeouts, 1)
    }

    func testUnendingNotificationsStillReachDeadlineAndStopAfterTwoQueries() {
        let transport = FakeTransport(clock: clock)
        transport.notificationsForever = true
        let session = HidppSession(transport: transport, clock: clock)
        let start = clock.monotonicMs
        XCTAssertThrowsError(try session.readState()) { XCTAssertEqual($0 as? HidppError, .timeout) }
        XCTAssertEqual(transport.writes.count, 2)
        XCTAssertTrue((1000...1020).contains(clock.monotonicMs - start))
    }

    func testInvalidHostStateFailsClosed() {
        for (slots, current) in [(UInt8(0), UInt8(0)), (4, 0), (3, 3)] {
            let transport = FakeTransport(clock: clock)
            transport.onWrite = { p in transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [slots, current]) } }
            let session = HidppSession(transport: transport, clock: clock)
            XCTAssertThrowsError(try session.readState())
        }
    }

    func testErrorReplyFailsImmediatelyWithoutRetry() {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { p in transport.replies.append { errorReply(p, 2) } }
        let session = HidppSession(transport: transport, clock: clock)
        XCTAssertThrowsError(try session.readState()) { XCTAssertEqual($0 as? HidppError, .queryRejected(code: 2)) }
        XCTAssertEqual(session.diagnostics.lastQueryError, 2)
        XCTAssertEqual(transport.writes.count, 1)
    }

    func testCapturesChangeHostRejectionDuringPassiveWindowOrLaterQuery() throws {
        for late in [false, true] {
            let transport = FakeTransport(clock: clock)
            var change: [UInt8]?
            transport.onWrite = { p in
                if p[3] == 0x1B {
                    change = p
                    if !late { transport.replies.append { errorReply(p, 8) } }
                    return
                }
                if late, let change { transport.replies.append { errorReply(change, 8) } }
                transport.replies.append { p[2] == 0 ? reply(p, [10, 0, 2]) : reply(p, [3, 1]) }
            }
            let session = HidppSession(transport: transport, clock: clock)
            _ = try session.readState()
            try session.changeHost(1)
            XCTAssertEqual(session.observeDeparture(budgetMs: 2000), "StillHere")
            XCTAssertEqual(session.diagnostics.changeHostError, 8)
            XCTAssertEqual(session.diagnostics.changeHostIndex, 10)
            XCTAssertEqual(session.diagnostics.changeHostVersion, 2)
            XCTAssertEqual(session.diagnostics.lastCurrentChannel, 2)
            XCTAssertGreaterThan(session.diagnostics.stateReplies, 1)
            XCTAssertEqual(transport.writes.filter { $0[3] == 0x1B }.count, 1)
        }
    }

    func testForeignErrorDoesNotBecomeOurChangeHostRejection() throws {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { p in
            if p[3] == 0x1B {
                var foreign = errorReply(p, 8)
                foreign[4] ^= 1 // another application's software ID
                transport.replies.append { foreign }
            } else {
                transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 1]) }
            }
        }
        let session = HidppSession(transport: transport, clock: clock)
        _ = try session.readState()
        try session.changeHost(1)
        _ = session.observeDeparture(budgetMs: 2000)
        XCTAssertNil(session.diagnostics.changeHostError)
    }

    func testDepartureStartsWithReadOnlyWindowAndKeepsTotalBudget() throws {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { p in transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 1]) } }
        let session = HidppSession(transport: transport, clock: clock)
        _ = try session.readState()
        transport.onWrite = nil
        try session.changeHost(1)
        let start = clock.monotonicMs
        transport.onWrite = { [clock] _ in XCTAssertGreaterThanOrEqual(clock.monotonicMs - start, 250) }
        XCTAssertEqual(session.observeDeparture(budgetMs: 2000), "Unknown")
        XCTAssertGreaterThan(session.diagnostics.timeouts, 0)
        XCTAssertTrue((0...2000).contains(clock.monotonicMs - start))
        XCTAssertEqual(transport.writes.filter { $0[3] == 0x1B }.count, 1)
    }

    func testKeepsNativeErrorCode() {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { _ in throw HidppError.io(native: 31) }
        let session = HidppSession(transport: transport, clock: clock)
        XCTAssertThrowsError(try session.readState())
        XCTAssertEqual(session.diagnostics.lastNativeError, 31)
        XCTAssertEqual(session.diagnostics.ioFailures, 1)
        XCTAssertEqual(transport.writes.count, 1)
    }

    func testChangeHostCannotBeRetriedEvenWhenWriteThrows() throws {
        for throwWrite in [false, true] {
            let transport = FakeTransport(clock: clock)
            transport.onWrite = { p in
                if p[3] == 0x1B {
                    if throwWrite { throw HidppError.timeout }
                    return
                }
                transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 0]) }
            }
            let session = HidppSession(transport: transport, clock: clock)
            _ = try session.readState()
            if throwWrite { XCTAssertThrowsError(try session.changeHost(2)) } else { try session.changeHost(2) }
            XCTAssertThrowsError(try session.changeHost(2)) { XCTAssertEqual($0 as? HidppError, .changeHostAlreadyAttempted) }
            XCTAssertEqual(transport.writes.filter { $0[3] == 0x1B }.count, 1)
        }
    }

    func testChangeHostRequiresPreflight() {
        let session = HidppSession(transport: FakeTransport(clock: clock), clock: clock)
        XCTAssertThrowsError(try session.changeHost(2)) { XCTAssertEqual($0 as? HidppError, .preflightRequired) }
    }

    func testObservationsDistinguishDisconnectFromSilence() throws {
        for expected in ["Left", "StillHere", "Unknown"] {
            let transport = FakeTransport(clock: clock)
            transport.onWrite = { p in transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 0]) } }
            let session = HidppSession(transport: transport, clock: clock)
            _ = try session.readState()
            transport.onWrite = nil
            try session.changeHost(2)
            transport.onWrite = { p in
                if expected == "Left" { throw HidppError.disconnected }
                if expected == "StillHere" { transport.replies.append { reply(p, [3, 0]) } }
            }
            let start = clock.monotonicMs
            XCTAssertEqual(session.observeDeparture(budgetMs: 2000), expected)
            XCTAssertTrue((0...2000).contains(clock.monotonicMs - start))
            XCTAssertEqual(transport.writes.filter { $0[3] == 0x1B }.count, 1)
        }
    }

    func testDisconnectDuringPassiveWindowIsLeft() throws {
        let transport = FakeTransport(clock: clock)
        transport.onWrite = { p in transport.replies.append { p[2] == 0 ? reply(p, [10]) : reply(p, [3, 0]) } }
        let session = HidppSession(transport: transport, clock: clock)
        _ = try session.readState()
        transport.onWrite = nil
        try session.changeHost(2)
        transport.replies.append { throw HidppError.disconnected }
        XCTAssertEqual(session.observeDeparture(budgetMs: 2000), "Left")
        XCTAssertEqual(transport.writes.count, 3)
    }
}
