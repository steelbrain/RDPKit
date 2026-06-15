import Foundation
@testable import RDPKit
import Testing

@Test func parsesTPKTTransportPacketLength() throws {
    let packet = Data([0x03, 0x00, 0x00, 0x07, 0x02, 0xF0, 0x80])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == 7)
}

@Test func waitsForPartialTPKTTransportPacketHeader() throws {
    let packet = Data([0x03, 0x00, 0x00])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == nil)
}

@Test func parsesFastPathTransportPacketLength() throws {
    let packet = Data([0x00, 0x08, 0x03, 0xEA, 0x00, 0x00, 0x00, 0x00])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == 8)
}

@Test func parsesExtendedFastPathTransportPacketLength() throws {
    let packet = Data([0x00, 0x81, 0x00])

    #expect(try RDPTransportPacketFraming.packetLength(from: packet) == 0x0100)
}

@Test func rejectsInvalidFastPathTransportPacketLength() throws {
    do {
        _ = try RDPTransportPacketFraming.packetLength(from: Data([0x00, 0x02]))
        #expect(Bool(false), "Expected invalid Fast-Path length to throw")
    } catch let error as RDPPreflightError {
        #expect(error.description == "receive failed: received invalid Fast-Path length 2")
    }
}
