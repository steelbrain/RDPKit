import Foundation

/// Graphics output: the RDPGFX channel ([MS-RDPEGFX] 3.2.5) and fast-path or
/// slow-path updates to the primary surface ([MS-RDPBCGR] 3.2.5.9).
///
/// ZGFX and segment errors break the decompressor history and end the session.
/// A PDU that fails to decode ends a capture run; a live session records it,
/// skips it and still acknowledges the frame so the server keeps sending.
extension RDPClientConnection {
    /// Video updates one frame may hold before its EndFrame; past this the
    /// server is not ending its frames.
    static let maximumPendingVideoFrameCount = 64
    /// The same for copies, which servers send one per rectangle.
    static let maximumPendingGraphicsUpdateCount = 4_096

    func openGraphicsPipeline(channelID: UInt32) throws {
        graphicsChannelID = channelID
        graphicsDecoder = RDPGFXServerTransportDecoder()
        // A new pipeline starts without surfaces or cache; the previous one's are gone.
        deletedGraphicsSurfaceIDs += graphicsCompositor?.surfaceIDs ?? []
        evictedGraphicsCacheSlots += graphicsCompositor?.decoderCacheSlots ?? []
        graphicsCompositor = nil
        graphicsFrameTracker = RDPGFXLogicalFrameTracker()
        pendingGraphicsUpdates = []
        // totalFramesDecoded counts from the channel's creation ([MS-RDPEGFX] 2.2.2.13).
        graphicsFramesDecoded = 0
        startPhase()
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
            throw RDPConnectionError.protocolViolation(
                "server confirmed an RDPGFX capability version that the client did not advertise"
            )
        }
        deletedGraphicsSurfaceIDs += graphicsCompositor?.surfaceIDs ?? []
        evictedGraphicsCacheSlots += graphicsCompositor?.decoderCacheSlots ?? []
        graphicsCompositor = RDPGFXSurfaceCompositor(
            capabilitySet: confirm.capabilitySet,
            outputWidth: desktopWidth,
            outputHeight: desktopHeight
        )
        startPhase(captureOnly: true)
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
        if let copy = try compositor.process(message, clearCodec: clearCodec) {
            try checkPendingRoom(isVideo: false)
            var frame = surfaceCopyFrame(copy, typeName: message.typeName)
            // Evictions since the previous copy happen before this one.
            frame.evictedCacheSlots = compositor.takeEvictedDecoderCacheSlots()
            pendingGraphicsUpdates.append(.frame(frame))
        }

        switch message.commandID {
        case RDPGFXCommandID.wireToSurface1:
            if let frame = try videoFrame(RDPGFXWireToSurface1PDU.parse(from: message), compositor: compositor) {
                try checkPendingRoom(isVideo: true)
                pendingGraphicsUpdates.append(.frame(frame))
                compositor.noteVideo(frame)
            }
        case RDPGFXCommandID.deleteSurface:
            // Updates already queued for the surface have nowhere to go, and a surface
            // created later with the same ID must not inherit its decoder state.
            let surfaceID = try RDPGFXDeleteSurfacePDU.parse(from: message).surfaceID
            pendingGraphicsUpdates.removeAll { $0.needs(surfaceID: surfaceID) }
            deletedGraphicsSurfaceIDs.append(surfaceID)
        case RDPGFXCommandID.surfaceToSurface:
            let copy = try RDPGFXSurfaceToSurfacePDU.parse(from: message)
            let copiesStagedVideo = !compositor.isOnDecoder(surfaceID: copy.sourceSurfaceID)
                && copy.sourceSurfaceID != copy.destinationSurfaceID
                && pendingGraphicsUpdates.contains { $0.isVideo(surfaceID: copy.sourceSurfaceID) }
            if copiesStagedVideo {
                try checkPendingRoom(isVideo: false)
                pendingGraphicsUpdates.append(.stagedVideoCopy(copy))
            }
        case RDPGFXCommandID.endFrame:
            return try RDPGFXEndFramePDU.parse(from: message).frameID
        default:
            break
        }
        return nil
    }

    /// The ended frame's snapshots. The decoder's updates come first, in wire order, with
    /// gnome's staged video resolved and video for surfaces it does not hold dropped; then
    /// the bitmap snapshots, as other codecs' updates follow the video they were drawn over.
    private func endedFrameSnapshots(frameID: UInt32) -> [RDPGraphicsFrameSnapshot] {
        guard let compositor = graphicsCompositor else {
            return []
        }
        var frames: [RDPGraphicsFrameSnapshot] = []
        // Where each access unit went per destination surface, so it is decoded there once.
        var stagedFrameIndices: [StagedVideoKey: Int] = [:]
        for (index, update) in pendingGraphicsUpdates.enumerated() {
            switch update {
            case let .frame(frame):
                frames.append(frame)
            case let .stagedVideoCopy(copy):
                for (videoIndex, earlier) in pendingGraphicsUpdates[..<index].enumerated() {
                    guard case let .frame(video) = earlier, video.contentKind == .video, video.surfaceID == copy.sourceSurfaceID
                    else {
                        continue
                    }
                    for point in copy.destinationPoints {
                        guard let staged = stagedVideoCopy(of: video, sourceRect: copy.sourceRect, to: point, surfaceID: copy.destinationSurfaceID)
                        else {
                            continue
                        }
                        let key = StagedVideoKey(videoIndex: videoIndex, surfaceID: copy.destinationSurfaceID)
                        guard let stagedIndex = stagedFrameIndices[key] else {
                            stagedFrameIndices[key] = frames.count
                            frames.append(staged)
                            continue
                        }
                        // A second offset would decode the access unit twice; the first one wins.
                        if frames[stagedIndex].destinationRect == staged.destinationRect {
                            frames[stagedIndex].regionRects += staged.regionRects
                            frames[stagedIndex].auxiliaryRegionRects += staged.auxiliaryRegionRects
                        }
                    }
                }
            }
        }
        let decoderFrames = frames.compactMap { frame -> RDPGraphicsFrameSnapshot? in
            guard frame.contentKind != .video || compositor.isOnDecoder(surfaceID: frame.surfaceID) else {
                return nil
            }
            let surfaceRect = compositor.surfaceRect(surfaceID: frame.surfaceID)
            var mapped = frame
            mapped.graphicsOutputRect = compositor.outputRect()
            mapped.surfaceRect = surfaceRect
            mapped.mappedOutputRect = compositor.mappedOutputRect(surfaceID: frame.surfaceID)
            return mapped
        }
        return decoderFrames + compositor.makeFrames(frameID: frameID)
    }

    private func surfaceCopyFrame(_ copy: RDPGraphicsSurfaceCopy, typeName: String) -> RDPGraphicsFrameSnapshot {
        let surfaceID = switch (copy.destination, copy.source) {
        case let (.surface(surfaceID), _), let (.cacheSlot, .surface(surfaceID)):
            surfaceID
        case (.cacheSlot, .cacheSlot):
            UInt16(0)
        }
        let destinations = copy.destination == .surface(surfaceID) ? copy.blocks.map(\.destination) : []
        return RDPGraphicsFrameSnapshot(
            frameID: graphicsFrameTracker.activeFrameID,
            surfaceID: surfaceID,
            codecID: RDPGFXCodecID.uncompressed,
            codecName: typeName,
            pixelFormat: RDPGFXPixelFormat.xrgb8888,
            destinationRect: destinations.first.map { first in
                destinations.dropFirst().reduce(first) {
                    RDPFrameRect(
                        left: min($0.left, $1.left),
                        top: min($0.top, $1.top),
                        right: max($0.right, $1.right),
                        bottom: max($0.bottom, $1.bottom)
                    )
                }
            } ?? RDPFrameRect(left: 0, top: 0, right: 0, bottom: 0),
            regionRects: destinations,
            encodedVideoData: Data(),
            contentKind: .surfaceCopy,
            surfaceCopy: copy
        )
    }

    private func checkPendingRoom(isVideo: Bool) throws {
        let videoCount = pendingGraphicsUpdates.count { if case let .frame(frame) = $0 { frame.contentKind == .video } else { false } }
        guard !isVideo || videoCount < Self.maximumPendingVideoFrameCount else {
            throw RDPConnectionError.protocolViolation(
                "server sent more than \(Self.maximumPendingVideoFrameCount) video updates without ending the frame"
            )
        }
        guard pendingGraphicsUpdates.count < Self.maximumPendingGraphicsUpdateCount else {
            throw RDPConnectionError.protocolViolation(
                "server sent more than \(Self.maximumPendingGraphicsUpdateCount) updates without ending the frame"
            )
        }
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
        let frames = endedFrameSnapshots(frameID: frameID)
        pendingGraphicsUpdates = []
        // Evictions after the frame's last copy go with the next frame.
        let evictedCacheSlots = graphicsCompositor?.takeEvictedDecoderCacheSlots() ?? []
        try deliver(frames)
        evictedGraphicsCacheSlots += evictedCacheSlots
        startPhase(captureOnly: true)
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
            disconnect()
        }
    }

    /// Records the snapshots, then calls the application. A throwing handler
    /// ends the session; the frame is not acknowledged.
    private func deliver(_ frames: [RDPGraphicsFrameSnapshot]) throws {
        var frames = frames
        if !frames.isEmpty {
            frames[0].deletedSurfaceIDs = deletedGraphicsSurfaceIDs
            frames[0].evictedCacheSlots = evictedGraphicsCacheSlots + frames[0].evictedCacheSlots
            deletedGraphicsSurfaceIDs = []
            evictedGraphicsCacheSlots = []
        }
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
                throw RDPConnectionError.graphicsFrameHandler(error)
            }
        }
        if !frames.isEmpty {
            announceDisplayControl()
        }
    }

    private func recordGraphicsUpdatePacket(_ packet: Data) {
        report.rdpGraphicsUpdateResponseCount = (report.rdpGraphicsUpdateResponseCount ?? 0) + 1
        report.rdpGraphicsUpdateResponseHexes.appendIfRoom(packet.rdpHexString, limit: RDPRecordLimit.packets)
    }

    /// Keeps the start of the first failing update, for diagnosing the server's bytes.
    private func recordGraphicsFailure(packet: Data, payload: Data, messages: [RDPGFXHeader], index: Int?) {
        guard report.rdpGraphicsFailureUpdatePayloadHex == nil else {
            return
        }
        report.rdpGraphicsFailureUpdateResponseHex = packet.rdpHexString
        // A reassembled message can be megabytes, kept for the rest of a live session.
        report.rdpGraphicsFailureUpdatePayloadHex = payload.prefix(RDPRecordLimit.failurePayloadByteCount).rdpHexString
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
        if !frames.isEmpty {
            startPhase(captureOnly: true)
        }
        primaryFramesCaptured += frames.count
        if let targetFrameCount, primaryFramesCaptured >= targetFrameCount {
            disconnect()
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

/// An update for the decoder, held until its RDPGFX frame ends.
enum RDPPendingGraphicsUpdate {
    case frame(RDPGraphicsFrameSnapshot)
    /// A SurfaceToSurface out of a surface the decoder does not hold, after video for it.
    case stagedVideoCopy(RDPGFXSurfaceToSurfacePDU)

    func isVideo(surfaceID: UInt16) -> Bool {
        guard case let .frame(frame) = self else {
            return false
        }
        return frame.contentKind == .video && frame.surfaceID == surfaceID
    }

    /// Whether the update has nowhere to go once the surface is deleted.
    func needs(surfaceID: UInt16) -> Bool {
        switch self {
        case let .frame(frame):
            guard frame.surfaceID == surfaceID else {
                return false
            }
            // A copy into the cache took its pixels before the surface went.
            if case .cacheSlot = frame.surfaceCopy?.destination {
                return false
            }
            return true
        case let .stagedVideoCopy(copy):
            return copy.sourceSurfaceID == surfaceID || copy.destinationSurfaceID == surfaceID
        }
    }
}

private struct StagedVideoKey: Hashable {
    var videoIndex: Int
    var surfaceID: UInt16
}

/// `video`'s regions inside `sourceRect`, as an update of another surface at `point`.
/// gnome-remote-desktop encodes video into an unmapped staging surface, then copies each
/// region rectangle to the mapped surface with a SurfaceToSurface of its own (gnome fixture,
/// sequence 143-144; blit_surface_to_surface in grd-rdp-dvc-graphics-pipeline.c). The
/// decoder never gets the staging surface, so the destination's decoder gets the access
/// unit instead, and with every one of them stays in step with the staging surface's.
func stagedVideoCopy(
    of video: RDPGraphicsFrameSnapshot,
    sourceRect: RDPGFXRect16,
    to point: RDPGFXPoint16,
    surfaceID: UInt16
) -> RDPGraphicsFrameSnapshot? {
    let xOffset = Int(point.x) - Int(sourceRect.left)
    let yOffset = Int(point.y) - Int(sourceRect.top)
    let update = video.destinationRect
    guard let left = UInt16(exactly: Int(update.left) + xOffset),
          let top = UInt16(exactly: Int(update.top) + yOffset),
          let right = UInt16(exactly: Int(update.right) + xOffset),
          let bottom = UInt16(exactly: Int(update.bottom) + yOffset)
    else {
        return nil
    }
    let relative = video.hasRelativeRegions
    // The copied part of each region, relative to the update, which moves with it.
    func copied(_ regions: [RDPFrameRect]) -> [RDPFrameRect] {
        regions.compactMap { region in
            let region = video.surfaceRegion(region, relative: relative)
            let left = max(Int(region.left), Int(sourceRect.left), Int(update.left)) - Int(update.left)
            let top = max(Int(region.top), Int(sourceRect.top), Int(update.top)) - Int(update.top)
            let right = min(Int(region.right), Int(sourceRect.right), Int(update.right)) - Int(update.left)
            let bottom = min(Int(region.bottom), Int(sourceRect.bottom), Int(update.bottom)) - Int(update.top)
            guard right > left, bottom > top else {
                return nil
            }
            return RDPFrameRect(left: UInt16(left), top: UInt16(top), right: UInt16(right), bottom: UInt16(bottom))
        }
    }
    let regions = copied(video.regionRects.isEmpty && video.auxiliaryRegionRects.isEmpty
        ? [RDPFrameRect(left: 0, top: 0, right: update.width, bottom: update.height)]
        : video.regionRects)
    let auxiliaryRegions = copied(video.auxiliaryRegionRects)
    guard !(regions + auxiliaryRegions).isEmpty else {
        return nil
    }
    var staged = video
    staged.surfaceID = surfaceID
    staged.surfaceRect = nil
    staged.mappedOutputRect = nil
    staged.destinationRect = RDPFrameRect(left: left, top: top, right: right, bottom: bottom)
    staged.regionRects = regions
    staged.auxiliaryRegionRects = auxiliaryRegions
    return staged
}
