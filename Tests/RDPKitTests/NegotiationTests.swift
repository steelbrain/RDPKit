import Foundation
@testable import RDPKit
import Testing

@Test func tpktWrapsPayloadWithExpectedHeader() throws {
    let packet = TPKT.wrap(Data([0x01, 0x02, 0x03]))

    #expect(packet == Data([0x03, 0x00, 0x00, 0x07, 0x01, 0x02, 0x03]))
    #expect(try TPKT.unwrap(packet) == Data([0x01, 0x02, 0x03]))
}

@Test func rejectsTPKTWithNonzeroReservedByte() throws {
    #expect(throws: RDPDecodeError.invalidTPKTReserved(0x01)) {
        try TPKT.unwrap(Data([0x03, 0x01, 0x00, 0x04]))
    }
}

@Test func rejectsTPKTWithLengthSmallerThanHeader() throws {
    #expect(throws: RDPDecodeError.invalidTPKTLength(declared: 3, actual: 4)) {
        try TPKT.unwrap(Data([0x03, 0x00, 0x00, 0x03]))
    }
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

@Test func rdpSecurityProtocolConstantsMatchNegotiationSpecValues() {
    #expect(RDPSecurityProtocols.tls.rawValue == 0x0000_0001)
    #expect(RDPSecurityProtocols.credSSP.rawValue == 0x0000_0002)
    #expect(RDPSecurityProtocols.rdSTLS.rawValue == 0x0000_0004)
    #expect(RDPSecurityProtocols.credSSPWithEarlyUserAuth.rawValue == 0x0000_0008)
    #expect(RDPSecurityProtocols.rdsAAD.rawValue == 0x0000_0010)
}

@Test func rdpNegotiationRequestFlagConstantsMatchSpecValues() {
    #expect(RDPNegotiationRequestFlags.restrictedAdminModeRequired == 0x01)
    #expect(RDPNegotiationRequestFlags.redirectedAuthenticationModeRequired == 0x02)
    #expect(RDPNegotiationRequestFlags.correlationInfoPresent == 0x08)
    #expect(RDPNegotiationRequestFlags.supportedMask == 0x0B)
}

@Test func rdpNegotiationResponseFlagConstantsMatchSpecValues() {
    #expect(RDPNegotiationResponseFlags.extendedClientDataSupported == 0x01)
    #expect(RDPNegotiationResponseFlags.dynamicVirtualChannelGraphicsSupported == 0x02)
    #expect(RDPNegotiationResponseFlags.reserved == 0x04)
    #expect(RDPNegotiationResponseFlags.restrictedAdminModeSupported == 0x08)
    #expect(RDPNegotiationResponseFlags.redirectedAuthenticationModeSupported == 0x10)
    #expect(RDPNegotiationResponseFlags.supportedMask == 0x1F)
}

@Test func rdpNegotiationRequestEncodesRDSTLSWithSpecValue() {
    let request = RDPNegotiationRequest(requestedProtocols: [.rdSTLS])

    #expect(request.encoded() == Data([
        0x01, 0x00, 0x08, 0x00,
        0x04, 0x00, 0x00, 0x00,
    ]))
}

@Test func rdpNegotiationRequestIncludesTLSWhenCredSSPIsRequested() {
    let request = RDPNegotiationRequest(requestedProtocols: [.credSSP])

    #expect(request.requestedProtocols == [.tls, .credSSP])
    #expect(request.encoded() == Data([
        0x01, 0x00, 0x08, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ]))
}

@Test func rdpNegotiationRequestIncludesCredSSPAndTLSWhenEarlyUserAuthIsRequested() {
    let request = RDPNegotiationRequest(requestedProtocols: [.credSSPWithEarlyUserAuth])

    #expect(request.requestedProtocols == [.tls, .credSSP, .credSSPWithEarlyUserAuth])
    #expect(request.encoded() == Data([
        0x01, 0x00, 0x08, 0x00,
        0x0B, 0x00, 0x00, 0x00,
    ]))
}

@Test func requestedSecurityProtocolsValidateServerSelection() {
    let requested: RDPSecurityProtocols = [.tls, .credSSP]

    #expect(requested.canSelect(.tls))
    #expect(requested.canSelect(.credSSP))
    #expect(requested.canSelect(RDPSecurityProtocols(rawValue: 0)))
    #expect(!requested.canSelect(.rdSTLS))
    #expect(!requested.canSelect([.tls, .credSSP]))
}

@Test func securityProtocolPredicatesTreatHybridExAsCredSSPFamily() {
    #expect(RDPSecurityProtocols.credSSPWithEarlyUserAuth.usesTLS)
    #expect(RDPSecurityProtocols.credSSPWithEarlyUserAuth.usesCredSSP)
    #expect(RDPSecurityProtocols.credSSP.usesTLS)
    #expect(RDPSecurityProtocols.credSSP.usesCredSSP)
    #expect(RDPSecurityProtocols.tls.usesTLS)
    #expect(!RDPSecurityProtocols.tls.usesCredSSP)
}

@Test func parsesEarlyUserAuthorizationResults() throws {
    let success = try RDPEarlyUserAuthorizationResultPDU.parse(Data([0x00, 0x00, 0x00, 0x00]))
    #expect(success.rawValue == 0x0000_0000)
    #expect(success.result == .success)

    let denied = try RDPEarlyUserAuthorizationResultPDU.parse(Data([0x05, 0x00, 0x00, 0x00]))
    #expect(denied.rawValue == 0x0000_0005)
    #expect(denied.result == .accessDenied)
}

@Test func rejectsMalformedEarlyUserAuthorizationResults() {
    #expect(throws: RDPDecodeError.invalidNegotiationLength(3)) {
        try RDPEarlyUserAuthorizationResultPDU.parse(Data([0x00, 0x00, 0x00]))
    }
    #expect(throws: RDPDecodeError.invalidNegotiationProtocol(1)) {
        try RDPEarlyUserAuthorizationResultPDU.parse(Data([0x01, 0x00, 0x00, 0x00]))
    }
}

@Test func x224ConnectionRequestCanCarryRoutingToken() {
    let routingToken = Data("Cookie: mststs=1183689379\r\n".utf8)
    let request = X224ConnectionRequest(
        routingToken: routingToken,
        negotiationRequest: RDPNegotiationRequest(requestedProtocols: [.credSSP])
    )
    let packet = request.encodedTPKT()

    #expect(packet.prefix(11) == Data([
        0x03, 0x00, 0x00, 0x2e,
        0x29, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]))
    #expect(packet.dropFirst(11).prefix(routingToken.count) == routingToken)
    #expect(packet.suffix(8) == Data([
        0x01, 0x00, 0x08, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ]))
}

@Test func x224ConnectionRequestTerminatesRoutingTokenWithCRLF() {
    let routingToken = Data("Cookie: mststs=1183689379".utf8)
    let request = X224ConnectionRequest(
        routingToken: routingToken,
        negotiationRequest: RDPNegotiationRequest(requestedProtocols: [.tls])
    )
    let packet = request.encodedTPKT()

    #expect(packet.prefix(11) == Data([
        0x03, 0x00, 0x00, 0x2e,
        0x29, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]))
    #expect(packet.dropFirst(11).prefix(routingToken.count + 2) == Data("Cookie: mststs=1183689379\r\n".utf8))
    #expect(packet.suffix(8) == Data([
        0x01, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ]))
}

@Test func x224ConnectionRequestCanCarryCorrelationInfo() {
    let correlationID = Data(0x10 ..< 0x20)
    let request = X224ConnectionRequest(
        negotiationRequest: RDPNegotiationRequest(requestedProtocols: [.tls]),
        correlationID: correlationID
    )
    let packet = request.encodedTPKT()

    #expect(packet.prefix(11) == Data([
        0x03, 0x00, 0x00, 0x37,
        0x32, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]))
    #expect(packet.dropFirst(11).prefix(8) == Data([
        0x01, 0x08, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ]))
    #expect(packet.dropFirst(19).prefix(20) == Data([
        0x06, 0x00, 0x24, 0x00,
        0x10, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B,
        0x1C, 0x1D, 0x1E, 0x1F,
    ]))
    #expect(packet.suffix(16) == Data(repeating: 0, count: 16))
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

@Test func parsesX224ConnectionConfirmWithRDSAADSelection() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x10, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0)
    #expect(confirm.negotiationResult == .selected(.rdsAAD))
    #expect(confirm.negotiationResult?.selectedProtocolNames == ["rds-aad"])
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

@Test func parsesX224ConnectionConfirmWithStandardSecuritySelection() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0)
    #expect(confirm.negotiationResult == .selected(RDPSecurityProtocols(rawValue: 0)))
    #expect(confirm.negotiationResult?.selectedProtocolNames == ["standard-rdp-security"])
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

@Test func preservesReservedNegotiationResponseFlag() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x04, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == RDPNegotiationResponseFlags.reserved)
    #expect(confirm.negotiationResult == .selected(.tls))
}

@Test func acceptsAllDefinedNegotiationResponseFlags() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x1F, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == RDPNegotiationResponseFlags.supportedMask)
    #expect(confirm.negotiationResult == .selected(.tls))
}

@Test func parsesWindows11NegotiationResponseFlags() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x2F, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0x2F)
    #expect(confirm.negotiationResult == .selected(.credSSP))
}

@Test func preservesUnknownNegotiationResponseFlags() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x40, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.negotiationFlags == 0x40)
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

@Test func parsesConnectionConfirmWithNonzeroClassAndOptions() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x01,
        0x02, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ])

    let confirm = try X224ConnectionConfirm.parse(fromTPKT: packet)

    #expect(confirm.classAndOptions == 0x01)
    #expect(confirm.negotiationResult == .selected(.tls))
}

@Test func rejectsNegotiationResponseWithTrailingBytes() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x14,
        0x0F, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xFF,
    ])

    #expect(throws: RDPDecodeError.invalidNegotiationLength(9)) {
        try X224ConnectionConfirm.parse(fromTPKT: packet)
    }
}

@Test func rejectsNegotiationResponseWithCombinedSelectedProtocols() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x08, 0x00,
        0x03, 0x00, 0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidNegotiationProtocol(0x0000_0003)) {
        try X224ConnectionConfirm.parse(fromTPKT: packet)
    }
}

@Test func rejectsNegotiationFailureWithNonzeroFlags() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x01, 0x08, 0x00,
        0x02, 0x00, 0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidNegotiationFlags(0x01)) {
        try X224ConnectionConfirm.parse(fromTPKT: packet)
    }
}

@Test func rejectsNegotiationFailureWithUnknownFailureCode() throws {
    let packet = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x08, 0x00,
        0x08, 0x00, 0x00, 0x00,
    ])

    #expect(throws: RDPDecodeError.invalidNegotiationFailureCode(0x0000_0008)) {
        try X224ConnectionConfirm.parse(fromTPKT: packet)
    }
}
