import Foundation
@testable import RDPKit
import Testing

@Test func mcsErectDomainRequestMatchesAnnotatedBytes() {
    #expect(MCSErectDomainRequestPDU().encodedTPKT() == Data([
        0x03, 0x00, 0x00, 0x0C,
        0x02, 0xF0, 0x80,
        0x04, 0x01, 0x00, 0x01, 0x00,
    ]))
}

@Test func mcsAttachUserRequestMatchesAnnotatedBytes() {
    #expect(MCSAttachUserRequestPDU().encodedTPKT() == Data([
        0x03, 0x00, 0x00, 0x08,
        0x02, 0xF0, 0x80,
        0x28,
    ]))
}

@Test func parsesMCSAttachUserConfirmUserChannel() throws {
    let confirm = try MCSAttachUserConfirm.parse(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x0B,
        0x02, 0xF0, 0x80,
        0x2E, 0x00, 0x00, 0x06,
    ]))

    #expect(confirm.result == 0)
    #expect(confirm.resultName == "rt-successful")
    #expect(confirm.userChannelID == 1007)
}

@Test func mcsChannelJoinRequestMatchesAnnotatedBytes() {
    let request = MCSChannelJoinRequestPDU(initiator: 1007, channelID: 1004)

    #expect(request.encodedTPKT() == Data([
        0x03, 0x00, 0x00, 0x0C,
        0x02, 0xF0, 0x80,
        0x38, 0x00, 0x06, 0x03, 0xEC,
    ]))
}

@Test func parsesMCSChannelJoinConfirm() throws {
    let confirm = try MCSChannelJoinConfirm.parse(fromTPKT: Data([
        0x03, 0x00, 0x00, 0x0F,
        0x02, 0xF0, 0x80,
        0x3E, 0x00, 0x00, 0x06, 0x03, 0xEC, 0x03, 0xEC,
    ]))

    #expect(confirm.result == 0)
    #expect(confirm.resultName == "rt-successful")
    #expect(confirm.initiator == 1007)
    #expect(confirm.requestedChannelID == 1004)
    #expect(confirm.channelID == 1004)
}
