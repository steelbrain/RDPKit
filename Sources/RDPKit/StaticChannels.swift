import Foundation

/// Static virtual channels ([MS-RDPBCGR] 3.1.5.2). drdynvc errors end the
/// session; an error on cliprdr, rdpsnd or rdpdr is recorded as a warning and
/// affects only that channel.
extension RDPClientConnection {
    func handleStaticChannel(_ indication: MCSSendDataIndicationPDU, name: String, packet: Data) throws {
        let isDynamicChannelTransport = name == RDPStaticVirtualChannel.drdynvc.name
        let maximumChunkByteCount = staticChannelChunkSize.byteCount
        let payload: Data
        do {
            let chunk = try RDPStaticVirtualChannelPDU.parse(
                fromUserData: indication.userData,
                maximumChunkByteCount: maximumChunkByteCount
            )
            // Appended in place: a copy out of the dictionary would copy the partial message per chunk.
            guard let message = try staticChannelReassemblers[indication.channelID, default: .init()]
                .append(chunk, maximumChunkByteCount: maximumChunkByteCount)
            else {
                return
            }
            payload = message.payload
        } catch {
            if isDynamicChannelTransport {
                throw error
            }
            recordChannelError(name, error)
            return
        }

        switch name {
        case RDPStaticVirtualChannel.drdynvc.name:
            try handleDynamicChannelPDU(payload, packet: packet)
        case RDPStaticVirtualChannel.cliprdr.name:
            handleClipboard(payload)
        case RDPStaticVirtualChannel.rdpsnd.name:
            if let audio {
                handleAudio(payload, session: audio)
            }
        case RDPStaticVirtualChannel.rdpdr.name:
            handleDeviceRedirection(payload)
        default:
            break
        }
    }

    func recordChannelError(_ channel: String, _ error: Error) {
        appendWarning(code: "virtual-channel-error", message: "\(channel): \(error)")
    }

    private func handleClipboard(_ payload: Data) {
        guard let clipboard else {
            return
        }
        do {
            let pdu = try RDPClipboardPDU.parse(from: payload)
            report.rdpClipboardMessages.appendCapped(.summarize(pdu), limit: RDPRecordLimit.messages)
            switch try clipboard.receive(pdu) {
            case .ready:
                callbacks.onClipboardReady?(clipboard)
            case let .text(text):
                callbacks.onClipboardText?(text)
            case let .content(content):
                if let text = content.text {
                    callbacks.onClipboardText?(text)
                }
                callbacks.onClipboardContent?(content)
            case let .fileGroupDescriptor(descriptor):
                callbacks.onClipboardFileGroupDescriptor?(descriptor)
            case let .remoteCopyUnavailable(isEmpty):
                callbacks.onClipboardRemoteCopyUnavailable?(isEmpty)
            case let .fileContents(contents):
                callbacks.onClipboardFileContents?(contents)
            case nil:
                break
            }
        } catch {
            recordChannelError(RDPStaticVirtualChannel.cliprdr.name, error)
        }
    }

    /// Handles one rdpsnd PDU from the static channel or AUDIO_PLAYBACK_DVC ([MS-RDPEA] 3.2.5).
    func handleAudio(_ payload: Data, session: RDPAudioSession) {
        do {
            let receivedAt = Date()
            // A Wave PDU has no header; it follows the WaveInfo PDU that announced it.
            if let sample = try session.receiveWaveData(payload, receivedAt: receivedAt) {
                report.rdpAudioMessages.appendCapped(
                    RDPAudioMessageSummary(typeName: "audio-wave-data", bodySize: UInt16(clamping: payload.count)),
                    limit: RDPRecordLimit.messages
                )
                deliverAudio(sample, session: session)
                return
            }
            let pdu = try RDPAudioPDU.parse(from: payload)
            report.rdpAudioMessages.appendCapped(.summarize(pdu), limit: RDPRecordLimit.messages)
            if let formats = try RDPAudioFormatsPDU.parseIfPresent(from: pdu) {
                session.respondToServerFormats(formats)
            } else if let training = try RDPAudioTrainingPDU.parseIfPresent(from: pdu) {
                session.respondToTraining(training)
            } else if let sample = try session.receive(pdu, receivedAt: receivedAt) {
                deliverAudio(sample, session: session)
            }
        } catch {
            recordChannelError(RDPStaticVirtualChannel.rdpsnd.name, error)
        }
    }

    private func deliverAudio(_ sample: RDPAudioSample, session: RDPAudioSession) {
        callbacks.onAudioSample?(sample)
        session.confirmConsumed(sample)
    }

    /// A broken rdpdr exchange stops device redirection only.
    private func handleDeviceRedirection(_ payload: Data) {
        guard let deviceRedirection else {
            return
        }
        do {
            for event in try deviceRedirection.receive(RDPDeviceRedirectionPDU.parse(from: payload)) {
                switch event {
                case let .driveUnavailable(name):
                    appendWarning(code: "shared-drive-unavailable", message: "\(name): the shared folder does not exist")
                case let .driveRejected(name, status):
                    appendWarning(
                        code: "shared-drive-rejected",
                        message: "\(name): the server refused the drive with 0x\(String(format: "%08x", status))"
                    )
                }
            }
        } catch {
            recordChannelError(RDPStaticVirtualChannel.rdpdr.name, error)
            self.deviceRedirection = nil
        }
    }
}
