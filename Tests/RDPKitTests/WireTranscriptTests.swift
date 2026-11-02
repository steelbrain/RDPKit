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

    let redacted = packet.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID)

    #expect(redacted.count == packet.count)
    #expect(redacted.range(of: password) == nil)
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: redacted)
    let redirection = try #require(try RDPServerRedirectionPDU.parseIfPresent(from: indication))
    #expect(redirection.passwordCookie == Data(count: password.count))
    #expect(redirection.loadBalanceInfo == Data("Cookie: msts=3640205228.15629.0000\r\n".utf8))
}

/// A field the same as the password, length included, is zeroed with it: a server that sends
/// the user name as the cleartext password must not leave the Password field in the clear.
@Test func redactionZeroesEveryFieldEqualToTheRedirectionPassword() throws {
    let password = utf16LittleEndian("test", nullTerminated: true)
    let packet = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        username: password,
        password: password
    ))

    let redacted = packet.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID)

    #expect(redacted.count == packet.count)
    #expect(redacted.range(of: password) == nil)
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: redacted)
    let redirection = try #require(try RDPServerRedirectionPDU.parseIfPresent(from: indication))
    #expect(redirection.passwordCookie == Data(count: password.count))
    #expect(redirection.loadBalanceInfo == Data("Cookie: msts=3640205228.15629.0000\r\n".utf8))
}

/// A Password field whose bytes repeat its length overlaps an earlier match: after a user name
/// that ends in the same four bytes, the first match runs into the password and the next one
/// starts inside it.
@Test func redactionZeroesARedirectionPasswordOverlappingAnEarlierMatch() throws {
    let length = Data([8, 0, 0, 0])
    let password = length + length
    let packet = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        username: length,
        password: password
    ))

    let redacted = packet.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID)

    // Read in full: the load balance info before the user name is kept.
    #expect(redacted.range(of: Data("Cookie: msts=".utf8)) != nil)
    #expect(redacted.count == packet.count)
    #expect(packet.suffix(password.count) == password)
    #expect(redacted.suffix(password.count).allSatisfy { $0 == 0 })
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
        let redacted = packet.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID)

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

    let redacted = packet.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID)

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

    let redacted = packet.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID)

    #expect(redacted.count == packet.count)
    let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: redacted)
    let shareData = try #require(try RDPShareDataPDU.parseIfPresent(from: indication))
    #expect(shareData.saveSessionInfo?.autoReconnectPacket?.arcRandomBits == Data(count: 16))
    #expect(shareData.saveSessionInfo?.autoReconnectPacket?.logonID == 2)
}

@Test func redactionLeavesOtherPacketsAlone() throws {
    let demandActive = try #require(KRdpCapture.events().first { $0.sequence == 19 }?.bytes)

    #expect(demandActive.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID) == demandActive)
    #expect(KRdpCapture.pointerHidden.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID) == KRdpCapture.pointerHidden)
}

/// Static channel chunks whose CHANNEL_PDU_HEADER length reads as a Share Control type: byte 2
/// of a 0x0A2000-byte message's is a redirection's 0x0A, and a 0x071000-byte message's is a
/// Share Data PDU's 0x07 with pduType2 0x26, a Save Session Info's, where its byte 14 falls.
private let staticChunksThatReadAsSecrets: [Data] = ([0x000A_2000, 0x0007_1000] as [UInt32]).map { length in
    var userData = Data()
    userData.appendLittleEndianUInt32(length)
    userData.appendLittleEndianUInt32(0x0000_0001) // CHANNEL_FLAG_FIRST
    userData.append(Data([1, 2, 3, 4, 5, 6, 0x26] + (8 ... 64).map { UInt8($0) }))
    return mcsSendDataIndication(channelID: 1010, userData: userData)
}

/// A Server Redirection and a Save Session Info are Share Control PDUs on the I/O channel
/// ([MS-RDPBCGR] 2.2.13.3, 2.2.10.1), so data on another channel is kept whole.
@Test func redactionKeepsStaticChannelData() throws {
    let transcript = RDPWireTranscript()
    transcript.noteIOChannel(KRdpCapture.ioChannelID)
    for chunk in staticChunksThatReadAsSecrets {
        transcript.record(direction: .serverToClient, layer: .application, bytes: chunk, capturePayload: true)
    }

    for chunk in staticChunksThatReadAsSecrets {
        #expect(chunk.redactingServerSecrets(ioChannelID: KRdpCapture.ioChannelID) == chunk)
    }
    #expect(transcript.events.map(\.bytes) == staticChunksThatReadAsSecrets)
}

/// A session's transcript redacts on the I/O channel its MCS Connect Response named, and
/// keeps other channels' data whole.
@Test func sessionTranscriptRedactsOnlyTheIOChannel() throws {
    let password = utf16LittleEndian("S3cret!", nullTerminated: true)
    let redirection = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.noRedirect.rawValue | RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue,
        password: password
    ))
    let transcript = RDPWireTranscript()

    let run = try KRdpCapture.run(
        appending: [redirection] + staticChunksThatReadAsSecrets + [KRdpCapture.emptyGraphicsFrame(id: 1)],
        frameCaptureLimit: 2,
        wireTranscript: transcript
    )

    #expect(run.report.error == nil)
    let recorded = transcript.events.compactMap(\.bytes)
    #expect(recorded.contains { $0.count == redirection.count && $0.prefix(20) == redirection.prefix(20) })
    #expect(!recorded.contains { $0.range(of: password) != nil })
    for chunk in staticChunksThatReadAsSecrets {
        #expect(recorded.contains(chunk))
    }
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
