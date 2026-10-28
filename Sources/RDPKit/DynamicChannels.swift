import Foundation

/// The DRDYNVC client ([MS-RDPEDYC] 3.2): capabilities at any time, channel
/// create/close with responses, per-channel reassembly and decompression.
/// Malformed DRDYNVC PDUs end the session; unknown commands are ignored.
extension RDPClientConnection {
    /// Largest message reassembled from DataFirst/Data fragments per channel kind.
    private static func maximumMessageByteCount(for kind: RDPDynamicChannelKind) -> Int {
        kind == .graphics ? RDPStaticVirtualChannelReassembler.defaultMaximumTotalLength : 1 << 20
    }

    /// Reported for unknown channel names: E_NOTIMPL ([MS-RDPEDYC] 2.2.2.2).
    private static let unsupportedChannelStatus = Int32(bitPattern: 0x8000_4001)

    func handleDynamicChannelPDU(_ payload: Data, packet: Data) throws {
        report.rdpDynamicChannelRequestHexes.appendIfRoom(packet.rdpHexString, limit: RDPRecordLimit.packets)
        guard let command = RDPDynamicVirtualChannelHeader.command(of: payload) else {
            recordDynamicChannelEvent("dynvc-unknown")
            return
        }
        switch command {
        case .capabilities:
            guard let request = try RDPDynamicVirtualChannelCapabilitiesRequest.parseIfPresent(from: payload) else {
                return
            }
            recordDynamicChannelEvent(request.typeName)
            report.rdpDynamicChannelCapabilitiesVersion = request.version
            let response = RDPDynamicVirtualChannelCapabilitiesResponse(requestedVersion: request.version)
            dynamicChannelVersion = response.version
            report.rdpDynamicChannelCapabilitiesResponseHex = try sendDynamicChannelControl(response.encoded())
                .rdpHexString
        case .create:
            guard let request = try RDPDynamicVirtualChannelCreateRequest.parseIfPresent(from: payload) else {
                return
            }
            recordDynamicChannelEvent("\(request.typeName):\(request.channelName)")
            try openDynamicChannel(request)
        case .close:
            guard let close = try RDPDynamicVirtualChannelClosePDU.parseIfPresent(from: payload) else {
                return
            }
            recordDynamicChannelEvent(close.typeName)
            try closeDynamicChannel(close)
        case .dataFirst, .data, .dataFirstCompressed, .dataCompressed:
            try receiveDynamicChannelData(payload, command: command, packet: packet)
        case .softSyncRequest, .softSyncResponse:
            // Soft-Sync applies only to multitransport, which this client does not offer.
            recordDynamicChannelEvent(command.typeName)
        }
    }

    private func recordDynamicChannelEvent(_ event: String) {
        report.rdpDynamicChannelRequestTypes.appendIfRoom(event, limit: RDPRecordLimit.messages)
    }

    /// Sends a DRDYNVC PDU on the drdynvc static channel.
    @discardableResult
    func sendDynamicChannelControl(_ payload: Data) throws -> Data {
        guard let channelID = staticChannelNames.first(where: { $0.value == RDPStaticVirtualChannel.drdynvc.name })?.key
        else {
            throw RDPPreflightError.protocolViolation("drdynvc channel is not joined")
        }
        return try sendStaticChannelPayload(payload, channelID: channelID)
    }

    /// Sends `payload` on a dynamic channel, split into Data PDUs as needed.
    @discardableResult
    func sendDynamicChannelData(_ payload: Data, channelID: UInt32) throws -> Data {
        var sent = Data()
        for pdu in RDPDynamicVirtualChannelDataPacketizer(channelID: channelID, payload: payload).encodedPDUs() {
            sent = try sendDynamicChannelControl(pdu)
        }
        return sent
    }

    private func openDynamicChannel(_ request: RDPDynamicVirtualChannelCreateRequest) throws {
        let kind: RDPDynamicChannelKind? = switch request.channelName {
        case RDPGFXChannel.name: .graphics
        case RDPDisplayControlChannel.name: .displayControl
        case RDPAudioDynamicChannel.name where configuration.audioPlaybackEnabled: .audio
        default: nil
        }
        let response = try sendDynamicChannelControl(RDPDynamicVirtualChannelCreateResponse(
            channelID: request.channelID,
            creationStatus: kind == nil ? Self.unsupportedChannelStatus : 0
        ).encoded())
        guard let kind else {
            return
        }
        discardDynamicChannelState(request.channelID)
        dynamicChannels[request.channelID] = kind
        switch kind {
        case .graphics:
            report.rdpGraphicsChannelName = request.channelName
            report.rdpGraphicsChannelID = request.channelID
            report.rdpGraphicsChannelCreateResponseHex = response.rdpHexString
            try openGraphicsPipeline(channelID: request.channelID)
        case .displayControl:
            report.rdpDisplayControlChannelID = request.channelID
            report.rdpDisplayControlChannelCreateResponseHex = response.rdpHexString
        case .audio:
            guard let channel = transport?.channel, let staticChannelID = drdynvcChannelID else {
                return
            }
            dynamicAudio = RDPAudioSession(
                userChannelID: userChannelID,
                dynamicStaticChannelID: staticChannelID,
                dynamicChannelID: request.channelID,
                channel: channel
            )
        }
    }

    private var drdynvcChannelID: UInt16? {
        staticChannelNames.first { $0.value == RDPStaticVirtualChannel.drdynvc.name }?.key
    }

    /// Answers a server Close with a Close for a channel this client opened ([MS-RDPEDYC] 3.2.5.2).
    private func closeDynamicChannel(_ close: RDPDynamicVirtualChannelClosePDU) throws {
        discardDynamicChannelState(close.channelID)
        guard let kind = dynamicChannels.removeValue(forKey: close.channelID) else {
            return
        }
        switch kind {
        case .graphics:
            graphicsChannelID = nil
        case .audio:
            dynamicAudio = nil
        case .displayControl:
            break
        }
        try sendDynamicChannelControl(close.encoded())
    }

    func discardDynamicChannelState(_ channelID: UInt32) {
        dynamicChannelFragments[channelID] = nil
        dynamicChannelDecompressors[channelID] = nil
    }

    private func receiveDynamicChannelData(
        _ payload: Data,
        command: RDPDynamicVirtualChannelCommand,
        packet: Data
    ) throws {
        let channelID: UInt32
        let totalLength: UInt32?
        let data: Data
        switch command {
        case .dataFirst:
            guard let pdu = try RDPDynamicVirtualChannelDataFirstPDU.parseIfPresent(from: payload) else {
                return
            }
            (channelID, totalLength, data) = (pdu.channelID, pdu.totalLength, pdu.payload)
        case .data:
            guard let pdu = try RDPDynamicVirtualChannelDataPDU.parseIfPresent(from: payload) else {
                return
            }
            (channelID, totalLength, data) = (pdu.channelID, nil, pdu.payload)
        default:
            guard let pdu = try RDPDynamicVirtualChannelCompressedDataPDU.parseIfPresent(from: payload) else {
                return
            }
            // Compressed data needs DYNVC_CAPS_VERSION3 ([MS-RDPEDYC] 3.1.5.1.4).
            guard dynamicChannelVersion == 3 else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            guard dynamicChannels[pdu.channelID] != nil else {
                return
            }
            channelID = pdu.channelID
            totalLength = pdu.totalLength
            data = try decompressDynamicChannelData(pdu)
        }
        guard let kind = dynamicChannels[channelID] else {
            return
        }
        switch kind {
        case .graphics: recordDynamicChannelEvent(command.typeName)
        case .displayControl: recordDynamicChannelEvent("\(command.typeName):display-control")
        case .audio: recordDynamicChannelEvent("\(command.typeName):audio")
        }
        guard let message = try reassembleDynamicChannelMessage(
            channelID: channelID,
            totalLength: totalLength,
            data: data,
            limit: Self.maximumMessageByteCount(for: kind)
        ) else {
            return
        }
        switch kind {
        case .graphics:
            try handleGraphicsMessage(message, packet: packet)
        case .displayControl:
            handleDisplayControl(message, channelID: channelID, packet: packet)
        case .audio:
            if let dynamicAudio {
                handleAudio(message, session: dynamicAudio)
            }
        }
    }

    /// Each channel has its own RDP8-lite history ([MS-RDPEDYC] 3.1.5.1.4).
    private func decompressDynamicChannelData(_ pdu: RDPDynamicVirtualChannelCompressedDataPDU) throws -> Data {
        let decompressor = dynamicChannelDecompressors[pdu.channelID] ?? RDPZGFXDecompressor.rdp8Lite()
        dynamicChannelDecompressors[pdu.channelID] = decompressor
        do {
            return try decompressor.decompress(pdu.compressedPayload)
        } catch {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
    }

    /// DataFirst starts a message of `totalLength` bytes; Data continues it, or
    /// is a whole message when none is pending ([MS-RDPEDYC] 3.1.5.1.2).
    private func reassembleDynamicChannelMessage(
        channelID: UInt32,
        totalLength: UInt32?,
        data: Data,
        limit: Int
    ) throws -> Data? {
        if let totalLength {
            guard Int(totalLength) <= limit, data.count <= Int(totalLength) else {
                throw RDPDecodeError.invalidDynamicVirtualChannelPDU
            }
            guard data.count < Int(totalLength) else {
                dynamicChannelFragments[channelID] = nil
                return data
            }
            dynamicChannelFragments[channelID] = RDPDynamicChannelFragment(totalLength: Int(totalLength), payload: data)
            return nil
        }
        // Taken out of the dictionary so the append does not copy the partial message.
        guard var fragment = dynamicChannelFragments.removeValue(forKey: channelID) else {
            return data
        }
        fragment.payload.append(data)
        guard fragment.payload.count <= fragment.totalLength else {
            throw RDPDecodeError.invalidDynamicVirtualChannelPDU
        }
        guard fragment.payload.count == fragment.totalLength else {
            dynamicChannelFragments[channelID] = fragment
            return nil
        }
        return fragment.payload
    }

    private func handleDisplayControl(_ message: Data, channelID: UInt32, packet: Data) {
        do {
            guard let caps = try RDPDisplayControlCapsPDU.parseIfPresent(from: message) else {
                return
            }
            report.rdpDisplayControlCapsHex = packet.rdpHexString
            report.rdpDisplayControlCaps = caps.capabilities
            guard let channel = transport?.channel, let staticChannelID = drdynvcChannelID else {
                return
            }
            callbacks.onDisplayControlReady?(RDPDisplayControlSession(
                dynamicChannelID: channelID,
                capabilities: caps.capabilities,
                userChannelID: userChannelID,
                staticChannelID: staticChannelID,
                channel: channel
            ))
        } catch {
            recordChannelError(RDPDisplayControlChannel.name, error)
        }
    }
}
