import Foundation
@testable import RDPKit
import Testing

@Test func parsesSuccessfulMCSConnectResponseServerChannels() throws {
    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(messageChannelBody: Data([0xED, 0x03])),
        requestedChannels: [.drdynvc],
        expectedMessageChannelAdvertised: true
    )

    #expect(response.result == 0)
    #expect(response.resultName == "rt-successful")
    #expect(response.calledConnectID == 0)
    #expect(response.serverUserDataKey == "McDn")
    #expect(response.clientRequestedProtocols == [.tls, .credSSP])
    #expect(response.ioChannelID == 1003)
    #expect(response.messageChannelID == 1005)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
    ])
    #expect(response.serverCertificatePublicKey == nil)
}

@Test func rejectsMCSConnectResponseWithWrongApplicationType() throws {
    let packet = TPKT.wrap(Data([0x02, 0xF0, 0x80, 0x7F, 0x65, 0x00]))

    do {
        _ = try MCSConnectResponse.parse(fromTPKT: packet)
        Issue.record("expected invalid MCS Connect Response header")
    } catch RDPDecodeError.invalidMCSConnectResponseHeader {
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func rejectsMCSConnectResponseWithoutServerH221Key() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(serverH221Key: Data([0x44, 0x75, 0x63, 0x61])),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func acceptsMCSConnectResponseWithMatchingClientRequestedProtocols() throws {
    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(),
        requestedChannels: [.drdynvc],
        expectedRequestedProtocols: [.tls, .credSSP]
    )

    #expect(response.clientRequestedProtocols == [.tls, .credSSP])
}

@Test func parsesMCSConnectResponseServerEarlyCapabilityFlags() throws {
    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(serverEarlyCapabilityFlags: 0x0000_0008),
        requestedChannels: [.drdynvc],
        expectedRequestedProtocols: [.tls, .credSSP]
    )

    #expect(response.serverEarlyCapabilityFlags == 0x0000_0008)
    #expect(response.serverSupportsSkipChannelJoin)
}

@Test func rejectsMCSConnectResponseWithMismatchedClientRequestedProtocols() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(clientRequestedProtocols: [.tls]),
            requestedChannels: [.drdynvc],
            expectedRequestedProtocols: [.tls, .credSSP]
        )
    }
}

@Test func rejectsMCSConnectResponseWithEnhancedSecurityEncryption() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(serverSecurityBody: Data([
                0x02, 0x00, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00,
                0x20, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ]) + Data(repeating: 0, count: 32)),
            requestedChannels: [.drdynvc],
            expectedRequestedProtocols: [.tls, .credSSP]
        )
    }
}

@Test func rejectsMCSConnectResponseWithInvalidServerSecurityData() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(serverSecurityBody: Data([
                0x04, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ])),
            requestedChannels: [.drdynvc]
        )
    }
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(serverSecurityBody: Data([
                0x02, 0x00, 0x00, 0x00,
                0x02, 0x00, 0x00, 0x00,
                0x1F, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
            ]) + Data(repeating: 0, count: 31)),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func parsesMCSConnectResponseWithStandardSecurityCertificate() throws {
    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(
            clientRequestedProtocols: nil,
            serverSecurityBody: standardSecurityBody(certificate: proprietaryServerCertificate())
        ),
        requestedChannels: [.drdynvc],
        expectedRequestedProtocols: RDPSecurityProtocols(rawValue: 0)
    )

    #expect(response.ioChannelID == 1003)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
    ])
    let publicKey = try #require(response.serverCertificatePublicKey)
    #expect(publicKey.publicExponent == 0x0001_0001)
    #expect(publicKey.modulus.count == 64)
    #expect(publicKey.keyByteCount == 72)
}

@Test func rejectsMCSConnectResponseWithMalformedProprietaryServerCertificate() {
    var badMagicCertificate = proprietaryServerCertificate()
    badMagicCertificate[badMagicCertificate.index(badMagicCertificate.startIndex, offsetBy: 16)] = 0
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(
                clientRequestedProtocols: nil,
                serverSecurityBody: standardSecurityBody(certificate: badMagicCertificate)
            ),
            requestedChannels: [.drdynvc]
        )
    }

    var badPaddingCertificate = proprietaryServerCertificate()
    badPaddingCertificate[badPaddingCertificate.index(badPaddingCertificate.startIndex, offsetBy: 100)] = 1
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(
                clientRequestedProtocols: nil,
                serverSecurityBody: standardSecurityBody(certificate: badPaddingCertificate)
            ),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseWithMalformedX509ServerCertificateChain() {
    var certificate = Data()
    certificate.appendLittleEndianUInt32(2)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(3)
    certificate.append(contentsOf: [0x30, 0x01, 0x00])
    certificate.append(Data(repeating: 0, count: 12))

    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(
                clientRequestedProtocols: nil,
                serverSecurityBody: standardSecurityBody(certificate: certificate)
            ),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func assumesAbsentMCSConnectResponseClientRequestedProtocolsIsStandardSecurity() throws {
    let standardSecurity = RDPSecurityProtocols(rawValue: 0)
    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(clientRequestedProtocols: nil),
        requestedChannels: [.drdynvc],
        expectedRequestedProtocols: standardSecurity
    )

    #expect(response.clientRequestedProtocols == nil)
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(clientRequestedProtocols: nil),
            requestedChannels: [.drdynvc],
            expectedRequestedProtocols: [.tls, .credSSP]
        )
    }
}

@Test func rejectsMCSConnectResponseWithMoreServerChannelsThanRequested() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(channelIDs: [1004, 1005]),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseWithFewerServerChannelsThanRequested() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(channelIDs: [1004]),
            requestedChannels: [.drdynvc, .cliprdr]
        )
    }
}

@Test func rejectsMCSConnectResponseServerNetworkDataWithInvalidPadding() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(channelIDs: [1004], includePad: false),
            requestedChannels: [.drdynvc]
        )
    }
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(channelIDs: [1004, 1005], includePad: true),
            requestedChannels: [.drdynvc, .cliprdr]
        )
    }
}

@Test func rejectsMCSConnectResponseWithInvalidServerNetworkLength() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(serverNetworkBody: Data([0xEB, 0x03])),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseWithInvalidMessageChannelLength() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(messageChannelBody: Data([0xED, 0x03, 0x00])),
            requestedChannels: [.drdynvc],
            expectedMessageChannelAdvertised: true
        )
    }
}

@Test func rejectsMCSConnectResponseWithUnadvertisedMessageChannel() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(messageChannelBody: Data([0xED, 0x03])),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func acceptsMCSConnectResponseWithServerMultitransportData() throws {
    var multitransport = Data()
    multitransport.appendLittleEndianUInt16(0x0C08)
    multitransport.appendLittleEndianUInt16(8)
    multitransport.appendLittleEndianUInt32(0x0000_0105)

    let response = try MCSConnectResponse.parse(
        fromTPKT: sampleMCSConnectResponse(extraServerBlocks: multitransport),
        requestedChannels: [.drdynvc]
    )

    #expect(response.ioChannelID == 1003)
    #expect(response.staticChannelAssignments == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
    ])
}

@Test func rejectsMCSConnectResponseWithInvalidServerMultitransportLength() {
    var multitransport = Data()
    multitransport.appendLittleEndianUInt16(0x0C08)
    multitransport.appendLittleEndianUInt16(7)
    multitransport.append(contentsOf: [0x01, 0x00, 0x00])

    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(extraServerBlocks: multitransport),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseWithDuplicateServerDataBlock() {
    var duplicateSecurity = Data()
    duplicateSecurity.appendLittleEndianUInt16(0x0C02)
    duplicateSecurity.appendLittleEndianUInt16(12)
    duplicateSecurity.append(Data(repeating: 0, count: 8))

    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(extraServerBlocks: duplicateSecurity),
            requestedChannels: [.drdynvc]
        )
    }

    var multitransport = Data()
    multitransport.appendLittleEndianUInt16(0x0C08)
    multitransport.appendLittleEndianUInt16(8)
    multitransport.appendLittleEndianUInt32(0x0000_0001)
    let duplicateMultitransport = multitransport + multitransport

    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(extraServerBlocks: duplicateMultitransport),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseMissingRequiredServerDataBlocks() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(includeServerCoreData: false),
            requestedChannels: [.drdynvc]
        )
    }
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(includeServerNetworkData: false),
            requestedChannels: [.drdynvc]
        )
    }
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(includeServerSecurityData: false),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseWithTrailingServerDataBytes() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(serverBlocksSuffix: Data([0x00])),
            requestedChannels: [.drdynvc]
        )
    }
}

@Test func rejectsMCSConnectResponseWithTrailingGCCUserDataBytes() {
    #expect(throws: RDPDecodeError.invalidMCSConnectResponseHeader) {
        try MCSConnectResponse.parse(
            fromTPKT: sampleMCSConnectResponse(gccUserDataSuffix: Data([0x00])),
            requestedChannels: [.drdynvc]
        )
    }
}

private func sampleMCSConnectResponse(
    channelIDs: [UInt16] = [1004],
    includePad: Bool? = nil,
    clientRequestedProtocols: RDPSecurityProtocols? = [.tls, .credSSP],
    serverEarlyCapabilityFlags: UInt32? = nil,
    serverSecurityBody: Data = Data(repeating: 0, count: 8),
    serverNetworkBody overrideServerNetworkBody: Data? = nil,
    messageChannelBody: Data? = nil,
    includeServerCoreData: Bool = true,
    includeServerNetworkData: Bool = true,
    includeServerSecurityData: Bool = true,
    extraServerBlocks: Data = Data(),
    serverBlocksSuffix: Data = Data(),
    serverH221Key: Data = Data([0x4D, 0x63, 0x44, 0x6E]),
    gccUserDataSuffix: Data = Data()
) -> Data {
    let domainParameters = Data([
        0x30, 0x1A,
        0x02, 0x01, 0x22,
        0x02, 0x01, 0x03,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x01,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x01,
        0x02, 0x03, 0x00, 0xFF, 0xF8,
        0x02, 0x01, 0x02,
    ])
    let padNeeded = !channelIDs.count.isMultiple(of: 2)
    let includePad = includePad ?? padNeeded
    let serverNetworkBody = overrideServerNetworkBody ?? {
        var body = Data()
        body.appendLittleEndianUInt16(1003)
        body.appendLittleEndianUInt16(UInt16(channelIDs.count))
        for channelID in channelIDs {
            body.appendLittleEndianUInt16(channelID)
        }
        if includePad {
            body.appendLittleEndianUInt16(0)
        }
        return body
    }()
    var serverNetworkData = Data()
    serverNetworkData.appendLittleEndianUInt16(0x0C03)
    serverNetworkData.appendLittleEndianUInt16(UInt16(serverNetworkBody.count + 4))
    serverNetworkData.append(serverNetworkBody)
    var serverMessageChannelData = Data()
    if let messageChannelBody {
        serverMessageChannelData.appendLittleEndianUInt16(0x0C04)
        serverMessageChannelData.appendLittleEndianUInt16(UInt16(messageChannelBody.count + 4))
        serverMessageChannelData.append(messageChannelBody)
    }
    var serverCoreData = Data()
    serverCoreData.appendLittleEndianUInt16(0x0C01)
    let serverCoreBodyLength = 4
        + (clientRequestedProtocols == nil ? 0 : 4)
        + (serverEarlyCapabilityFlags == nil ? 0 : 4)
    serverCoreData.appendLittleEndianUInt16(UInt16(serverCoreBodyLength + 4))
    serverCoreData.appendLittleEndianUInt32(0x0008_0005)
    if let clientRequestedProtocols {
        serverCoreData.appendLittleEndianUInt32(clientRequestedProtocols.rawValue)
    }
    if let serverEarlyCapabilityFlags {
        serverCoreData.appendLittleEndianUInt32(serverEarlyCapabilityFlags)
    }
    var serverSecurityData = Data()
    serverSecurityData.appendLittleEndianUInt16(0x0C02)
    serverSecurityData.appendLittleEndianUInt16(UInt16(serverSecurityBody.count + 4))
    serverSecurityData.append(serverSecurityBody)
    var serverBlocks = Data()
    if includeServerCoreData {
        serverBlocks.append(serverCoreData)
    }
    if includeServerNetworkData {
        serverBlocks.append(serverNetworkData)
    }
    if includeServerSecurityData {
        serverBlocks.append(serverSecurityData)
    }
    serverBlocks.append(serverMessageChannelData)
    serverBlocks.append(extraServerBlocks)
    serverBlocks.append(serverBlocksSuffix)
    var gccConnectData = Data([
        0x00, 0x05,
        0x00, 0x14, 0x7C, 0x00, 0x01,
        0x2A,
        0x14, 0x76, 0x0A, 0x01, 0x01, 0x00, 0x01, 0xC0, 0x00,
    ])
    gccConnectData.append(serverH221Key)
    gccConnectData.appendPERLength(serverBlocks.count)
    gccConnectData.append(serverBlocks)
    gccConnectData.append(gccUserDataSuffix)

    var mcsFields = Data()
    mcsFields.append(contentsOf: [0x0A, 0x01, 0x00])
    mcsFields.append(contentsOf: [0x02, 0x01, 0x00])
    mcsFields.append(domainParameters)
    mcsFields.append(berOctetString(gccConnectData))

    var mcs = Data()
    mcs.append(contentsOf: [0x7F, 0x66])
    mcs.append(berLength(mcsFields.count))
    mcs.append(mcsFields)

    return TPKT.wrap(Data([0x02, 0xF0, 0x80]) + mcs)
}

private func standardSecurityBody(certificate: Data) -> Data {
    var body = Data()
    body.appendLittleEndianUInt32(0x0000_0002)
    body.appendLittleEndianUInt32(0x0000_0002)
    body.appendLittleEndianUInt32(32)
    body.appendLittleEndianUInt32(UInt32(certificate.count))
    body.append(Data(repeating: 0x11, count: 32))
    body.append(certificate)
    return body
}

private func proprietaryServerCertificate() -> Data {
    var publicKey = Data()
    publicKey.appendLittleEndianUInt32(0x3141_5352)
    publicKey.appendLittleEndianUInt32(72)
    publicKey.appendLittleEndianUInt32(512)
    publicKey.appendLittleEndianUInt32(63)
    publicKey.appendLittleEndianUInt32(0x0001_0001)
    publicKey.append(Data(repeating: 0xA5, count: 64))
    publicKey.append(Data(repeating: 0, count: 8))

    var certificate = Data()
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt16(0x0006)
    certificate.appendLittleEndianUInt16(UInt16(publicKey.count))
    certificate.append(publicKey)
    certificate.appendLittleEndianUInt16(0x0008)
    certificate.appendLittleEndianUInt16(72)
    certificate.append(Data(repeating: 0x5A, count: 72))
    return certificate
}

private func berOctetString(_ value: Data) -> Data {
    var data = Data([0x04])
    data.append(berLength(value.count))
    data.append(value)
    return data
}

private func berLength(_ length: Int) -> Data {
    if length < 0x80 {
        return Data([UInt8(length)])
    }

    return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
}
