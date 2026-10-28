import Foundation

/// Graphics output: the RDPGFX channel ([MS-RDPEGFX] 3.2.5) and fast-path or
/// slow-path updates to the primary surface ([MS-RDPBCGR] 3.2.5.9).
///
/// ZGFX and segment errors break the decompressor history and end the session.
/// A PDU that fails to decode ends a capture run; a live session records it,
/// skips it and still acknowledges the frame so the server keeps sending.
extension RDPClientConnection {
    func openGraphicsPipeline(channelID: UInt32) throws {
        graphicsChannelID = channelID
        graphicsDecoder = RDPGFXServerTransportDecoder()
        graphicsCompositor = nil
        graphicsFrameTracker = RDPGFXLogicalFrameTracker()
        pendingGraphicsFrames = []
        let advertise = RDPGFXCapsAdvertisePDU(capabilitySets: configuration.graphicsCapabilityProfile.capabilitySets)
        report.rdpGraphicsCapsAdvertiseHex = try sendDynamicChannelData(advertise.encoded(), channelID: channelID)
            .rdpHexString
    }

    func handleGraphicsMessage(_ payload: Data, packet: Data) throws {
        let messages: [RDPGFXHeader]
        do {
            messages = try graphicsDecoder.decodeGraphicsMessages(from: payload)
        } catch {
            recordGraphicsFailure(packet: packet, payload: payload, messages: [], index: nil)
            throw error
        }
        if report.rdpGraphicsResponseType == nil, let first = messages.first {
            report.rdpGraphicsResponseHex = packet.rdpHexString
            report.rdpGraphicsResponseType = first.typeName
        }
        if graphicsCompositor != nil {
            recordGraphicsUpdatePacket(packet)
        }

        for (index, message) in messages.enumerated() where !sessionEnded {
            if message.commandID == RDPGFXCommandID.capsConfirm {
                try confirmGraphicsCapabilities(message)
                continue
            }
            // Nothing but CapsConfirm is valid before it ([MS-RDPEGFX] 3.2.5.2).
            guard let compositor = graphicsCompositor else {
                continue
            }
            var endedFrameID: UInt32?
            do {
                endedFrameID = try processGraphicsMessage(message, compositor: compositor)
            } catch {
                recordGraphicsFailure(packet: packet, payload: payload, messages: messages, index: index)
                if targetFrameCount != nil {
                    throw error
                }
                appendWarning(code: "graphics-decode-error", message: "\(message.typeName): \(error)")
                if message.commandID == RDPGFXCommandID.endFrame {
                    endedFrameID = try? RDPGFXEndFramePDU.parse(from: message).frameID
                }
            }
            if let endedFrameID {
                try finishGraphicsFrame(endedFrameID)
            }
        }
    }

    private func confirmGraphicsCapabilities(_ message: RDPGFXHeader) throws {
        guard let confirm = try RDPGFXCapsConfirmPDU.parse(from: message) else {
            return
        }
        report.rdpGraphicsSelectedCapabilityVersion = confirm.capabilitySet.version
        report.rdpGraphicsSelectedCapabilityFlags = confirm.capabilitySet.flags
        let advertised = configuration.graphicsCapabilityProfile.capabilitySets.map(\.version)
        guard advertised.contains(confirm.capabilitySet.version) else {
            throw RDPPreflightError.protocolViolation(
                "server confirmed an RDPGFX capability version that the client did not advertise"
            )
        }
        graphicsCompositor = RDPGFXSurfaceCompositor(
            capabilitySet: confirm.capabilitySet,
            outputWidth: configuration.desktopWidth,
            outputHeight: configuration.desktopHeight
        )
    }

    /// Applies one RDPGFX PDU; returns the frame ID when it ends a frame.
    private func processGraphicsMessage(_ message: RDPGFXHeader, compositor: RDPGFXSurfaceCompositor) throws -> UInt32? {
        try graphicsFrameTracker.track(message)
        let messageLimit = recordedGraphicsMessageLimit(targetFrameCount: targetFrameCount)
        if report.rdpGraphicsUpdateMessages.hasRoom(limit: messageLimit),
           let summary = try? RDPGFXMessageSummary.summarize(message, includeVideoDetails: targetFrameCount != nil)
        {
            report.rdpGraphicsUpdateMessages.appendIfRoom(summary, limit: messageLimit)
        }
        try compositor.process(message, clearCodec: clearCodec)

        switch message.commandID {
        case RDPGFXCommandID.wireToSurface1:
            if let frame = try videoFrame(RDPGFXWireToSurface1PDU.parse(from: message), compositor: compositor) {
                pendingGraphicsFrames.append(frame)
            }
        case RDPGFXCommandID.surfaceToSurface:
            pendingGraphicsFrames += try copiedVideoFrames(
                pendingGraphicsFrames,
                using: RDPGFXSurfaceToSurfacePDU.parse(from: message)
            )
        case RDPGFXCommandID.endFrame:
            let endFrame = try RDPGFXEndFramePDU.parse(from: message)
            // Video for a surface deleted within the frame has nowhere to go.
            let videoFrames = pendingGraphicsFrames.compactMap { frame -> RDPGraphicsFrameSnapshot? in
                guard frame.contentKind == .video,
                      let surfaceRect = compositor.surfaceRect(surfaceID: frame.surfaceID)
                else {
                    return nil
                }
                var mapped = frame
                mapped.graphicsOutputRect = compositor.outputRect()
                mapped.surfaceRect = surfaceRect
                mapped.mappedOutputRect = compositor.mappedOutputRect(surfaceID: frame.surfaceID)
                return mapped
            }
            pendingGraphicsFrames = videoFrames + compositor.makeFrames(
                frameID: endFrame.frameID,
                excludingSurfaceIDs: Set(videoFrames.map(\.surfaceID))
            )
            return endFrame.frameID
        default:
            break
        }
        return nil
    }

    private func videoFrame(
        _ wire: RDPGFXWireToSurface1PDU,
        compositor: RDPGFXSurfaceCompositor
    ) throws -> RDPGraphicsFrameSnapshot? {
        let primary: RDPGFXAVC420BitmapStream
        var auxiliary: RDPGFXAVC420BitmapStream?
        var layout: RDPAVC444SubframeLayout?
        switch wire.codecID {
        case RDPGFXCodecID.avc420:
            primary = try RDPGFXAVC420BitmapStream.parse(from: wire.bitmapData)
        case RDPGFXCodecID.avc444, RDPGFXCodecID.avc444v2:
            let avc444 = try RDPGFXAVC444BitmapStream.parse(from: wire.bitmapData)
            primary = avc444.firstStream
            auxiliary = avc444.secondStream
            layout = switch avc444.layoutCode {
            case .yuv420AndChroma420: .yuv420AndChroma420
            case .yuv420Only: .yuv420Only
            case .chroma420Only: .chroma420Only
            }
        default:
            return nil
        }
        return RDPGraphicsFrameSnapshot(
            frameID: graphicsFrameTracker.activeFrameID,
            surfaceID: wire.surfaceID,
            codecID: wire.codecID,
            codecName: RDPGFXCodecID.name(for: wire.codecID),
            videoCodec: .h264,
            pixelFormat: wire.pixelFormat,
            graphicsOutputRect: compositor.outputRect(),
            surfaceRect: compositor.surfaceRect(surfaceID: wire.surfaceID),
            mappedOutputRect: compositor.mappedOutputRect(surfaceID: wire.surfaceID),
            destinationRect: RDPFrameRect(wire.destinationRect),
            regionRects: primary.regionRects.map(RDPFrameRect.init),
            encodedVideoData: primary.encodedBitstream,
            auxiliaryEncodedVideoData: auxiliary?.encodedBitstream,
            auxiliaryRegionRects: auxiliary?.regionRects.map(RDPFrameRect.init) ?? [],
            avc444SubframeLayout: layout
        )
    }

    /// Hands the frame's snapshots to the application, then sends the
    /// RDPGFX_FRAME_ACKNOWLEDGE_PDU ([MS-RDPEGFX] 3.2.5.4) for every EndFrame.
    private func finishGraphicsFrame(_ frameID: UInt32) throws {
        let frames = pendingGraphicsFrames
        pendingGraphicsFrames = []
        try deliver(frames)
        guard let graphicsChannelID else {
            return
        }
        graphicsFramesDecoded &+= 1
        let acknowledge = RDPGFXFrameAcknowledgePDU(frameID: frameID, totalFramesDecoded: graphicsFramesDecoded)
        let packet = try sendDynamicChannelData(acknowledge.encoded(), channelID: graphicsChannelID)
        report.rdpGraphicsFrameAcknowledgeHexes.appendIfRoom(
            packet.rdpHexString,
            limit: recordedGraphicsAcknowledgeLimit(targetFrameCount: targetFrameCount)
        )
        if let targetFrameCount, graphicsFramesDecoded >= UInt32(clamping: targetFrameCount) {
            sessionEnded = true
        }
    }

    /// Records the snapshots, then calls the application. A throwing handler
    /// ends the session; the frame is not acknowledged.
    private func deliver(_ frames: [RDPGraphicsFrameSnapshot]) throws {
        for frame in frames {
            if report.rdpGraphicsFirstFrame == nil {
                report.rdpGraphicsFirstFrame = frame
            }
            report.rdpGraphicsFrames.appendCapped(frame, limit: recordedGraphicsFrameLimit(targetFrameCount: targetFrameCount))
        }
        for frame in frames {
            do {
                try callbacks.onGraphicsFrame?(frame)
            } catch {
                throw RDPPreflightError.graphicsFrameHandler(error)
            }
        }
    }

    private func recordGraphicsUpdatePacket(_ packet: Data) {
        report.rdpGraphicsUpdateResponseCount = (report.rdpGraphicsUpdateResponseCount ?? 0) + 1
        report.rdpGraphicsUpdateResponseHexes.appendIfRoom(packet.rdpHexString, limit: RDPRecordLimit.packets)
    }

    /// Keeps the first failing update, for diagnosing the server's bytes.
    private func recordGraphicsFailure(packet: Data, payload: Data, messages: [RDPGFXHeader], index: Int?) {
        guard report.rdpGraphicsFailureUpdatePayloadHex == nil else {
            return
        }
        report.rdpGraphicsFailureUpdateResponseHex = packet.rdpHexString
        report.rdpGraphicsFailureUpdatePayloadHex = payload.rdpHexString
        report.rdpGraphicsFailureUpdateMessages = messages.map { message in
            (try? RDPGFXMessageSummary.summarize(message, includeVideoDetails: false))
                ?? RDPGFXMessageSummary(typeName: message.typeName)
        }
        report.rdpGraphicsFailureUpdateMessageIndex = index
    }

    // MARK: Primary surface

    func handleFastPath(_ packet: Data) throws {
        let pdu = try RDPFastPathOutputPDU.parse(packet)
        recordGraphicsUpdatePacket(packet)
        let messageLimit = recordedGraphicsMessageLimit(targetFrameCount: nil)
        if report.rdpFastPathUpdateMessages.hasRoom(limit: messageLimit) {
            for summary in pdu.summaries {
                report.rdpFastPathUpdateMessages.appendIfRoom(summary, limit: messageLimit)
            }
        }
        for fragment in pdu.updates where !sessionEnded {
            guard let update = try fastPathReassembler.append(fragment) else {
                continue
            }
            if let pointer = update.pointerUpdate {
                applyPointer(pointer)
            } else if let error = update.pointerDecodeError {
                appendWarning(code: "pointer-error", message: String(describing: error))
            } else if let commands = update.surfaceCommands {
                try updatePrimarySurface { try primarySurface.process(commands) }
                try acknowledgeCompletedFrames()
            } else if let bitmap = update.bitmapUpdate {
                try updatePrimarySurface { try primarySurface.process(bitmap) }
            } else if let palette = update.paletteUpdate {
                primarySurface.updatePalette(palette)
            }
        }
    }

    func handleSlowPathGraphics(_ update: RDPSlowPathGraphicsUpdate, packet: Data) throws {
        recordGraphicsUpdatePacket(packet)
        switch update {
        case let .bitmap(bitmap):
            try updatePrimarySurface { try primarySurface.process(bitmap) }
        case let .palette(palette):
            primarySurface.updatePalette(palette)
        case .orders, .synchronize:
            break
        }
    }

    private func updatePrimarySurface(_ update: () throws -> [RDPGraphicsFrameSnapshot]) throws {
        let frames: [RDPGraphicsFrameSnapshot]
        do {
            frames = try update()
        } catch {
            if targetFrameCount != nil {
                throw error
            }
            appendWarning(code: "graphics-decode-error", message: String(describing: error))
            return
        }
        try deliver(frames)
        primaryFramesCaptured += frames.count
        if let targetFrameCount, primaryFramesCaptured >= targetFrameCount {
            sessionEnded = true
        }
    }

    /// One Frame Acknowledge per frame marker End, empty frames included, when
    /// both sides advertised the capability ([MS-RDPBCGR] 2.2.12.1, [MS-RDPRFX] 2.2.3.3).
    private func acknowledgeCompletedFrames() throws {
        let frameIDs = primarySurface.takeCompletedFrameIDs()
        guard let share, share.acknowledgesFrames else {
            return
        }
        for frameID in frameIDs {
            let packet = RDPClientFrameAcknowledgePDU(shareID: share.shareID, frameID: frameID)
                .encodedTPKT(userChannelID: userChannelID, ioChannelID: ioChannelID)
            report.rdpGraphicsFrameAcknowledgeHexes.appendIfRoom(
                packet.rdpHexString,
                limit: recordedGraphicsAcknowledgeLimit(targetFrameCount: targetFrameCount)
            )
            try send(packet)
        }
    }

    func applyPointer(_ update: RDPServerPointerUpdate) {
        do {
            callbacks.onRemotePointer?(try pointerState.apply(update))
        } catch {
            appendWarning(code: "pointer-error", message: String(describing: error))
        }
    }
}

/// Copies of this frame's video for a SurfaceToSurface out of its surface.
/// gnome-remote-desktop encodes AVC420 into an unmapped staging surface and
/// copies it to the mapped one every frame (gnome fixture, sequence 143-144).
/// A same-surface copy, such as a scroll, would decode the access unit twice.
func copiedVideoFrames(
    _ frames: [RDPGraphicsFrameSnapshot],
    using copy: RDPGFXSurfaceToSurfacePDU
) -> [RDPGraphicsFrameSnapshot] {
    guard copy.sourceSurfaceID != copy.destinationSurfaceID else {
        return []
    }
    let sourceRect = RDPFrameRect(copy.sourceRect)
    return frames.filter {
        $0.contentKind == .video && $0.surfaceID == copy.sourceSurfaceID
    }.flatMap { frame -> [RDPGraphicsFrameSnapshot] in
        guard sourceRect.left <= frame.destinationRect.left,
              sourceRect.top <= frame.destinationRect.top,
              sourceRect.right >= frame.destinationRect.right,
              sourceRect.bottom >= frame.destinationRect.bottom
        else {
            return []
        }
        return copy.destinationPoints.compactMap { point in
            let xOffset = Int(point.x) - Int(sourceRect.left)
            let yOffset = Int(point.y) - Int(sourceRect.top)
            guard let left = UInt16(exactly: Int(frame.destinationRect.left) + xOffset),
                  let top = UInt16(exactly: Int(frame.destinationRect.top) + yOffset),
                  let right = UInt16(exactly: Int(frame.destinationRect.right) + xOffset),
                  let bottom = UInt16(exactly: Int(frame.destinationRect.bottom) + yOffset)
            else {
                return nil
            }
            var copied = frame
            copied.surfaceID = copy.destinationSurfaceID
            copied.surfaceRect = nil
            copied.mappedOutputRect = nil
            copied.destinationRect = RDPFrameRect(left: left, top: top, right: right, bottom: bottom)
            return copied
        }
    }
}
