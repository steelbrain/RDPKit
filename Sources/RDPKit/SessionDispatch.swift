import Foundation
import NIOCore

/// The receive path after the Client Info PDU: every server message, from
/// licensing to the end of the session, goes through `dispatch(_:)`, which
/// routes it by MCS channel ([MS-RDPBCGR] 1.3.1.1, 1.3.1.3).
extension RDPClientConnection {
    func receiveAndDispatch() throws {
        guard let transport else {
            throw RDPPreflightError.receive("not connected")
        }
        var timeout = receiveTimeout
        if let phaseDeadline {
            let remaining = phaseDeadline - .now()
            guard remaining > .zero else {
                try handleReceiveTimeout()
                return
            }
            timeout = min(timeout ?? remaining, remaining)
        }
        let message: Data
        do {
            message = try transport.receive(timeout: timeout)
        } catch RDPTransportError.timedOut {
            try handleReceiveTimeout()
            return
        } catch let error as RDPPreflightError {
            throw error
        } catch {
            try handleConnectionEnd(error)
            return
        }
        if report.rdpClientInfoResponseHex == nil {
            report.rdpClientInfoResponseHex = message.rdpHexString
        }
        try dispatch(message)
    }

    /// Bounds the wait for the next connection milestone by the configured
    /// timeout, however much other traffic arrives. A live session that shows
    /// frames awaits nothing: TCP keepalive notices a dead peer. `captureOnly`
    /// marks a milestone only a capture run waits for, its next frame.
    func startPhase(captureOnly: Bool = false) {
        let isLive = targetFrameCount == nil
        phaseDeadline = isLive && (captureOnly || report.rdpGraphicsFirstFrame != nil)
            ? nil
            : .now() + .seconds(Int64(configuration.timeoutSeconds))
    }

    /// Live sessions wait indefinitely once frames flow; TCP keepalive notices a dead peer.
    private var receiveTimeout: TimeAmount? {
        if isTerminating {
            return .seconds(1)
        }
        let waitsIndefinitely = targetFrameCount == nil && report.rdpGraphicsFirstFrame != nil && !isDeactivated
        return waitsIndefinitely ? nil : .seconds(Int64(configuration.timeoutSeconds))
    }

    private func dispatch(_ message: Data) throws {
        guard message.first == TPKT.version else {
            autoDetectMeter.countReceivedBytes(message.count)
            try handleFastPath(message)
            return
        }
        if let ultimatum = try MCSDisconnectProviderUltimatumPDU.parseIfPresent(fromTPKT: message) {
            var termination = termination ?? RDPRemoteTermination()
            termination.disconnectReason = ultimatum.reason
            self.termination = termination
            try endSession(by: termination)
            return
        }
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: message) else {
            return
        }
        if indication.channelID == messageChannelID {
            try handleMessageChannel(indication)
            return
        }
        autoDetectMeter.countReceivedBytes(message.count)
        if indication.channelID == ioChannelID {
            try handleIOChannel(message, indication: indication)
        } else if let name = staticChannelNames[indication.channelID] {
            try handleStaticChannel(indication, name: name, packet: message)
        }
    }

    // MARK: I/O channel

    private func handleIOChannel(_ message: Data, indication: MCSSendDataIndicationPDU) throws {
        let shareControl: RDPShareControlPDU
        switch try RDPIOChannelPDU.parse(indication, licensing: !licensingComplete) {
        case let .license(license):
            recordPostAutoDetectResponse(message, type: nil)
            try handleLicense(license)
            return
        case let .shareControl(pdu):
            shareControl = pdu
        case nil:
            return
        }
        recordPostAutoDetectResponse(message, type: shareControl.typeName)
        if report.rdpLicensingResponseType != nil, report.rdpPostLicensingResponseHex == nil {
            report.rdpPostLicensingResponseHex = message.rdpHexString
            report.rdpPostLicensingResponseType = shareControl.typeName
        }
        let shareData = shareControl.type == 0x7 ? try RDPShareDataPDU.parseIfPresent(from: indication) : nil
        if awaitingPostConfirmActiveResponse {
            awaitingPostConfirmActiveResponse = false
            report.rdpPostConfirmActiveResponseHex = message.rdpHexString
            report.rdpPostConfirmActiveResponseType = shareData?.typeName ?? shareControl.typeName
        }

        switch shareControl.type {
        case 0x1:
            guard let demandActive = try RDPDemandActivePDU.parseIfPresent(from: indication) else {
                return
            }
            try activate(demandActive)
        case 0x6:
            try handleDeactivateAll()
        case 0x7:
            if let shareData {
                try handleShareData(shareData, packet: message)
            }
        case 0xA:
            guard let redirection = try RDPServerRedirectionPDU.parseIfPresent(from: indication) else {
                return
            }
            // LB_NOREDIRECT: informational only, no redirection is required ([MS-RDPBCGR] 2.2.13.1).
            guard !redirection.flags.contains(.noRedirect) else {
                appendWarning(
                    code: "informational-redirection",
                    message: "server sent an informational redirection" + (redirection.targetHost.map { " for \($0)" } ?? "")
                )
                return
            }
            self.redirection = redirection
            throw RDPPreflightError.protocolViolation(redirection.targetHost.map {
                "server requested RDP redirection to \($0)"
            } ?? "server requested RDP redirection")
        default:
            break
        }
    }

    private func recordPostAutoDetectResponse(_ message: Data, type: String?) {
        guard sawConnectTimeAutoDetect, report.rdpPostAutoDetectResponseHex == nil else {
            return
        }
        report.rdpPostAutoDetectResponseHex = message.rdpHexString
        report.rdpPostAutoDetectResponseType = type
    }

    private func handleShareData(_ shareData: RDPShareDataPDU, packet: Data) throws {
        if var share, !share.finalization.isComplete {
            report.rdpFinalizationResponseHexes.appendIfRoom(packet.rdpHexString, limit: RDPRecordLimit.messages)
            report.rdpFinalizationResponseTypes.appendIfRoom(shareData.typeName, limit: RDPRecordLimit.messages)
            share.finalization.observe(shareData)
            self.share = share
            if share.finalization.isComplete {
                finishActivation(share)
            }
        }
        // ERRINFO_NONE only clears the status ([MS-RDPBCGR] 2.2.5.1.1).
        if let errorInfo = shareData.errorInfo, errorInfo != 0 {
            var termination = termination ?? RDPRemoteTermination()
            termination.errorInfo = errorInfo
            self.termination = termination
        }
        if let update = shareData.graphicsUpdate {
            try handleSlowPathGraphics(update, packet: packet)
        }
        if let pointer = shareData.pointerUpdate {
            applyPointer(pointer)
        } else if let error = shareData.pointerDecodeError {
            appendWarning(code: "pointer-error", message: String(describing: error))
        }
    }

    // MARK: Licensing ([MS-RDPELE] 3.1.5)

    private func handleLicense(_ license: RDPServerLicensePDU) throws {
        stage = .licensing
        if report.rdpLicensingResponseType == nil {
            report.rdpLicensingResponseType = license.typeName
            if case let .errorAlert(alert) = license.message {
                report.rdpLicensingErrorCode = alert.errorCode
            }
        }
        switch license.message {
        case let .errorAlert(alert):
            guard alert.isValidClient else {
                throw RDPPreflightError.protocolViolation("server licensing failed: \(alert.description)")
            }
            licensingComplete = true
            startPhase()
        case let .licenseRequest(request):
            try answerLicenseRequest(request)
        case let .platformChallenge(challenge):
            guard let licenseKeys else {
                throw RDPDecodeError.invalidLicensePDU
            }
            let response = try RDPClientPlatformChallengeResponsePDU(
                channelID: ioChannelID,
                platformChallenge: licenseKeys.openVerified(challenge.encryptedChallenge, mac: challenge.mac),
                keys: licenseKeys
            )
            try send(response.encodedTPKT(userChannelID: userChannelID))
        case let .newLicense(issued), let .upgradeLicense(issued):
            guard let licenseKeys else {
                throw RDPDecodeError.invalidLicensePDU
            }
            let licenseInfo = try licenseKeys.openVerified(issued.encryptedLicenseInfo, mac: issued.mac)
            report.rdpIssuedClientLicense = try RDPServerNewLicenseInformation.parse(licenseInfo).storedClientLicense
            licensingComplete = true
            startPhase()
        }
    }

    /// Presents the stored license when it matches the server's product,
    /// otherwise asks for a new one.
    private func answerLicenseRequest(_ request: RDPServerLicenseRequest) throws {
        guard let serverPublicKey = request.serverCertificatePublicKey ?? serverCertificatePublicKey else {
            throw RDPPreflightError.protocolViolation("server did not provide a usable licensing public key")
        }
        let packet: Data
        let clientRandom: Data
        let premasterSecret: Data?
        if let storedLicense = configuration.storedClientLicense, storedLicense.matches(request) {
            let information = try RDPClientLicenseInformationPDU(
                channelID: ioChannelID,
                serverPublicKey: serverPublicKey,
                serverRandom: request.serverRandom,
                storedLicense: storedLicense
            )
            packet = try information.encodedTPKT(userChannelID: userChannelID)
            clientRandom = information.clientRandom
            premasterSecret = information.premasterSecret
        } else {
            let newLicenseRequest = try RDPClientNewLicenseRequestPDU(
                channelID: ioChannelID,
                serverPublicKey: serverPublicKey,
                username: configuration.credentials?.username ?? clientName,
                machineName: clientName
            )
            packet = try newLicenseRequest.encodedTPKT(userChannelID: userChannelID)
            clientRandom = newLicenseRequest.clientRandom
            premasterSecret = newLicenseRequest.premasterSecret
        }
        licenseKeys = try premasterSecret.map {
            try RDPLicenseKeys.derive(clientRandom: clientRandom, serverRandom: request.serverRandom, premasterSecret: $0)
        }
        try send(packet)
    }

    // MARK: Message channel ([MS-RDPBCGR] 2.2.14)

    /// A malformed request is recorded and skipped: auto-detection is advisory.
    private func handleMessageChannel(_ indication: MCSSendDataIndicationPDU) throws {
        let request: RDPServerAutoDetectRequest
        do {
            guard let parsed = try RDPServerAutoDetectRequest.parseIfPresent(from: indication) else {
                return
            }
            request = parsed
        } catch {
            appendWarning(code: "auto-detect-error", message: String(describing: error))
            return
        }
        let isConnectTime = share == nil
        if isConnectTime {
            sawConnectTimeAutoDetect = true
            if stage == .clientInfo {
                stage = .autoDetect
            }
            if report.rdpAutoDetectRequestType == nil {
                report.rdpAutoDetectRequestType = request.requestTypeName
                report.rdpAutoDetectSequenceNumber = request.sequenceNumber
            }
        }
        guard let response = autoDetectMeter.response(to: request) else {
            return
        }
        let packet = response.encodedTPKT(userChannelID: userChannelID, messageChannelID: indication.channelID)
        if isConnectTime {
            report.rdpAutoDetectResponseHex = packet.rdpHexString
        }
        try send(packet)
    }

    // MARK: Activation ([MS-RDPBCGR] 3.2.5.3.13-22)

    /// Answers a Demand Active, at connection time or after Deactivate All
    /// (deactivation-reactivation, [MS-RDPBCGR] 1.3.1.3).
    private func activate(_ demandActive: RDPDemandActivePDU) throws {
        licensingComplete = true
        isDeactivated = false
        startPhase()
        // A reactivation means the server is not disconnecting after all.
        isTerminating = false
        termination = nil
        stage = .confirmActive
        report.rdpDemandActiveShareID = demandActive.shareID
        report.rdpDemandActiveCapabilitySets = demandActive.capabilitySets
        // The client confirms the desktop size the server set ([MS-RDPBCGR] 2.2.7.1.2).
        if let width = demandActive.desktopWidth, let height = demandActive.desktopHeight,
           (1 ... 8192).contains(width), (1 ... 8192).contains(height)
        {
            resizeDesktop(width: width, height: height)
        }

        let confirmActive = RDPClientConfirmActivePDU(
            shareID: demandActive.shareID,
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight
        )
        let confirmActivePacket = confirmActive.encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
        report.rdpConfirmActiveRequestHex = confirmActivePacket.rdpHexString
        report.rdpConfirmActiveCapabilitySets = confirmActive.capabilitySets

        // Synchronize targets the Demand Active pduSource, or the fixed server
        // channel when that is zero ([MS-RDPBCGR] 3.2.5.3.13.1, 3.2.5.3.14).
        let targetUser = demandActive.pduSource != 0 ? demandActive.pduSource : RDPServerChannelID.fixed
        let shareID = demandActive.shareID
        let synchronize = RDPClientSynchronizePDU(shareID: shareID, targetUser: targetUser)
            .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
        let cooperate = RDPClientControlPDU.cooperate(shareID: shareID)
            .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
        let requestControl = RDPClientControlPDU.requestControl(shareID: shareID)
            .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
        let fontList = RDPClientFontListPDU(shareID: shareID)
            .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
        report.rdpClientSynchronizeRequestHex = synchronize.rdpHexString
        report.rdpClientControlCooperateRequestHex = cooperate.rdpHexString
        report.rdpClientControlRequestHex = requestControl.rdpHexString
        report.rdpClientFontListRequestHex = fontList.rdpHexString

        maximumChunkByteCount = demandActive.serverVirtualChannelChunkSize
            ?? RDPStaticVirtualChannelPDU.maximumPayloadByteCount
        fastPathReassembler = RDPFastPathOutputFragmentReassembler(
            maximumBufferedByteCount: confirmActive.multifragmentUpdateMaxRequestSize
        )
        share = RDPActiveShare(
            shareID: shareID,
            serverInputFlags: demandActive.serverInputFlags,
            acknowledgesFrames: demandActive.capabilitySets.contains { $0.type == RDPCapabilitySetType.frameAcknowledge }
        )
        awaitingPostConfirmActiveResponse = true
        try send(confirmActivePacket)
        // The finalization PDUs do not wait for the server's ([MS-RDPBCGR] 1.3.1.1).
        stage = .finalization
        for packet in [synchronize, cooperate, requestControl, fontList] {
            try send(packet)
        }
    }

    private func finishActivation(_ share: RDPActiveShare) {
        stage = .graphics
        startPhase(captureOnly: true)
        guard let channel = transport?.channel else {
            return
        }
        callbacks.onInputReady?(RDPInputSession(
            shareID: share.shareID,
            userChannelID: userChannelID,
            ioChannelID: ioChannelID,
            channel: channel,
            serverInputFlags: share.serverInputFlags
        ))
    }

    /// Deactivate All starts a reactivation, unless a Set Error Info said the
    /// server is disconnecting.
    private func handleDeactivateAll() throws {
        isDeactivated = true
        startPhase()
        if let termination, termination.errorInfo != nil {
            if termination.isClean, graphicsOpened {
                try endSession(by: termination)
            } else {
                isTerminating = true
            }
        }
    }

    // MARK: Session end

    /// Ends the session for a termination: a clean one after the graphics
    /// pipeline opened is a normal end, anything else a failure.
    func endSession(by termination: RDPRemoteTermination) throws {
        if termination.isClean, graphicsOpened {
            sessionEnded = true
            return
        }
        if stage == .graphics, !graphicsOpened {
            throw RDPPreflightError.protocolViolation("\(termination.description) before opening RDPGFX dynamic channel")
        }
        throw RDPPreflightError.protocolViolation(termination.description)
    }

    /// A close after the server announced the end is that end; otherwise only
    /// a close, never a lost connection, can end a live session normally.
    private func handleConnectionEnd(_ error: Error) throws {
        try callbacks.throwIfCancelled()
        if let termination {
            try endSession(by: termination)
            return
        }
        guard isConnectionClose(error) else {
            throw RDPPreflightError.receive("connection lost: \(connectionErrorDescription(error))")
        }
        if isDeactivated {
            throw RDPPreflightError.protocolViolation(deactivatedMessage)
        }
        if stage == .graphics, report.rdpGraphicsFirstFrame != nil, !hasPartialGraphicsData {
            sessionEnded = true
            return
        }
        throw RDPPreflightError.receive("connection closed before receiving \(awaitedMessage)")
    }

    private func handleReceiveTimeout() throws {
        if let termination, isTerminating {
            try endSession(by: termination)
            return
        }
        if isDeactivated {
            throw RDPPreflightError.protocolViolation(deactivatedMessage)
        }
        switch stage {
        case .confirmActive, .finalization:
            throw RDPPreflightError.protocolViolation(share?.finalization.receivedControlGranted == true
                ? "server did not send Font Map during connection finalization"
                : "server did not grant control during connection finalization")
        case .graphics:
            if targetFrameCount != nil, report.rdpGraphicsFirstFrame != nil, !hasPartialGraphicsData {
                sessionEnded = true
                return
            }
            if graphicsChannelID != nil, graphicsCompositor == nil {
                throw RDPPreflightError.protocolViolation(graphicsChannelID.flatMap { dynamicChannelFragments[$0] } != nil
                    ? "server did not complete fragmented RDPGFX capabilities data"
                    : "server did not confirm RDPGFX capabilities")
            }
        default:
            break
        }
        throw RDPPreflightError.receive("\(awaitedMessage) timed out after \(configuration.timeoutSeconds) seconds")
    }

    /// Graphics flow: RDPGFX capabilities are confirmed, or a frame arrived without RDPGFX.
    private var graphicsOpened: Bool {
        graphicsCompositor != nil || report.rdpGraphicsFirstFrame != nil
    }

    private var deactivatedMessage: String {
        graphicsCompositor == nil
            ? "server deactivated the session before opening RDPGFX dynamic channel"
            : "server deactivated the session during RDP graphics updates"
    }

    private var awaitedMessage: String {
        switch stage {
        case .autoDetect: "RDP Post Auto-Detect Response"
        case .licensing: "RDP Post Licensing Response"
        case .graphics: "RDP Graphics Update"
        default: "RDP Client Info Response"
        }
    }

    private var hasPartialGraphicsData: Bool {
        fastPathReassembler.isActive || graphicsChannelID.map { dynamicChannelFragments[$0] != nil } == true
    }
}

/// A server PDU on the I/O channel. Licensing PDUs come before the first
/// Demand Active and never after ([MS-RDPBCGR] 1.3.1.1), and the two headers
/// can be mistaken for each other: a Share Control totalLength can have the
/// SEC_LICENSE_PKT bit set, and a licensing flagsHi can read as a Share
/// Control type (4.1.11). So licensing is tried first, and only while it is
/// in progress.
enum RDPIOChannelPDU {
    case license(RDPServerLicensePDU)
    case shareControl(RDPShareControlPDU)

    static func parse(_ indication: MCSSendDataIndicationPDU, licensing: Bool) throws -> RDPIOChannelPDU? {
        if licensing, let license = try RDPServerLicensePDU.parseIfPresent(from: indication) {
            return .license(license)
        }
        return try RDPShareControlPDU.parseIfPresent(from: indication).map { .shareControl($0) }
    }
}
