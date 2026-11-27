import Foundation
import XCTest
@testable import MappingCore

final class FirmataTests: XCTestCase {
    // D2 is bidirectional, D6 is the physical pin for analog channel A0, and D9 belongs to port 1.
    private let capabilityResponse: [UInt8] = [
        0xF0, 0x6C, 127, 127, 0, 1, 1, 1, 127, 127, 127, 127, 2, 10, 127, 127, 127, 0, 1, 127, 0xF7,
    ]
    private let mappingResponse: [UInt8] = [0xF0, 0x6A, 127, 127, 127, 127, 127, 127, 0, 127, 127, 127, 0xF7]
    private let discoveryRequests: [UInt8] = [0xF0, 0x6B, 0xF7, 0xF0, 0x69, 0xF7]

    func testFragmentedDiscoveryAndAnalogInput() throws {
        var session = FirmataSession()
        XCTAssertEqual(Array(session.connect(at: 1)), [0xF9])
        XCTAssertTrue(session.receive(Data([0xF9, 2]), at: 1.02).isEmpty)
        XCTAssertEqual(Array(session.receive(Data([8]), at: 1.05)), discoveryRequests)
        XCTAssertTrue(session.receive(Data(mappingResponse), at: 1.07).isEmpty)
        for byte in capabilityResponse {
            XCTAssertTrue(session.receive(Data([byte]), at: 1.10).isEmpty)
        }
        guard case .ready(let board) = session.phase else {
            return XCTAssertTrue(false, "Expected successful discovery")
        }
        XCTAssertEqual(board.protocolMajor, 2)
        XCTAssertEqual(board.protocolMinor, 8)
        XCTAssertEqual(board.pins.count, 10)
        XCTAssertEqual(board.pins[6].analogChannel, 0)
        XCTAssertEqual(board.pins[6].analogResolution, 10)
        XCTAssertFalse(board.pins[6].digitalOutput)
        XCTAssertEqual(Array(try session.configureInput(.analog(channel: 0))), [0xF4, 6, 2, 0xC0, 1])
        _ = session.receive(Data([0xE1, 1, 1, 0xE0, 1]), at: 1.11)
        XCTAssertNil(session.latestSample)
        _ = session.receive(Data([4]), at: 1.11)
        let sample = try XCTUnwrap(session.latestSample)
        XCTAssertEqual(sample.value, 513)
        XCTAssertEqual(sample.normalized, 513.0 / 1023.0, accuracy: 1e-12)
        _ = session.receive(Data([0xE0, 127, 127]), at: 1.15)
        XCTAssertEqual(session.latestSample, sample)
        XCTAssertThrowsError(try session.configureInput(.analog(channel: 1)))
        XCTAssertEqual(session.input, .analog(channel: 0))
        XCTAssertEqual(Array(try session.configureInput(nil)), [0xC0, 0])
        XCTAssertNil(session.latestSample)
    }

    func testDigitalPortAndIndividualPinWrite() throws {
        var session = discoveredSession()
        XCTAssertEqual(Array(try session.configureInput(.digital(pin: 9))), [0xF4, 9, 0, 0xD1, 1])
        _ = session.receive(Data([0x90, 2, 0, 0x91, 2, 2]), at: 2)
        XCTAssertNil(session.latestSample)
        _ = session.receive(Data([0x91, 2, 0]), at: 2)
        XCTAssertEqual(session.latestSample?.value, 1)
        XCTAssertThrowsError(try session.writeDigital(pin: 9, high: true, at: 2))
        XCTAssertThrowsError(try session.writeDigital(pin: Int.min, high: true, at: 2))
        XCTAssertEqual(Array(try session.writeDigital(pin: 2, high: true, at: 2)), [
            0xF4, 2, 1, 0xF5, 2, 1, 0xF0, 0x6D, 2, 0xF7,
        ])
        XCTAssertThrowsError(try session.writeDigital(pin: 2, high: false, at: 2.03))
        _ = session.receive(Data([0xF0, 0x6E, 3, 1, 1, 0xF7]), at: 2.04)
        XCTAssertEqual(session.output, .pending(pin: 2, high: true))
        _ = session.receive(Data([0xF0, 0x6E, 2, 1, 1, 0xF7]), at: 2.05)
        XCTAssertEqual(session.output, .confirmed(pin: 2, high: true))
        XCTAssertEqual(Array(try session.writeDigital(pin: 2, high: false, at: 2.06)), [0xF5, 2, 0, 0xF0, 0x6D, 2, 0xF7])
        _ = session.tick(at: 3.10)
        XCTAssertEqual(session.output, .unconfirmed(pin: 2))
        XCTAssertEqual(Array(try session.configureInput(.digital(pin: 2))), [0xD1, 0, 0xF4, 2, 0, 0xD0, 1])
        XCTAssertThrowsError(try session.writeDigital(pin: 2, high: true, at: 3.2))
    }

    func testBoardResetClearsInFlightControl() throws {
        var session = discoveredSession()
        _ = try session.configureInput(.analog(channel: 0))
        _ = session.receive(Data([0xE0, 64, 0]), at: 2)
        _ = try session.writeDigital(pin: 2, high: true, at: 2)
        let reset = Data([0xF9, 2, 8, 0xE0, 64, 0, 0xF0, 0x6E, 2, 1, 1, 0xF7])
        XCTAssertEqual(Array(session.receive(reset, at: 2.1)), discoveryRequests)
        XCTAssertEqual(session.phase, .discovering)
        XCTAssertNil(session.input)
        XCTAssertNil(session.latestSample)
        XCTAssertEqual(session.output, .idle)
        XCTAssertThrowsError(try session.writeDigital(pin: 2, high: true, at: 2.14))
        XCTAssertTrue(session.receive(Data(capabilityResponse + mappingResponse), at: 2.15).isEmpty)
        XCTAssertNil(session.input)
        XCTAssertTrue(session.tick(at: 2.20).isEmpty)
        XCTAssertEqual(Array(session.receive(Data([0xFF]), at: 2.25)), [0xF9])
        session.disconnect()
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertTrue(session.receive(Data(reset), at: 2.30).isEmpty)
    }

    func testMalformedDiscoveryTimeoutAndParserResynchronization() throws {
        var session = FirmataSession()
        _ = session.connect(at: 0)
        XCTAssertTrue(session.tick(at: 0.5).isEmpty)
        XCTAssertEqual(Array(session.tick(at: 0.8)), [0xF9])
        let oversized = Data([0xF0, 0x6C] + Array(repeating: 0, count: 9000) + [0xF7, 0xF9, 2, 8])
        XCTAssertEqual(Array(session.receive(oversized, at: 1)), discoveryRequests)
        XCTAssertEqual(Array(session.tick(at: 2)), discoveryRequests)
        _ = session.receive(Data([0xF0, 0x6C, 1, 127, 0xF7]), at: 3)
        XCTAssertEqual(session.phase, .failed(.invalidDiscovery))
        XCTAssertThrowsError(try session.configureInput(.digital(pin: 1)))
        _ = session.connect(at: 4)
        _ = session.receive(Data([0xF9, 2, 4]), at: 4.1)
        XCTAssertEqual(session.phase, .failed(.unsupportedVersion(2, 4)))

        _ = session.connect(at: 5)
        _ = session.receive(Data([0xF9, 2, 8] + capabilityResponse + [0xF0, 0x6A, 127, 0xF7]), at: 5.1)
        XCTAssertEqual(session.phase, .failed(.invalidDiscovery))
        _ = session.connect(at: 6)
        _ = session.receive(Data([0xFF]), at: 9)
        _ = session.receive(Data([0xFF]), at: 13)
        _ = session.tick(at: 14)
        XCTAssertEqual(session.phase, .failed(.handshakeTimedOut))
    }

    private func discoveredSession() -> FirmataSession {
        var session = FirmataSession()
        _ = session.connect(at: 0)
        _ = session.receive(Data([0xF9, 2, 8] + capabilityResponse + mappingResponse), at: 0.1)
        return session
    }
}
