import Foundation

/// Text for a diagnostics view, such as RDPClient's Stats for Nerds window: metric units, pixel
/// formats, and summaries of what a connection report holds. A value that is not there reads
/// "none", unless a function says otherwise. The view's layout stays the app's.
public enum RDPDiagnosticText {
    // MARK: Units

    /// Milliseconds, with two decimals below 1 ms and one above.
    public static func milliseconds(_ value: Double?) -> String {
        guard let value else {
            return "none"
        }
        return String(format: value < 1 ? "%.2f ms" : "%.1f ms", value)
    }

    /// The last and average of a timing in milliseconds.
    public static func timing(last: Double?, average: Double?) -> String {
        "last \(milliseconds(last)), avg \(milliseconds(average))"
    }

    /// A refresh interval in seconds, such as a display link's, in milliseconds.
    public static func refreshInterval(_ seconds: TimeInterval?) -> String {
        milliseconds(seconds.map { $0 * 1000 })
    }

    public static func framesPerSecond(_ value: Double?) -> String {
        guard let value else {
            return "none"
        }
        return String(format: "%.1f fps", value)
    }

    /// A refresh rate, without decimals when it is whole.
    public static func hertz(_ value: Double?) -> String {
        guard let value else {
            return "none"
        }
        return String(format: value.rounded() == value ? "%.0f Hz" : "%.1f Hz", value)
    }

    /// Megabits per second, with two decimals below 1 and one above.
    public static func megabitsPerSecond(_ value: Double?) -> String {
        guard let value else {
            return "none"
        }
        return String(format: value < 1 ? "%.2f Mbps" : "%.1f Mbps", value)
    }

    /// A byte count in the units a file size shows in, such as "1.2 MB".
    public static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    /// An exact byte count, such as "120 bytes".
    public static func byteCount(_ value: Int?) -> String {
        value.map { "\($0) bytes" } ?? "none"
    }

    /// "yes" or "no", and `missing` for nil.
    public static func yesNo(_ value: Bool?, missing: String = "none") -> String {
        value.map { $0 ? "yes" : "no" } ?? missing
    }

    /// A number as it is.
    public static func number(_ value: (some BinaryInteger)?) -> String {
        value.map { "\($0)" } ?? "none"
    }

    /// A 32-bit code, such as an error code or share ID, as eight hex digits.
    public static func hex(_ value: UInt32?) -> String {
        value.map { String(format: "0x%08x", $0) } ?? "none"
    }

    /// A Core Video pixel format: its four characters and hex code, such as
    /// "420v (0x34323076)", or the code alone when they are not printable; "unknown" for nil.
    public static func pixelFormat(_ value: UInt32?) -> String {
        guard let value else {
            return "unknown"
        }
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        let code = hex(value)
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
              let fourCC = String(bytes: bytes, encoding: .ascii)
        else {
            return code
        }
        return "\(fourCC) (\(code))"
    }

    // MARK: Session

    /// The parts of a one-line performance summary, for the app to join: frames per second,
    /// the last decode, the wire rate and the display link's rate. The rates are those of the
    /// 5 s up to `date`, so they fall once traffic stops; frames per second falls back on the
    /// session's average before there is a rolling rate.
    public static func viewerMetrics(
        _ metrics: RDPRenderMetrics,
        displayLinkFramesPerSecond: Double?,
        at date: Date
    ) -> [String] {
        var parts: [String] = []
        if let rate = metrics.rollingFramesPerSecond(at: date) ?? metrics.averageFramesPerSecond {
            parts.append(framesPerSecond(rate))
        }
        if let decode = metrics.lastDecodeMilliseconds {
            parts.append("decode \(milliseconds(decode))")
        }
        if let wire = metrics.rollingWireMegabitsPerSecond(at: date) {
            parts.append("rx \(megabitsPerSecond(wire))")
        }
        if let displayLinkFramesPerSecond {
            parts.append(hertz(displayLinkFramesPerSecond))
        }
        return parts
    }

    /// Where the session went: after a Server Redirection, the server the one typed in passed
    /// it on to.
    public static func connectionTarget(of report: RDPConnectionReport) -> String {
        switch report.redirectionDepth {
        case 0:
            report.target
        case 1:
            "\(report.target), after a server redirection"
        default:
            "\(report.target), after \(report.redirectionDepth) server redirections"
        }
    }

    /// How the server ended the session, when it said: the Set Error Info code's name, the
    /// Disconnect Provider Ultimatum reason, and RDPKit's category for them.
    public static func remoteTermination(_ termination: RDPRemoteTermination?) -> String {
        guard let termination else {
            return "none"
        }
        let names = [termination.errorInfoName, termination.disconnectReasonName].compactMap { $0 }
        return "\(names.joined(separator: ", ")) (\(termination.category.rawValue))"
    }

    /// Each warning's code and message, one per line.
    public static func warnings(_ warnings: [RDPConnectionWarning]?) -> String {
        guard let warnings, !warnings.isEmpty else {
            return "none"
        }
        return warnings.map { "\($0.code): \($0.message)" }.joined(separator: "\n")
    }

    // MARK: Negotiation

    /// Each channel's name and ID, such as "rdpdr=1004, cliprdr=1005".
    public static func channels(_ channels: [RDPStaticVirtualChannelAssignment]?) -> String {
        list(channels?.map { "\($0.name)=\($0.channelID)" }, missing: "none")
    }

    /// Each joined channel's name and ID.
    public static func channels(_ channels: [RDPChannelJoinReport]?) -> String {
        list(channels?.map { "\($0.name)=\($0.channelID)" }, missing: "none")
    }

    /// The capability sets' names.
    public static func capabilitySets(_ capabilities: [RDPCapabilitySetSummary]?) -> String {
        list(capabilities?.map(\.name), missing: "none")
    }

    /// Items joined with commas, or `missing` when there are none, such as the finalization
    /// PDUs the server answered with.
    public static func list(_ items: [String]?, missing: String = "not attempted") -> String {
        guard let items, !items.isEmpty else {
            return missing
        }
        return items.joined(separator: ", ")
    }

    /// The first `limit` message types, such as a clipboard or audio channel's
    /// `typeName`s; "not observed" without any.
    public static func messageTypes(_ typeNames: [String]?, limit: Int = 4) -> String {
        list(typeNames.map { Array($0.prefix(limit)) }, missing: "not observed")
    }

    /// The RDPGFX capability the server selected, as its version and flags in hex.
    public static func graphicsCapability(of report: RDPConnectionReport?) -> String {
        guard let version = report?.rdpGraphicsSelectedCapabilityVersion else {
            return "none"
        }
        let flags = report?.rdpGraphicsSelectedCapabilityFlags.map { " flags=\(hex($0))" } ?? ""
        return "\(hex(version))\(flags)"
    }

    /// The Display Control capabilities: how many monitors, and the area they may cover.
    public static func displayControlCapabilities(_ capabilities: RDPDisplayControlCapabilities?) -> String {
        guard let capabilities else {
            return "none"
        }
        return "max monitors \(capabilities.maxNumMonitors), "
            + "area \(capabilities.maxMonitorAreaFactorA)x\(capabilities.maxMonitorAreaFactorB)"
    }

    // MARK: Graphics

    /// The first `limit` RDPGFX PDUs, each as its type, surface, size, frame, codec, tiles and
    /// AVC444 layout where it has them; "not observed" without any.
    public static func graphicsUpdates(_ messages: [RDPGFXMessageSummary]?, limit: Int = 4) -> String {
        list(messages.map { $0.prefix(limit).map(graphicsUpdate) }, missing: "not observed")
    }

    /// Which PDU of the first failing graphics update failed, and of how many, then its first
    /// few PDUs as `graphicsUpdates(_:limit:)` gives them: those around the failing one, which
    /// in an update of more than 64 do not start at its first. "transport" for an update that
    /// did not decode into PDUs.
    public static func graphicsFailure(of report: RDPConnectionReport?) -> String {
        guard let report,
              report.rdpGraphicsFailureUpdatePayloadHex != nil
              || report.rdpGraphicsFailureUpdateResponseHex != nil
        else {
            return "none"
        }
        var index = report.rdpGraphicsFailureUpdateMessageIndex.map { "message \($0)" } ?? "transport"
        if let messageCount = report.rdpGraphicsFailureUpdateMessageCount {
            index += " of \(messageCount)"
        }
        if let firstIndex = report.rdpGraphicsFailureUpdateFirstMessageIndex {
            index += ", summaries from \(firstIndex)"
        }
        guard let messages = report.rdpGraphicsFailureUpdateMessages, !messages.isEmpty else {
            return index
        }
        return "\(index): \(graphicsUpdates(messages))"
    }

    /// A frame's codec, size, payload, regions and H.264 NAL unit types.
    public static func frame(_ frame: RDPFrameMetadata?) -> String {
        guard let frame else {
            return "none"
        }
        let codec = frame.contentKind == .video ? "\(frame.codecName)/\(frame.videoCodec.displayName)" : frame.codecName
        var parts = [
            codec,
            "\(frame.width)x\(frame.height)",
            "\(frame.payloadByteCount) bytes",
            "\(frame.regionCount) regions",
        ]
        if !frame.videoNalUnitTypes.isEmpty {
            parts.append("nal \(frame.videoNalUnitTypes.map(String.init).joined(separator: "/"))")
        }
        return parts.joined(separator: ", ")
    }

    private static func graphicsUpdate(_ message: RDPGFXMessageSummary) -> String {
        var parts = [message.typeName]
        if let surfaceID = message.surfaceID {
            parts.append("s\(surfaceID)")
        }
        if let width = message.width, let height = message.height {
            parts.append("\(width)x\(height)")
        }
        if let frameID = message.frameID {
            parts.append("f\(frameID)")
        }
        if let codecName = message.codecName {
            parts.append(codecName)
        }
        if let tileCount = message.progressiveRegionTileCount {
            parts.append("tiles \(tileCount)")
        }
        if let firstCount = message.progressiveTileFirstCount, firstCount > 0 {
            parts.append("first \(firstCount)")
        }
        if let upgradeCount = message.progressiveTileUpgradeCount, upgradeCount > 0 {
            parts.append("upgrade \(upgradeCount)")
        }
        if let tileCount = message.cavideoTileCount {
            parts.append("rfx tiles \(tileCount)")
        }
        if let entropy = message.cavideoTileSetEntropyAlgorithms?.last {
            parts.append(entropy)
        }
        if let layout = message.avc444Layout {
            parts.append(layout)
        }
        return parts.joined(separator: " ")
    }
}
