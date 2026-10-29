import Foundation

extension RDPClientConnection {
    /// MCS Connect Initial/Response, Erect Domain, Attach User and a Channel
    /// Join for every channel ([MS-RDPBCGR] 3.2.5.3.3-8). The client never
    /// advertises skip-channel-join, so it always joins.
    func connectChannels() throws {
        stage = .channelConnection
        resetSessionRecord()
        let mcsConfiguration = MCSConnectInitialConfiguration(
            desktopWidth: configuration.desktopWidth,
            desktopHeight: configuration.desktopHeight,
            scaleFactors: configuration.scaleFactors,
            physicalSize: configuration.physicalSize,
            clientName: clientName,
            selectedProtocol: selectedProtocols,
            requestedProtocols: configuration.negotiationRequest.requestedProtocols,
            channels: configuration.staticVirtualChannels,
            advertiseMessageChannel: (report.negotiationFlags ?? 0)
                & RDPNegotiationResponseFlags.extendedClientDataSupported != 0,
            redirectedSessionID: configuration.redirectionSessionID,
            keyboard: configuration.clientKeyboard
        )
        let connectInitial = MCSConnectInitialPDU(configuration: mcsConfiguration).encodedTPKT()
        report.mcsConnectInitialHex = connectInitial.rdpHexString
        try send(connectInitial)
        let connectResponseData = try receive("MCS Connect Response")
        report.mcsConnectResponseHex = connectResponseData.rdpHexString
        let connectResponse = try MCSConnectResponse.parse(
            fromTPKT: connectResponseData,
            requestedChannels: mcsConfiguration.channels,
            expectedRequestedProtocols: mcsConfiguration.requestedProtocols,
            expectedMessageChannelAdvertised: mcsConfiguration.advertiseMessageChannel
        )
        report.mcsConnectResult = connectResponse.resultName
        report.mcsServerUserDataKey = connectResponse.serverUserDataKey
        report.mcsIOChannelID = connectResponse.ioChannelID
        report.mcsMessageChannelID = connectResponse.messageChannelID
        report.mcsStaticChannels = connectResponse.staticChannelAssignments
        guard connectResponse.result == 0 else {
            throw RDPConnectionError.protocolViolation("MCS Connect Response result: \(connectResponse.resultName)")
        }
        guard let ioChannelID = connectResponse.ioChannelID else {
            throw RDPConnectionError.protocolViolation("MCS Connect Response did not include an I/O channel")
        }
        self.ioChannelID = ioChannelID
        messageChannelID = connectResponse.messageChannelID.flatMap { $0 == 0 ? nil : $0 }
        serverCertificatePublicKey = connectResponse.serverCertificatePublicKey

        let erectDomain = MCSErectDomainRequestPDU().encodedTPKT()
        report.mcsErectDomainRequestHex = erectDomain.rdpHexString
        try send(erectDomain)
        let attachUser = MCSAttachUserRequestPDU().encodedTPKT()
        report.mcsAttachUserRequestHex = attachUser.rdpHexString
        try send(attachUser)
        let attachUserConfirmData = try receive("MCS Attach User Confirm")
        report.mcsAttachUserConfirmHex = attachUserConfirmData.rdpHexString
        let attachUserConfirm = try MCSAttachUserConfirm.parse(fromTPKT: attachUserConfirmData)
        report.mcsAttachUserResult = attachUserConfirm.resultName
        guard attachUserConfirm.result == 0 else {
            throw RDPConnectionError.protocolViolation("MCS Attach User Confirm result: \(attachUserConfirm.resultName)")
        }
        guard let userChannelID = attachUserConfirm.userChannelID else {
            throw RDPConnectionError.protocolViolation("MCS Attach User Confirm did not include a user channel ID")
        }
        self.userChannelID = userChannelID
        transport?.noteJoinedDomain()
        report.mcsUserChannelID = userChannelID

        var joins = [("user", userChannelID), ("io", ioChannelID)]
        joins += connectResponse.staticChannelAssignments.map { ($0.name, $0.channelID) }
        if let messageChannelID {
            joins.append(("message", messageChannelID))
        }
        report.mcsJoinedChannels = []
        for (name, channelID) in joins {
            let request = MCSChannelJoinRequestPDU(initiator: userChannelID, channelID: channelID).encodedTPKT()
            try send(request)
            let confirmData = try receive("MCS Channel Join Confirm for \(name)")
            let confirm = try MCSChannelJoinConfirm.parse(fromTPKT: confirmData)
            let joined = confirm.validates(requestedChannelID: channelID)
            let result = joined
                ? confirm.resultName
                : "\(confirm.resultName)-channel-\(confirm.channelID)-for-\(channelID)"
            report.mcsJoinedChannels?.append(RDPChannelJoinReport(
                name: name,
                channelID: channelID,
                requestHex: request.rdpHexString,
                confirmHex: confirmData.rdpHexString,
                result: result
            ))
            guard joined else {
                throw RDPConnectionError.protocolViolation("MCS Channel Join Confirm result for \(name): \(result)")
            }
        }
        for assignment in connectResponse.staticChannelAssignments {
            staticChannelNames[assignment.channelID] = assignment.name
            if assignment.name == RDPStaticVirtualChannel.drdynvc.name {
                drdynvcChannelID = assignment.channelID
            }
        }
        openStaticChannelSessions()
    }

    /// The Client Info PDU carries the credentials ([MS-RDPBCGR] 3.2.5.3.11).
    func sendClientInfo() throws {
        stage = .clientInfo
        try callbacks.throwIfCancelled()
        let clientInfo = RDPClientInfoPDU(
            credentials: configuration.credentials,
            passwordCookie: configuration.redirectionPasswordCookie,
            audioPlaybackEnabled: configuration.audioPlaybackEnabled
        )
        report.rdpClientInfoCredentialsIncluded = clientInfo.credentialsIncluded
        let packet = try clientInfo.encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
        try send(packet)
        report.rdpClientInfoSent = true
        report.rdpClientInfoRequestBytes = packet.count
        startPhase()
    }

    /// Lists start empty once the channels exist, so "none seen" reads as [] rather than nil.
    private func resetSessionRecord() {
        report.rdpClientInfoSent = false
        report.rdpFinalizationResponseHexes = []
        report.rdpFinalizationResponseTypes = []
        report.rdpDynamicChannelRequestHexes = []
        report.rdpDynamicChannelRequestTypes = []
        report.rdpGraphicsUpdateResponseCount = 0
        report.rdpGraphicsUpdateResponseHexes = []
        report.rdpGraphicsUpdateMessages = []
        report.rdpFastPathUpdateMessages = []
        report.rdpGraphicsFailureUpdateMessages = []
        report.rdpGraphicsFrameAcknowledgeHexes = []
        report.rdpGraphicsFrames = []
        report.rdpClipboardMessages = []
        report.rdpClipboardSentMessages = []
        report.rdpAudioMessages = []
    }

    private func openStaticChannelSessions() {
        guard let channel = transport?.channel else {
            return
        }
        for (channelID, name) in staticChannelNames {
            switch name {
            case RDPStaticVirtualChannel.cliprdr.name:
                report.rdpClipboardChannelID = channelID
                let log = clipboardSentLog
                clipboard = RDPClipboardSession(
                    userChannelID: userChannelID,
                    staticChannelID: channelID,
                    channel: channel,
                    chunkSize: staticChannelChunkSize,
                    requestsRichFormats: callbacks.onClipboardContent != nil,
                    sentMessageHandler: { summary, _ in log.append(summary) }
                )
            case RDPStaticVirtualChannel.rdpsnd.name:
                report.rdpAudioChannelID = channelID
                audio = RDPAudioSession(userChannelID: userChannelID, staticChannelID: channelID, channel: channel)
            case RDPStaticVirtualChannel.rdpdr.name:
                deviceRedirection = RDPDeviceRedirectionSession(
                    userChannelID: userChannelID,
                    staticChannelID: channelID,
                    channel: channel,
                    computerName: clientName,
                    drives: configuration.sharedDrives,
                    chunkSize: staticChannelChunkSize
                )
            default:
                break
            }
        }
    }
}
