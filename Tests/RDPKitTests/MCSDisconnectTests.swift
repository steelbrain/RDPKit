import Foundation
@testable import RDPKit
import Testing

@Test func parsesMCSDisconnectProviderUltimatumReason() throws {
    let pdu = try #require(try MCSDisconnectProviderUltimatumPDU.parseIfPresent(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x09,
        0x02, 0xF0, 0x80,
        0x21, 0x80,
    ])))

    #expect(pdu.reason == 3)
    #expect(pdu.reasonName == "rn-user-requested")
}

/// The bytes FreeRDP sends for its own disconnects, which KRdp sends RDPKit too.
@Test func encodesUserRequestedMCSDisconnectProviderUltimatum() throws {
    #expect(MCSDisconnectProviderUltimatumPDU.userRequested.encodedTPKT() == Data([
        0x03, 0x00, 0x00, 0x09,
        0x02, 0xF0, 0x80,
        0x21, 0x80,
    ]))
    for reason in UInt8(0) ... 4 {
        let pdu = MCSDisconnectProviderUltimatumPDU(reason: reason)
        #expect(try MCSDisconnectProviderUltimatumPDU.parseIfPresent(fromTPKT: pdu.encodedTPKT()) == pdu)
    }
}

@Test func ignoresNonDisconnectTPKT() throws {
    #expect(try MCSDisconnectProviderUltimatumPDU.parseIfPresent(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x08,
        0x02, 0xF0, 0x80, 0x28,
    ])) == nil)
}

@Test func rejectsMalformedMCSDisconnectProviderUltimatumPadding() throws {
    #expect(throws: RDPDecodeError.invalidMCSSendDataIndication) {
        try MCSDisconnectProviderUltimatumPDU.parseIfPresent(fromTPKT: Data([
            0x03, 0x00, 0x00, 0x09,
            0x02, 0xF0, 0x80,
            0x21, 0x81,
        ]))
    }
}

@Test func parsesEveryMCSDisconnectProviderUltimatumReason() throws {
    // T.125 Reason is a 3-bit PER enumeration after the 6-bit choice (8).
    let expectations: [(bytes: [UInt8], name: String)] = [
        ([0x20, 0x00], "rn-domain-disconnected"),
        ([0x20, 0x80], "rn-provider-initiated"),
        ([0x21, 0x00], "rn-token-purged"),
        ([0x21, 0x80], "rn-user-requested"),
        ([0x22, 0x00], "rn-channel-purged"),
    ]
    for (reason, expectation) in expectations.enumerated() {
        let pdu = try #require(try MCSDisconnectProviderUltimatumPDU.parseIfPresent(
            fromTPKT: Data([0x03, 0x00, 0x00, 0x09, 0x02, 0xF0, 0x80] + expectation.bytes)
        ))
        #expect(pdu.reason == UInt8(reason))
        #expect(pdu.reasonName == expectation.name)
    }
}

@Test func parsesMCSDisconnectProviderUltimatumFromDataSlice() throws {
    let buffer = Data([0xFF, 0x03, 0x00, 0x00, 0x09, 0x02, 0xF0, 0x80, 0x21, 0x80])
    let pdu = try #require(try MCSDisconnectProviderUltimatumPDU.parseIfPresent(fromTPKT: buffer.dropFirst()))

    #expect(pdu.reason == 3)
}
