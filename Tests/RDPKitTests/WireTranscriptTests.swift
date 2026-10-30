import Foundation
@testable import RDPKit
import Testing

/// A Server Redirection PDU's Password field is a cleartext password unless
/// PK-encrypted ([MS-RDPBCGR] 2.2.13.1); transcripts and report hex zero it.
@Test func redactionZeroesTheRedirectionPassword() throws {
    let password = utf16LittleEndian("S3cret!", nullTerminated: true)
    let packet = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        password: password
    ))

    let redacted = packet.redactingServerSecrets

    #expect(redacted.count == packet.count)
    #expect(redacted.range(of: password) == nil)
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: redacted)
    let redirection = try #require(try RDPServerRedirectionPDU.parseIfPresent(from: indication))
    #expect(redirection.passwordCookie == Data(count: password.count))
    #expect(redirection.loadBalanceInfo == Data("Cookie: msts=3640205228.15629.0000\r\n".utf8))
}

/// A redirection this client does not read in full, for a flag it does not know or bytes it
/// cannot place, may hold the password anywhere after RedirFlags, so all of that is zeroed.
@Test func redactionZeroesARedirectionItCannotReadInFull() throws {
    let password = utf16LittleEndian("S3cret!", nullTerminated: true)
    let loadBalanceInfo = RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue
    let packets = [
        KRdpCapture.ioPacket(KRdpCapture.redirection(flags: loadBalanceInfo | 0x0400, password: password)),
        KRdpCapture.ioPacket(KRdpCapture.redirection(flags: loadBalanceInfo, password: password, trailingBytes: Data([1, 2, 3]))),
    ]
    for packet in packets {
        let redacted = packet.redactingServerSecrets

        #expect(redacted.count == packet.count)
        #expect(redacted.range(of: password) == nil)
        let redirFlags = try #require(packet.range(of: Data([0x07, 0x00, 0x00, 0x00]))).upperBound
        #expect(redacted.prefix(upTo: redirFlags + 4) == packet.prefix(upTo: redirFlags + 4))
        #expect(redacted.suffix(from: redirFlags + 4).allSatisfy { $0 == 0 })
    }
}

/// A Save Session Info PDU this client cannot read may hold an auto-reconnect cookie, so
/// everything after its Share Data header is zeroed.
@Test func redactionZeroesASaveSessionInfoItCannotRead() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(0x0000_0003)
    payload.appendLittleEndianUInt16(38)
    payload.append(Data((1 ... 30).map { UInt8($0) }))
    let packet = KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x26, payload: payload))

    let redacted = packet.redactingServerSecrets

    #expect(redacted.count == packet.count)
    #expect(redacted.suffix(payload.count).allSatisfy { $0 == 0 })
    #expect(redacted.dropLast(payload.count) == packet.dropLast(payload.count))
}

/// The auto-reconnect cookie reconnects to the session without a password
/// ([MS-RDPBCGR] 2.2.4.2, 5.5).
@Test func redactionZeroesTheAutoReconnectCookie() throws {
    let randomBits = Data((1 ... 16).map { UInt8($0 * 11) })
    var payload = Data()
    payload.appendLittleEndianUInt32(0x0000_0003)
    payload.appendLittleEndianUInt16(38)
    payload.appendLittleEndianUInt32(0x0000_0001)
    payload.appendLittleEndianUInt32(28)
    payload.appendLittleEndianUInt32(28)
    payload.appendLittleEndianUInt32(1)
    payload.appendLittleEndianUInt32(2)
    payload.append(randomBits)
    payload.append(Data(repeating: 0, count: 570))
    let packet = KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x26, payload: payload))

    let redacted = packet.redactingServerSecrets

    #expect(redacted.count == packet.count)
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: redacted)
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(from: indication))
    #expect(shareData.saveSessionInfo?.autoReconnectPacket?.arcRandomBits == Data(count: 16))
    #expect(shareData.saveSessionInfo?.autoReconnectPacket?.logonID == 2)
}

@Test func redactionLeavesOtherPacketsAlone() throws {
    let demandActive = try #require(KRdpCapture.events().first { $0.sequence == 19 }?.bytes)

    #expect(demandActive.redactingServerSecrets == demandActive)
    #expect(KRdpCapture.pointerHidden.redactingServerSecrets == KRdpCapture.pointerHidden)
}

@Test func transcriptRedactsServerSecretsAndStopsAtItsCap() throws {
    let password = Data("hunter2\0".utf8)
    let redirection = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        password: password
    ))
    let transcript = RDPWireTranscript(maximumPayloadByteCount: redirection.count + 10)

    transcript.record(direction: .serverToClient, layer: .application, bytes: redirection, capturePayload: true)
    transcript.record(direction: .clientToServer, layer: .application, bytes: Data(count: 500), capturePayload: false)
    transcript.record(direction: .serverToClient, layer: .application, bytes: Data(count: 11), capturePayload: true)
    transcript.recordMarker(direction: .clientToServer, layer: .security)

    let events = transcript.events
    #expect(events.map(\.sequence) == [0, 1])
    #expect(events.map(\.byteCount) == [redirection.count, 500])
    let recorded = try #require(events.first?.bytes)
    #expect(recorded.count == redirection.count)
    #expect(recorded.range(of: password) == nil)
    #expect(events.last?.hex == nil)
}
