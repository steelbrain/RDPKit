import Foundation
@testable import RDPKit
import Testing

// Two negotiation transcripts captured off the wire (see RDPFirstFrameCapture
// --capture-transcript): gnome-remote-desktop and KRdp. Replaying one against
// a local server (which terminates TLS and performs NLA live, then feeds the
// recorded server PDUs back in order) drives the real client through the whole
// negotiation, including GRD's routing-token redirect and reconnect, up to the
// first video frame, without the live host.

@Test func replaysGnomeNegotiationTranscriptThroughToFirstFrame() throws {
    // The capture spanned two TCP connections: GRD redirects on the first and
    // serves graphics on the reconnect.
    #expect(try RDPTranscriptReplayServer.segment(loadTranscriptFixture("gnome-negotiation-transcript")).count == 2)

    let report = try replayTranscriptFixture("gnome-negotiation-transcript").report

    #expect(report.status == "success")
    #expect(report.error == nil)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.surfaceID == 0)
    #expect(report.rdpGraphicsFirstFrame?.width == 1280)
    #expect(report.rdpGraphicsFirstFrame?.height == 720)
    #expect(report.rdpGraphicsFirstFrame?.videoNalUnitTypes == [7, 8, 5])
    // ResetGraphics names one monitor, (0,0)-(1279,719) with inclusive bounds.
    #expect(report.rdpGraphicsFirstFrame?.monitors == [
        RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 1280, bottom: 720), isPrimary: true),
    ])
}

@Test func replaysKrdpNegotiationTranscriptThroughToFirstFrame() throws {
    #expect(try RDPTranscriptReplayServer.segment(loadTranscriptFixture("krdp-negotiation-transcript")).count == 1)

    let (report, clientPackets) = try replayTranscriptFixture("krdp-negotiation-transcript")

    #expect(report.status == "success")
    #expect(report.error == nil)
    #expect(report.rdpDynamicChannelCapabilitiesResponseHex != nil)
    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsChannelCreateResponseHex != nil)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.width == 3840)
    #expect(report.rdpGraphicsFirstFrame?.height == 2400)
    #expect(report.rdpGraphicsFirstFrame.map { Array($0.videoNalUnitTypes.prefix(3)) } == [7, 8, 6])
    // ResetGraphics (event 39) names one monitor, (0,0)-(3840,2400) with exclusive bounds.
    #expect(report.rdpGraphicsFirstFrame?.monitors == [
        RDPRemoteMonitor(rect: RDPFrameRect(left: 0, top: 0, right: 3840, bottom: 2400), isPrimary: true),
    ])

    // KRdp runs auto-detect after activation (events 31, 38, 43, 44): RTT
    // requests get RTT responses, and the continuous Bandwidth Measure Stop
    // gets results counting the session traffic since the Start
    // ([MS-RDPBCGR] 1.3.9, 2.2.14.2).
    let responses = clientPackets.compactMap(autoDetectResponse)
    #expect(responses.filter { $0.type == 0x0000 }.map(\.sequenceNumber) == [0x0023, 0x0001, 0x0002])
    let bandwidth = try #require(responses.first { $0.type == 0x000B })
    #expect(bandwidth.sequenceNumber == 0)
    #expect(bandwidth.byteCount > 0)
}

/// The client's auto-detect response in `packet` (security header
/// SEC_AUTODETECT_RSP, [MS-RDPBCGR] 2.2.14.4), if it holds one.
private func autoDetectResponse(
    _ packet: Data
) -> (sequenceNumber: UInt16, type: UInt16, byteCount: UInt32)? {
    guard let request = try? mcsSendDataRequest(fromTPKT: packet),
          request.userData.count >= 10,
          request.userData.littleEndianUInt32(at: 0) == 0x0000_2000,
          request.userData[request.userData.startIndex + 5] == 0x01
    else {
        return nil
    }
    let userData = request.userData
    let type = userData.littleEndianUInt16(at: 8)
    let byteCount = type == 0x000B && userData.count >= 18 ? userData.littleEndianUInt32(at: 14) : 0
    return (userData.littleEndianUInt16(at: 6), type, byteCount)
}

/// Every server PDU of both captures, in wire order, through the parsers the
/// client uses and with the state it keeps per connection. Any parse error
/// fails the test, and so does a PDU the client would skip. GRD's Demand
/// Active length (0x0196) has the SEC_LICENSE_PKT bit set, so licensing is
/// tried only while it is in progress.
@Test func parsesEveryServerPDUInBothCaptures() throws {
    let finalization = ["server-synchronize", "control-cooperate", "control-granted-control", "font-map"]
    let activation = ["license-error-valid-client", "server-demand-active"] + finalization
    // Both servers send the same capability sets; KRdp's Bitmap Codecs set is empty.
    let serverCapabilitySets = [
        "general", "bitmap", "order", "pointer", "input", "virtual-channel", "share", "font",
        "multifragment-update", "large-pointer", "capability-0x0019", "surface-commands", "bitmap-codecs",
        "frame-acknowledge",
    ]
    let gnomeConnectTimeAutoDetect = ["connect-time-bandwidth-measure-start->none", "bandwidth-measure-stop->0x0003"]
        + Array(repeating: "connect-time-rtt-measure-request->0x0000", count: 10)
        + ["network-characteristics-rtt-bandwidth->none"]
    let rtt = "rtt-measure-request->0x0000"
    let graphics = [
        "rdpgfx-caps-confirm": 1, "rdpgfx-reset-graphics": 1, "rdpgfx-create-surface": 1,
        "rdpgfx-map-surface-to-output": 1, "rdpgfx-start-frame": 1, "rdpgfx-wire-to-surface-1": 1,
        "rdpgfx-end-frame": 1,
    ]

    for (name, expected) in [
        // GRD redirects on the first connection and serves graphics on the
        // reconnect, encoding AVC420 into a staging surface it copies from.
        ("gnome-negotiation-transcript", CaptureSummary(
            ioChannel: activation + ["server-redirection"] + activation,
            demandActiveCapabilitySets: [serverCapabilitySets, serverCapabilitySets],
            autoDetect: gnomeConnectTimeAutoDetect + [rtt, rtt] + gnomeConnectTimeAutoDetect + [rtt, rtt, rtt, rtt],
            dynamicChannels: [
                RDPGFXChannel.name, "Microsoft::Windows::RDS::Telemetry", RDPAudioDynamicChannel.name,
                "Microsoft::Windows::RDS::Input", RDPDisplayControlChannel.name, "RDCamera_Device_Enumerator",
            ],
            graphics: graphics.merging(["rdpgfx-create-surface": 2, "rdpgfx-surface-to-surface": 1]) { $1 },
            audio: ["audio-formats", "audio-training"],
            displayControl: [RDPDisplayControlCapabilities(
                maxNumMonitors: 16,
                maxMonitorAreaFactorA: 8192,
                maxMonitorAreaFactorB: 8192
            )]
        )),
        ("krdp-negotiation-transcript", CaptureSummary(
            ioChannel: activation,
            demandActiveCapabilitySets: [serverCapabilitySets],
            autoDetect: [
                "connect-time-rtt-measure-request->0x0000", rtt, "bandwidth-measure-start->none", rtt,
                "post-connect-bandwidth-measure-stop->0x000B",
            ],
            dynamicChannels: [RDPGFXChannel.name],
            graphics: graphics,
            fastPath: ["pointer-new", "pointer-cached"],
            pointers: ["image 0 46x46", "cached-image 0 46x46"]
        )),
    ] {
        var summary = CaptureSummary()
        for segment in try RDPTranscriptReplayServer.segment(loadTranscriptFixture(name)) {
            var connection = try CaptureConnection(x224Response: segment.x224Response, summary: summary)
            for event in segment.appEvents where event.direction == .serverToClient {
                do {
                    try connection.receive(#require(event.bytes))
                } catch {
                    Issue.record("\(name) event \(event.sequence): \(error)")
                    throw error
                }
            }
            #expect(connection.isIdle, "\(name): a fragmented message never completed")
            summary = connection.summary
        }
        #expect(summary == expected, "\(name)")
    }
}

/// What a capture's server PDUs parsed to.
private struct CaptureSummary: Equatable, CustomStringConvertible {
    /// Licensing and Share Control/Data type names on the I/O channel.
    var ioChannel: [String] = []
    var demandActiveCapabilitySets: [[String]] = []
    /// Auto-detect requests on the message channel, each with the client's response.
    var autoDetect: [String] = []
    /// Dynamic channels the server created.
    var dynamicChannels: [String] = []
    /// RDPGFX messages by type.
    var graphics: [String: Int] = [:]
    /// Messages on AUDIO_PLAYBACK_DVC.
    var audio: [String] = []
    var displayControl: [RDPDisplayControlCapabilities] = []
    var fastPath: [String] = []
    var pointers: [String] = []

    var description: String {
        """
        ioChannel: \(ioChannel)
        demandActiveCapabilitySets: \(demandActiveCapabilitySets)
        autoDetect: \(autoDetect)
        dynamicChannels: \(dynamicChannels)
        graphics: \(graphics.sorted { $0.key < $1.key })
        audio: \(audio)
        displayControl: \(displayControl)
        fastPath: \(fastPath)
        pointers: \(pointers)
        """
    }
}

private struct CaptureParseError: Error, CustomStringConvertible {
    var description: String
}

/// One captured TCP connection as the client sees it after the X.224 exchange.
private struct CaptureConnection {
    private enum Stage {
        case connectResponse
        case attachUserConfirm(MCSConnectResponse)
        case channelJoinConfirms([UInt16])
        case session
    }

    private(set) var summary: CaptureSummary
    private var stage = Stage.connectResponse
    private var ioChannelID: UInt16 = 0
    private var messageChannelID: UInt16?
    private var drdynvcChannelID: UInt16?
    private var licensing = true
    private var autoDetectMeter = RDPAutoDetectBandwidthMeter()
    private var maximumChunkByteCount = RDPStaticVirtualChannelPDU.maximumPayloadByteCount
    private var staticChannelReassembler = RDPStaticVirtualChannelReassembler()
    private var staticChannelMessagePending = false
    private var dynamicChannelVersion: UInt16?
    private var dynamicChannels: [UInt32: String] = [:]
    private var dynamicChannelFragments: [UInt32: (totalLength: Int, payload: Data)] = [:]
    private var dynamicChannelDecompressors: [UInt32: RDPZGFXDecompressor] = [:]
    private let graphicsDecoder = RDPGFXServerTransportDecoder()
    private var graphicsCompositor: RDPGFXSurfaceCompositor?
    private var graphicsFrameTracker = RDPGFXLogicalFrameTracker()
    private let clearCodec = RDPClearCodecDecoder()
    private var fastPathReassembler = RDPFastPathOutputFragmentReassembler()
    private var fastPathUpdatePending = false
    private let primarySurface = RDPPrimarySurfaceCompositor(width: 1280, height: 720)
    private let pointerState = RDPRemotePointerState()

    init(x224Response: Data, summary: CaptureSummary) throws {
        self.summary = summary
        let confirm = try X224ConnectionConfirm.parse(fromTPKT: x224Response)
        guard case .selected = try #require(confirm.negotiationResult) else {
            throw CaptureParseError(description: "X.224 negotiation failed")
        }
    }

    /// No static channel, dynamic channel or fast-path message is half received.
    var isIdle: Bool {
        !staticChannelMessagePending && dynamicChannelFragments.isEmpty && !fastPathUpdatePending
    }

    mutating func receive(_ packet: Data) throws {
        switch stage {
        case .connectResponse:
            // Both capturing clients requested drdynvc only and advertised the message channel.
            let response = try MCSConnectResponse.parse(
                fromTPKT: packet,
                requestedChannels: [.drdynvc],
                expectedMessageChannelAdvertised: true
            )
            guard response.result == 0, let ioChannelID = response.ioChannelID else {
                throw CaptureParseError(description: "MCS Connect Response \(response.resultName)")
            }
            self.ioChannelID = ioChannelID
            messageChannelID = response.messageChannelID.flatMap { $0 == 0 ? nil : $0 }
            drdynvcChannelID = response.staticChannelAssignments.first {
                $0.name == RDPStaticVirtualChannel.drdynvc.name
            }?.channelID
            stage = .attachUserConfirm(response)
        case let .attachUserConfirm(response):
            let confirm = try MCSAttachUserConfirm.parse(fromTPKT: packet)
            let userChannelID = try #require(confirm.userChannelID)
            stage = .channelJoinConfirms(
                [userChannelID, ioChannelID] + response.staticChannelAssignments.map(\.channelID)
                    + (messageChannelID.map { [$0] } ?? [])
            )
        case var .channelJoinConfirms(channelIDs):
            let confirm = try MCSChannelJoinConfirm.parse(fromTPKT: packet)
            guard confirm.validates(requestedChannelID: channelIDs.removeFirst()) else {
                throw CaptureParseError(description: "MCS Channel Join Confirm \(confirm.resultName)")
            }
            stage = channelIDs.isEmpty ? .session : .channelJoinConfirms(channelIDs)
        case .session:
            try dispatch(packet)
        }
    }

    private mutating func dispatch(_ packet: Data) throws {
        guard packet.first == TPKT.version else {
            return try receiveFastPath(packet)
        }
        let indication = try MCSSendDataIndicationPDU.parse(fromTPKT: packet)
        switch indication.channelID {
        case messageChannelID:
            let request = try #require(try RDPServerAutoDetectRequest.parseIfPresent(fromTPKT: packet))
            let response = autoDetectMeter.response(to: request).map { String(format: "0x%04X", $0.responseType) } ?? "none"
            summary.autoDetect.append("\(request.requestTypeName)->\(response)")
        case ioChannelID:
            try receiveIOChannel(packet, indication: indication)
        case drdynvcChannelID:
            let chunk = try RDPStaticVirtualChannelPDU.parse(
                fromUserData: indication.userData,
                maximumChunkByteCount: maximumChunkByteCount
            )
            let message = try staticChannelReassembler.append(chunk, maximumChunkByteCount: maximumChunkByteCount)
            staticChannelMessagePending = message == nil
            if let message {
                try receiveDynamicChannelPDU(message.payload)
            }
        default:
            throw CaptureParseError(description: "data on unexpected channel \(indication.channelID)")
        }
    }

    private mutating func receiveIOChannel(_ packet: Data, indication: MCSSendDataIndicationPDU) throws {
        switch try #require(try RDPIOChannelPDU.parse(indication, licensing: licensing)) {
        case let .license(license):
            summary.ioChannel.append(license.typeName)
            licensing = license.typeName != "license-error-valid-client"
        case let .shareControl(shareControl):
            licensing = false
            var typeName = shareControl.typeName
            switch shareControl.type {
            case 0x1:
                let demandActive = try #require(try RDPDemandActivePDU.parseIfPresent(fromTPKT: packet))
                summary.demandActiveCapabilitySets.append(demandActive.capabilitySets.map(\.name))
                maximumChunkByteCount = demandActive.serverVirtualChannelChunkSize
                    ?? RDPStaticVirtualChannelPDU.maximumPayloadByteCount
                fastPathReassembler = RDPFastPathOutputFragmentReassembler(
                    maximumBufferedByteCount: RDPClientConfirmActivePDU(shareID: demandActive.shareID)
                        .multifragmentUpdateMaxRequestSize
                )
            case 0x7:
                let shareData = try #require(try RDPShareDataPDU.parseIfPresent(from: indication))
                typeName = shareData.typeName
                try receivePointer(shareData.pointerUpdate, error: shareData.pointerDecodeError)
            case 0xA:
                _ = try #require(try RDPServerRedirectionPDU.parseIfPresent(fromTPKT: packet, channelID: ioChannelID))
            default:
                break
            }
            summary.ioChannel.append(typeName)
        }
    }

    /// [MS-RDPEDYC] 3.1.5; the reassembly follows RDPClientConnection's.
    private mutating func receiveDynamicChannelPDU(_ payload: Data) throws {
        let channelID: UInt32
        let totalLength: UInt32?
        var data: Data
        switch try #require(RDPDynamicVirtualChannelHeader.command(of: payload)) {
        case .capabilities:
            let request = try #require(try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(from: payload))
            dynamicChannelVersion = RDPDynamicVirtualChannelCapabilitiesResponse(requestedVersion: request.version).version
            return
        case .create:
            let request = try #require(try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: payload))
            dynamicChannels[request.channelID] = request.channelName
            summary.dynamicChannels.append(request.channelName)
            return
        case .close:
            let close = try #require(try RDPDynamicVirtualChannelClosePDU.parseIfPresent(from: payload))
            dynamicChannels[close.channelID] = nil
            return
        case .softSyncRequest, .softSyncResponse:
            return
        case .dataFirst:
            let pdu = try #require(try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(from: payload))
            (channelID, totalLength, data) = (pdu.channelID, pdu.totalLength, pdu.payload)
        case .data:
            let pdu = try #require(try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: payload))
            (channelID, totalLength, data) = (pdu.channelID, nil, pdu.payload)
        case .dataFirstCompressed, .dataCompressed:
            let pdu = try #require(try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(from: payload))
            guard dynamicChannelVersion == 3 else {
                throw CaptureParseError(description: "compressed DVC data without version 3")
            }
            let decompressor = dynamicChannelDecompressors[pdu.channelID] ?? RDPZGFXDecompressor.rdp8Lite()
            dynamicChannelDecompressors[pdu.channelID] = decompressor
            (channelID, totalLength, data) = try (pdu.channelID, pdu.totalLength, decompressor.decompress(pdu.compressedPayload))
        }
        let channelName = try #require(dynamicChannels[channelID])
        if let totalLength {
            guard data.count < Int(totalLength) else {
                return try receiveDynamicChannelMessage(data, channelName: channelName)
            }
            dynamicChannelFragments[channelID] = (Int(totalLength), data)
            return
        }
        if var fragment = dynamicChannelFragments[channelID] {
            fragment.payload.append(data)
            guard fragment.payload.count >= fragment.totalLength else {
                dynamicChannelFragments[channelID] = fragment
                return
            }
            dynamicChannelFragments[channelID] = nil
            data = fragment.payload
        }
        try receiveDynamicChannelMessage(data, channelName: channelName)
    }

    private mutating func receiveDynamicChannelMessage(_ message: Data, channelName: String) throws {
        switch channelName {
        case RDPGFXChannel.name:
            try receiveGraphicsMessages(message)
        case RDPAudioDynamicChannel.name:
            summary.audio.append(try RDPAudioPDU.parse(from: message).typeName)
        case RDPDisplayControlChannel.name:
            summary.displayControl.append(try #require(try RDPDisplayControlCapsPDU.parseIfPresent(from: message)).capabilities)
        default:
            throw CaptureParseError(description: "data on dynamic channel \(channelName)")
        }
    }

    /// [MS-RDPEGFX] 3.2.5, as RDPClientConnection handles it.
    private mutating func receiveGraphicsMessages(_ message: Data) throws {
        for graphicsMessage in try graphicsDecoder.decodeGraphicsMessages(from: message) {
            summary.graphics[graphicsMessage.typeName, default: 0] += 1
            if graphicsMessage.commandID == RDPGFXCommandID.capsConfirm {
                let confirm = try #require(try RDPGFXCapsConfirmPDU.parse(from: graphicsMessage))
                graphicsCompositor = RDPGFXSurfaceCompositor(
                    capabilitySet: confirm.capabilitySet,
                    outputWidth: 1280,
                    outputHeight: 720
                )
                continue
            }
            let compositor = try #require(graphicsCompositor, "RDPGFX message before CapsConfirm")
            try graphicsFrameTracker.track(graphicsMessage)
            _ = try RDPGFXMessageSummary.summarize(graphicsMessage)
            try compositor.process(graphicsMessage, clearCodec: clearCodec)
            if graphicsMessage.commandID == RDPGFXCommandID.wireToSurface1 {
                let wire = try RDPGFXWireToSurface1PDU.parse(from: graphicsMessage)
                switch wire.codecID {
                case RDPGFXCodecID.avc420:
                    _ = try RDPGFXAVC420BitmapStream.parse(from: wire.bitmapData)
                case RDPGFXCodecID.avc444, RDPGFXCodecID.avc444v2:
                    _ = try RDPGFXAVC444BitmapStream.parse(from: wire.bitmapData)
                default:
                    break
                }
            }
        }
    }

    private mutating func receiveFastPath(_ packet: Data) throws {
        let pdu = try RDPFastPathOutputPDU.parse(packet)
        summary.fastPath += pdu.summaries.map { $0.pointerTypeName ?? $0.typeName }
        for fragment in pdu.updates {
            let update = try fastPathReassembler.append(fragment)
            fastPathUpdatePending = update == nil
            guard let update else {
                continue
            }
            try receivePointer(update.pointerUpdate, error: update.pointerDecodeError)
            if let commands = update.surfaceCommands {
                _ = try primarySurface.process(commands)
            } else if let bitmap = update.bitmapUpdate {
                _ = try primarySurface.process(bitmap)
            }
        }
    }

    private mutating func receivePointer(_ update: RDPServerPointerUpdate?, error: RDPDecodeError?) throws {
        if let error {
            throw error
        }
        switch try update.map(pointerState.apply) {
        case let .image(image):
            summary.pointers.append("image \(image.cacheIndex) \(image.width)x\(image.height)")
        case let .cachedImage(image):
            summary.pointers.append("cached-image \(image.cacheIndex) \(image.width)x\(image.height)")
        case let update?:
            summary.pointers.append("\(update)")
        case nil:
            break
        }
    }
}
