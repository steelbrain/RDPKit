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
