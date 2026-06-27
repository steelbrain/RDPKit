import Foundation
@testable import RDPKit
import Testing

@Test func tpktWrapsPayloadWithExpectedHeader() throws {
    let packet = TPKT.wrap(Data([0x01, 0x02, 0x03]))

    #expect(packet == Data([0x03, 0x00, 0x00, 0x07, 0x01, 0x02, 0x03]))
    #expect(try TPKT.unwrap(packet) == Data([0x01, 0x02, 0x03]))
}

@Test func x224ConnectionRequestMatchesRdpNegotiationBytes() {
    let request = X224ConnectionRequest(
        negotiationRequest: RDPNegotiationRequest(requestedProtocols: [.tls, .credSSP])
    )

    #expect(request.encodedTPKT() == Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ]))
}

@Test func x224ConnectionRequestCanCarryRoutingToken() {
    let routingToken = Data("Cookie: mststs=1183689379\r\n".utf8)
    let request = X224ConnectionRequest(
        routingToken: routingToken,
        negotiationRequest: RDPNegotiationRequest(requestedProtocols: [.credSSP])
    )
    let packet = request.encodedTPKT()

    #expect(packet.prefix(11) == Data([
        0x03, 0x00, 0x00, 0x2d,
        0x28, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]))
    #expect(packet.dropFirst(11).prefix(routingToken.count) == routingToken)
    #expect(packet.suffix(8) == Data([
        0x01, 0x00, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ]))
}

@Test func parsesX224ConnectionConfirmWithTlsSelection() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.destinationReference == 0)
    #expect(confirm.sourceReference == 0x1234)
    #expect(confirm.negotiationFlags == 0)
    #expect(confirm.negotiationResult == .selected(.tls))
}

@Test func parsesX224ConnectionConfirmWithCredSSPSelection() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0)
    #expect(confirm.negotiationResult == .selected(.credSSP))
}

@Test func parsesNegotiationFailureCode() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0)
    #expect(confirm.negotiationResult == .failure(2))
}

@Test func preservesNegotiationResponseFlags() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x0B, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0x0B)
    #expect(confirm.negotiationResult == .selected(.tls))
}

@Test func rejectsConnectionConfirmWhenX224LengthDoesNotMatchPayload() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x14,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xFF,
    ])

    do {
        _ = try X224ConnectionConfirm.parse(fromTPKT: packet)
        Issue.record("expected invalid X.224 length")
    } catch RDPDecodeError.invalidX224Length(declared: 15, actual: 16) {
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
