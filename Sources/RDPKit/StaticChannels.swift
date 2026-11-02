import Foundation

/// Static virtual channels ([MS-RDPBCGR] 3.1.5.2). drdynvc errors end the
/// session; an error on cliprdr, rdpsnd or rdpdr is recorded as a warning and
/// affects only that channel.
extension RDPClientConnection {
    func handleStaticChannel(_ indication: MCSSendDataIndicationPDU, name: String, packet: Data) throws {
        let isDynamicChannelTransport = name == RDPStaticVirtualChannel.drdynvc.name
        let maximumChunkByteCount = staticChannelChunkSize.byteCount
        let payload: Data
        // The start of the cliprdr message an error drops: the chunk's own, or the one it continues.
        var clipboardMessageStart: Data?
        do {
            let chunk: RDPStaticVirtualChannelPDU
            do {
                chunk = try RDPStaticVirtualChannelPDU.parse(
                    fromUserData: indication.userData,
                    maximumChunkByteCount: maximumChunkByteCount
                )
            } catch {
                // A chunk `parse` rejects, such as FIRST and LAST with a totalLength its data
                // does not have, still starts a message when its flags say FIRST: it ends the
                // message being reassembled, as a FIRST chunk that parses does ([MS-RDPBCGR]
                // 3.1.5.2.2.1), and its own message is lost.
                if name == RDPStaticVirtualChannel.cliprdr.name,
                   let payload = RDPStaticVirtualChannelPDU.firstChunkPayload(fromUserData: indication.userData)
                {
                    staticChannelReassemblers[indication.channelID] = nil
                    clipboardMessageStart = payload
                }
                throw error
            }
            if name == RDPStaticVirtualChannel.cliprdr.name {
                clipboardMessageStart = chunk.isFirst
                    ? chunk.payload
                    : staticChannelReassemblers[indication.channelID]?.pendingMessagePrefix
            }
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
            if let clipboardMessageStart {
                handleLostClipboardMessage(startingWith: clipboardMessageStart)
            }
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
        let pdu: RDPClipboardPDU
        do {
            pdu = try RDPClipboardPDU.parse(from: payload)
        } catch {
            recordChannelError(RDPStaticVirtualChannel.cliprdr.name, error)
            handleLostClipboardMessage(startingWith: payload)
            return
        }
        report.rdpClipboardMessages.appendCapped(.summarize(pdu), limit: RDPRecordLimit.messages)
        // A response that fails here has already answered its request in the session.
        do {
            try deliver(clipboard.receive(pdu), from: clipboard)
        } catch {
            recordChannelError(RDPStaticVirtualChannel.cliprdr.name, error)
        }
    }

    /// A Format Data Response dropped whole, such as one over the 64 MiB a message may
    /// hold, one whose first chunk does not parse, one with a bad later chunk, or one whose
    /// header does not parse, still answers the request it was for: left outstanding, that
    /// request would hold back every later remote copy of the session.
    private func handleLostClipboardMessage(startingWith payload: Data) {
        var cursor = ByteCursor(payload)
        guard let clipboard,
              (try? cursor.readLittleEndianUInt16()) == RDPClipboardMessageType.formatDataResponse
        else {
            return
        }
        deliver(clipboard.receiveLostFormatDataResponse(), from: clipboard)
    }

    /// Delivers the event turning `fetchesRemoteCopies` on queued, if it still holds.
    func deliverPendingClipboardEvent() {
        if let clipboard {
            deliver(clipboard.takePendingEvent(), from: clipboard)
        }
    }

    private func deliver(_ event: RDPClipboardEvent?, from clipboard: RDPClipboardSession) {
        switch event {
        case .ready:
            callbacks.onClipboardReady?(clipboard)
        case let .text(text):
            callbacks.onClipboardText?(text, clipboard.deliveredRemoteCopyNumber)
        case let .content(content):
            let copyNumber = clipboard.deliveredRemoteCopyNumber
            if let text = content.text {
                callbacks.onClipboardText?(text, copyNumber)
            }
            callbacks.onClipboardContent?(content, copyNumber)
        case let .fileGroupDescriptor(descriptor):
            callbacks.onClipboardFileGroupDescriptor?(descriptor, clipboard.deliveredRemoteCopyNumber)
        case let .remoteCopyUnavailable(isEmpty):
            callbacks.onClipboardRemoteCopyUnavailable?(isEmpty, clipboard.deliveredRemoteCopyNumber)
        case let .fileContents(contents):
            callbacks.onClipboardFileContents?(contents)
        case nil:
            break
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
        // Read before the sample is handed on, so it counts only the audio ahead of it.
        let playbackDelay = callbacks.audioPlaybackDelay?() ?? .zero
        callbacks.onAudioSample?(sample)
        session.confirmConsumed(sample, playbackDelay: playbackDelay)
    }

    /// A broken rdpdr exchange stops device redirection only.
    private func handleDeviceRedirection(_ payload: Data) {
        guard let deviceRedirection else {
            return
        }
        do {
            try recordDeviceRedirectionEvents(deviceRedirection.receive(RDPDeviceRedirectionPDU.parse(from: payload)))
        } catch {
            recordChannelError(RDPStaticVirtualChannel.rdpdr.name, error)
            self.deviceRedirection = nil
        }
    }

    /// Records the events device redirection's I/O queue left for the session thread.
    func deliverPendingDeviceRedirectionEvents() {
        if let deviceRedirection {
            recordDeviceRedirectionEvents(deviceRedirection.takePendingEvents())
        }
    }

    private func recordDeviceRedirectionEvents(_ events: [RDPDeviceRedirectionEvent]) {
        for event in events {
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
    }
}
