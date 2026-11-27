import XCTest
@testable import MappingCore
import Foundation

final class PJLinkTests: XCTestCase {
    private struct Script: PJLinkTransport {
        var lines: [String]
        var sent: [Data] = []
        mutating func send(_ message: Data) { sent.append(message) }
        mutating func receiveLine() throws -> String {
            guard !lines.isEmpty else { throw PJLinkProtocolError.disconnected }
            return lines.removeFirst()
        }
    }

    func testFragmentsExactCommandsAndTypedReplies() throws {
        var decoder = PJLinkLineDecoder()
        XCTAssertEqual(try decoder.append(Data("PJLI".utf8)), [])
        XCTAssertTrue(decoder.hasPartialLine)
        XCTAssertEqual(try decoder.append(Data("NK 0\r%1pOwR=2\r%1AV".utf8)), ["PJLINK 0", "%1pOwR=2"])
        XCTAssertEqual(try decoder.append(Data("MT=21\r".utf8)), ["%1AVMT=21"])
        XCTAssertFalse(decoder.hasPartialLine)
        XCTAssertEqual(String(decoding: PJLinkCommand.setPower(true).wire, as: UTF8.self), "%1POWR 1\r")
        XCTAssertEqual(String(decoding: PJLinkCommand.setMute(false).wire, as: UTF8.self), "%1AVMT 30\r")
        XCTAssertEqual(try PJLinkCodec.reply(to: .powerStatus, line: "%1pOwR=2"), .power(.cooling))
        XCTAssertEqual(try PJLinkCodec.reply(to: .powerStatus, line: "%1POWR=3"), .power(.warming))
        XCTAssertEqual(try PJLinkCodec.reply(to: .muteStatus, line: "%1AVMT=21"), .mute(.audio))
        XCTAssertEqual(try PJLinkCodec.reply(to: .faults, line: "%1ERST=012210"), .faults(
            .init(fan: .clearOrUnsupported, lamp: .warning, temperature: .fault,
                  cover: .fault, filter: .warning, other: .clearOrUnsupported)))
        XCTAssertEqual(try PJLinkCodec.reply(to: .deviceClass, line: "%1CLSS=2"), .deviceClass(2))
        XCTAssertEqual(try PJLinkCodec.reply(to: .powerStatus, line: "%1POWR=ERR3"), .rejected(.unavailable))
        XCTAssertEqual(try PJLinkCodec.reply(to: .setMute(true), line: "%1AVMT=ERR2"), .rejected(.parameter))
    }

    func testRejectsMalformedAndMismatchedWireData() throws {
        var decoder = PJLinkLineDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: PJLinkLineDecoder.maximumLineBytes + 1)))
        var oversized = PJLinkLineDecoder()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: PJLinkLineDecoder.maximumFragmentBytes + 1)))
        var injected = PJLinkLineDecoder()
        XCTAssertThrowsError(try injected.append(Data("PJLINK 0\n".utf8)))
        XCTAssertThrowsError(try PJLinkGreeting(line: "PJLINK 1 GGGGGGGG"))
        XCTAssertThrowsError(try PJLinkGreeting(line: "PJLINK 0 suffix"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .powerStatus, line: "%2POWR=1"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .powerStatus, line: "%1AVMT=1"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .powerStatus, line: "%1POWR=01"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .muteStatus, line: "%1AVMT=10"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .faults, line: "%1ERST=0112a0"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .setPower(true), line: "%1POWR=1"))
        XCTAssertThrowsError(try PJLinkCodec.reply(to: .powerStatus, line: "PJLINK ERRA"))
        XCTAssertFalse(PJLinkCodec.validPassword("two words"))
        XCTAssertFalse(PJLinkCodec.validPassword(String(repeating: "A", count: 33)))
    }

    func testModernHandshakeBindsFreshNonceAndSequentialReplies() throws {
        var script = Script(lines: ["PJLINK 1 0a1b2c3d", "PJLINK 2 000102030405060708090a0b0c0d0e0f",
                                    "%1POWR=3", "%1AVMT=ERR3", "%1ERST=000000", "%1CLSS=2"])
        let controller = Array(repeating: UInt8(0x10), count: 16)
        var algorithms: [PJLinkDigest] = []
        var inputs: [Data] = []
        let replies = try PJLinkClient.transact(over: &script, using: .sha256, password: "Fixture1",
                                               commands: PJLinkClient.statusCommands, controllerNonce: { controller }) { mode, bytes in
            algorithms.append(mode)
            inputs.append(bytes)
            return Array(repeating: 0xAB, count: 32)
        }
        XCTAssertEqual(algorithms, [.sha256])
        XCTAssertEqual(inputs, [Data("101112131415161718191a1b1c1d1e1fFixture1".utf8)])
        XCTAssertEqual(script.sent.map { String(decoding: $0, as: UTF8.self) }, [
            "PJLINK 2\r", String(repeating: "10", count: 16) + String(repeating: "ab", count: 32) + "%1POWR ?\r",
            "%1AVMT ?\r", "%1ERST ?\r", "%1CLSS ?\r"
        ])
        XCTAssertEqual(replies.first, .power(.warming))
        XCTAssertEqual(replies[1], .rejected(.unavailable))
        XCTAssertEqual(replies.last, .deviceClass(2))
    }

    func testExplicitAuthModesAndNoDowngradeOrWriteBatch() throws {
        var legacy = Script(lines: ["PJLINK 1 0a1B2c3D", "%1AVMT=OK"])
        let reply = try PJLinkClient.transact(over: &legacy, using: .legacyMD5, password: "Fixture1", commands: [.setMute(true)],
                                             controllerNonce: { [] }) { algorithm, input in
            XCTAssertEqual(algorithm, .md5)
            XCTAssertEqual(input, Data("0a1B2c3DFixture1".utf8))
            return Array(repeating: 0x24, count: 16)
        }
        XCTAssertEqual(reply, [.acknowledged])
        XCTAssertEqual(legacy.sent, [Data((String(repeating: "24", count: 16) + "%1AVMT 31\r").utf8)])

        var plain = Script(lines: ["PJLINK 0", "%1POWR=0"])
        XCTAssertEqual(try PJLinkClient.transact(over: &plain, using: .unprotected, password: "", commands: [.powerStatus],
                                                controllerNonce: { [] }, digest: { _, _ in [] }), [.power(.standby)])
        XCTAssertEqual(plain.sent, [PJLinkCommand.powerStatus.wire])

        var downgrade = Script(lines: ["PJLINK 1 0a1b2c3d", "PJLINK ERR1"])
        XCTAssertThrowsError(try PJLinkClient.transact(over: &downgrade, using: .sha256, password: "Fixture1", commands: [.setPower(true)],
                                                      controllerNonce: { [] }, digest: { _, _ in [] }))
        XCTAssertEqual(downgrade.sent, [PJLinkCodec.securityInquiry])

        var mismatch = Script(lines: ["PJLINK 0"])
        XCTAssertThrowsError(try PJLinkClient.transact(over: &mismatch, using: .legacyMD5, password: "Fixture1", commands: [.setPower(true)],
                                                      controllerNonce: { [] }, digest: { _, _ in [] }))
        XCTAssertTrue(mismatch.sent.isEmpty)

        var batch = Script(lines: [])
        XCTAssertThrowsError(try PJLinkClient.transact(over: &batch, using: .unprotected, password: "",
                                                      commands: [.setPower(false), .powerStatus], controllerNonce: { [] }, digest: { _, _ in [] }))
        XCTAssertTrue(batch.sent.isEmpty)
    }
}
