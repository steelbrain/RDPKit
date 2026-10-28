import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL
@testable import RDPKit
import Testing

// Live-session behaviour against the KRdp capture: the recorded negotiation
// (Fixtures/krdp-negotiation-transcript.json) runs up to its first frame, and
// each test appends the server traffic it needs, or scripts the connection
// once the recording ends.

@Test func informationalRedirectionDoesNotEndTheSession() throws {
    // LB_NOREDIRECT: "for informational purposes only" ([MS-RDPBCGR] 2.2.13.1).
    let redirection = KRdpCapture.ioPacket(KRdpCapture.redirection(
        flags: RDPServerRedirectionPDU.Flags.noRedirect.rawValue | RDPServerRedirectionPDU.Flags.loadBalanceInfo.rawValue
    ))
    let run = try KRdpCapture.run(
        appending: [redirection, KRdpCapture.emptyGraphicsFrame(id: 1)],
        frameCaptureLimit: 2
    )

    #expect(run.report.error == nil)
    #expect(run.report.status == "success")
    #expect(run.report.rdpGraphicsFrameAcknowledgeHexes?.count == 2)
    #expect(run.report.warnings.contains { $0.code == "informational-redirection" })
}

@Test func unknownAutoDetectRequestAndMalformedSaveSessionInfoDoNotEndTheSession() throws {
    var unknownAutoDetect = Data()
    unknownAutoDetect.appendLittleEndianUInt16(0x1000) // SEC_AUTODETECT_REQ
    unknownAutoDetect.appendLittleEndianUInt16(0)
    unknownAutoDetect.append(contentsOf: [0x06, 0x00])
    unknownAutoDetect.appendLittleEndianUInt16(0x0042)
    unknownAutoDetect.appendLittleEndianUInt16(0x7777)
    var malformedAutoDetect = Data()
    malformedAutoDetect.appendLittleEndianUInt16(0x1000)
    malformedAutoDetect.appendLittleEndianUInt16(0)
    malformedAutoDetect.append(contentsOf: [0x09, 0x00]) // RTT request headerLength must be 6
    malformedAutoDetect.appendLittleEndianUInt16(0x0043)
    malformedAutoDetect.appendLittleEndianUInt16(0x0001)
    // INFOTYPE_LOGON_LONG with a truncated body ([MS-RDPBCGR] 2.2.10.1.1).
    var saveSessionInfo = Data()
    saveSessionInfo.appendLittleEndianUInt32(0x0000_0001)
    saveSessionInfo.append(Data(repeating: 0, count: 6))

    let run = try KRdpCapture.run(
        appending: [
            KRdpCapture.messageChannelPacket(unknownAutoDetect),
            KRdpCapture.messageChannelPacket(malformedAutoDetect),
            KRdpCapture.ioPacket(KRdpCapture.shareData(pduType2: 0x26, payload: saveSessionInfo)),
            KRdpCapture.emptyGraphicsFrame(id: 1),
        ],
        frameCaptureLimit: 2
    )

    #expect(run.report.error == nil)
    #expect(run.report.rdpGraphicsFrameAcknowledgeHexes?.count == 2)
    #expect(run.report.warnings.contains { $0.code == "auto-detect-error" })
}

// MARK: - KRdp capture harness

/// The KRdp capture's channels: I/O 1003, drdynvc 1004, message 1005, and
/// RDPGFX on dynamic channel 1, all uncompressed.
enum KRdpCapture {
    static let ioChannelID: UInt16 = 1003
    static let drdynvcChannelID: UInt16 = 1004
    static let messageChannelID: UInt16 = 1005
    static let graphicsChannelID: UInt32 = 1

    struct Run {
        var report: RDPPreflightReport
        var clientPackets: [Data]
    }

    static func events() throws -> [RDPWireEvent] {
        let url = try #require(Bundle.module.url(
            forResource: "krdp-negotiation-transcript",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode([RDPWireEvent].self, from: Data(contentsOf: url))
    }

    /// Replays the capture (or its first `prefix` events) followed by
    /// `appending`, then hands the connection to `onEnd`. The run is cancelled
    /// after `guardSeconds` so a hang fails the test instead of stalling it.
    static func run(
        prefix: Int? = nil,
        appending packets: [Data] = [],
        frameCaptureLimit: Int? = 1,
        timeoutSeconds: Int = 10,
        guardSeconds: Double = 20,
        onEnd: (@Sendable (Channel) -> Void)? = nil
    ) throws -> Run {
        var events = try events()
        if let prefix {
            events = Array(events.prefix(prefix))
        }
        for packet in packets {
            events.append(RDPWireEvent(
                sequence: events.count,
                direction: .serverToClient,
                layer: .application,
                byteCount: packet.count,
                hex: packet.rdpHexString
            ))
        }
        let credentials = RDPCredentials(username: "rdp-user", password: "rdp-user")
        let server = try RDPTranscriptReplayServer.start(transcript: events, credentials: credentials, onSegmentEnd: onEnd)
        defer { server.stop() }

        let cancellation = RDPConnectionCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + guardSeconds) {
            cancellation.cancel()
        }
        let report = RDPPreflightClient().run(
            configuration: RDPConnectionConfiguration(
                host: "127.0.0.1",
                port: server.port,
                credentials: credentials,
                timeoutSeconds: timeoutSeconds,
                hideCertificateWarnings: true,
                graphicsFrameCaptureLimit: frameCaptureLimit,
                desktopWidth: 1280,
                desktopHeight: 720,
                clipboardEnabled: false,
                graphicsCapabilityProfile: .avcThinClient
            ),
            cancellation: cancellation
        )
        cancellation.cancel()
        return Run(report: report, clientPackets: server.clientPackets.value)
    }

    /// An MCS Send Data Indication from the capture's server ([MS-RDPBCGR] 2.2.8.1.1.1.2).
    static func packet(channelID: UInt16, userData: Data) -> Data {
        var mcs = Data([0x68, 0x00, 0x05])
        mcs.appendBigEndianUInt16(channelID)
        mcs.appendUInt8(0x70)
        mcs.appendPERLength(userData.count)
        mcs.append(userData)
        return X224DataTPDU.wrap(mcs)
    }

    static func ioPacket(_ userData: Data) -> Data {
        packet(channelID: ioChannelID, userData: userData)
    }

    static func messageChannelPacket(_ userData: Data) -> Data {
        packet(channelID: messageChannelID, userData: userData)
    }

    /// A Share Control PDU of `type` from the server channel ([MS-RDPBCGR] 2.2.8.1.1.1.1).
    static func shareControl(type: UInt16, body: Data) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(UInt16(6 + body.count))
        data.appendLittleEndianUInt16(type | 0x10)
        data.appendLittleEndianUInt16(0x03EA)
        data.append(body)
        return data
    }

    /// A Share Data PDU for the capture's share ([MS-RDPBCGR] 2.2.8.1.1.1.2).
    static func shareData(pduType2: UInt8, payload: Data) -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(shareID)
        body.appendUInt8(0)
        body.appendUInt8(1)
        body.appendLittleEndianUInt16(UInt16(payload.count))
        body.appendUInt8(pduType2)
        body.appendUInt8(0)
        body.appendLittleEndianUInt16(0)
        body.append(payload)
        return shareControl(type: 0x7, body: body)
    }

    static let shareID: UInt32 = 0x0001_03EE

    /// A Server Redirection PDU carrying a routing token ([MS-RDPBCGR] 2.2.13.3.1).
    static func redirection(flags: UInt32, password: Data? = nil) -> Data {
        var fields = Data()
        let cookie = Data("Cookie: msts=3640205228.15629.0000\r\n".utf8)
        fields.appendLittleEndianUInt32(UInt32(cookie.count))
        fields.append(cookie)
        if let password {
            fields.appendLittleEndianUInt32(UInt32(password.count))
            fields.append(password)
        }
        var body = Data()
        body.appendLittleEndianUInt16(0)
        body.appendLittleEndianUInt16(0x0400)
        body.appendLittleEndianUInt16(UInt16(12 + fields.count))
        body.appendLittleEndianUInt32(7)
        body.appendLittleEndianUInt32(flags | (password == nil ? 0 : RDPServerRedirectionPDU.Flags.password.rawValue))
        body.append(fields)
        return shareControl(type: 0xA, body: body)
    }

    /// RDPGFX PDUs on the capture's graphics channel, as one uncompressed
    /// RDP8 segment ([MS-RDPEGFX] 2.2.5.1) in a complete DVC message.
    static func graphicsPacket(_ messages: Data, channelID: UInt32 = graphicsChannelID) -> Data {
        let dynamic = RDPDynamicVirtualChannelDataPDU(channelID: channelID, payload: Data([0xE0, 0x04]) + messages).encoded()
        return packet(
            channelID: drdynvcChannelID,
            userData: RDPStaticVirtualChannelPDU(payload: dynamic).encodedUserData()
        )
    }

    static func graphicsPDU(_ commandID: UInt16, _ body: Data) -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(commandID)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(UInt32(8 + body.count))
        data.append(body)
        return data
    }

    static func startFrame(id: UInt32) -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(0)
        body.appendLittleEndianUInt32(id)
        return graphicsPDU(RDPGFXCommandID.startFrame, body)
    }

    static func endFrame(id: UInt32) -> Data {
        var body = Data()
        body.appendLittleEndianUInt32(id)
        return graphicsPDU(RDPGFXCommandID.endFrame, body)
    }

    static func emptyGraphicsFrame(id: UInt32) -> Data {
        graphicsPacket(startFrame(id: id) + endFrame(id: id))
    }

    /// A fast-path hidden-pointer update: traffic that advances no milestone.
    static let pointerHidden = Data([0x00, 0x05, 0x05, 0x00, 0x00])

    /// Sends `packet` every `interval` until the connection closes.
    static func repeatedly(_ packet: Data, every interval: TimeAmount) -> @Sendable (Channel) -> Void {
        { channel in
            let task = channel.eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { _ in
                var buffer = channel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                channel.writeAndFlush(buffer, promise: nil)
            }
            channel.closeFuture.whenComplete { _ in
                task.cancel()
            }
        }
    }
}
