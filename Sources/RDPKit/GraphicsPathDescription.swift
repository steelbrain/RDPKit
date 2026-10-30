import Foundation

public enum RDPGraphicsPathDescription {
    public static func describe(report: RDPConnectionReport?) -> String {
        guard let report else {
            return "not negotiated"
        }
        return describe(
            selectedCapabilityVersion: report.rdpGraphicsSelectedCapabilityVersion,
            selectedCapabilityFlags: report.rdpGraphicsSelectedCapabilityFlags,
            firstFrame: report.rdpGraphicsFirstFrame,
            updateMessages: report.rdpGraphicsUpdateMessages
        )
    }

    public static func describe(
        selectedCapabilityVersion: UInt32?,
        selectedCapabilityFlags: UInt32?,
        firstFrame: RDPGraphicsFrameSnapshot?,
        updateMessages: [RDPGFXMessageSummary]?
    ) -> String {
        let capability = capabilityDescription(
            version: selectedCapabilityVersion,
            flags: selectedCapabilityFlags
        )
        if let firstFrame {
            if firstFrame.contentKind == .bitmap,
               let update = updateMessages?.first(where: { $0.codecName != nil })
            {
                return "\(capability) -> \(updateDescription(update)) -> \(frameDescription(firstFrame))"
            }
            return "\(capability) -> \(frameDescription(firstFrame))"
        }
        if let update = updateMessages?.first(where: { $0.codecName != nil }) {
            return "\(capability) -> \(updateDescription(update))"
        }
        return capability
    }

    private static func capabilityDescription(version: UInt32?, flags: UInt32?) -> String {
        guard let version else {
            return "graphics not confirmed"
        }

        var parts: [String]
        switch version {
        case RDPGFXCapabilityVersion.version107:
            parts = ["RDPGFX v10.7"]
            if let flags, flags & RDPGFXCapabilityFlags.avcDisabled != 0 {
                parts.append("AVC disabled")
            } else if let flags, flags & RDPGFXCapabilityFlags.avcThinClient != 0 {
                parts.append("AVC thin-client")
            }
            if let flags, flags & RDPGFXCapabilityFlags.scaledMapDisabled != 0 {
                parts.append("scaled-map disabled")
            }
        case RDPGFXCapabilityVersion.version81:
            parts = ["RDPGFX v8.1"]
            if let flags, flags & RDPGFXCapabilityFlags.thinClient != 0 {
                parts.append("thin-client")
            }
            if let flags, flags & RDPGFXCapabilityFlags.avc420Enabled != 0 {
                parts.append("AVC420")
            }
        case RDPGFXCapabilityVersion.version8:
            parts = ["RDPGFX v8"]
            if let flags, flags & RDPGFXCapabilityFlags.thinClient != 0 {
                parts.append("thin-client")
            }
        default:
            parts = ["RDPGFX 0x\(String(format: "%08x", version))"]
        }

        if let flags {
            parts.append("flags=0x\(String(format: "%08x", flags))")
        }
        return parts.joined(separator: " ")
    }

    private static func frameDescription(_ frame: RDPGraphicsFrameSnapshot) -> String {
        if frame.contentKind == .video {
            return "\(frame.codecName)/\(frame.videoCodec.displayName)"
        }
        return frame.codecName
    }

    private static func updateDescription(_ message: RDPGFXMessageSummary) -> String {
        guard let codecName = message.codecName else {
            return message.typeName
        }
        if codecName == "caprogressive",
           let tileCount = message.progressiveRegionTileCount
        {
            return "\(message.typeName) \(codecName) tiles=\(tileCount)"
        }
        if codecName == "cavideo",
           let tileCount = message.cavideoTileCount,
           let entropy = message.cavideoTileSetEntropyAlgorithms?.last
        {
            return "\(message.typeName) \(codecName) remotefx tiles=\(tileCount) entropy=\(entropy)"
        }
        return "\(message.typeName) \(codecName)"
    }
}
