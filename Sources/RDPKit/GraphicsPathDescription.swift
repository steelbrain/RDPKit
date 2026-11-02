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

        typealias Flags = RDPGFXCapabilityFlags
        let name = versionName(version) ?? "0x\(String(format: "%08x", version))"
        var parts = ["RDPGFX \(name)"]
        // Flags the version does not define are ignored, as RDPGFXCapabilitySet.flags ignores them.
        let definedFlags = (flags ?? 0) & (RDPGFXCapabilitySet.definedFlags(for: version) ?? 0)
        if definedFlags & Flags.thinClient != 0 {
            parts.append("thin-client")
        }
        if definedFlags & Flags.avc420Enabled != 0 {
            parts.append("AVC420")
        }
        if definedFlags & Flags.avcDisabled != 0 {
            parts.append("AVC disabled")
        } else if definedFlags & Flags.avcThinClient != 0 {
            parts.append("AVC thin-client")
        }
        if definedFlags & Flags.scaledMapDisabled != 0 {
            parts.append("scaled-map disabled")
        }

        if let flags {
            parts.append("flags=0x\(String(format: "%08x", flags))")
        }
        return parts.joined(separator: " ")
    }

    private static func versionName(_ version: UInt32) -> String? {
        switch version {
        case RDPGFXCapabilityVersion.version8: "v8"
        case RDPGFXCapabilityVersion.version81: "v8.1"
        case RDPGFXCapabilityVersion.version10: "v10.0"
        case RDPGFXCapabilityVersion.version101: "v10.1"
        case RDPGFXCapabilityVersion.version102: "v10.2"
        case RDPGFXCapabilityVersion.version103: "v10.3"
        case RDPGFXCapabilityVersion.version104: "v10.4"
        case RDPGFXCapabilityVersion.version105: "v10.5"
        case RDPGFXCapabilityVersion.version106: "v10.6"
        case RDPGFXCapabilityVersion.version107: "v10.7"
        default: nil
        }
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
