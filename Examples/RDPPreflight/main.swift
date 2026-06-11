import Foundation
import RDPKit

struct Arguments {
    var host: String?
    var port: UInt16 = 3389
    var username: String?
    var domain: String?
    var passwordEnv: String?
    var timeoutSeconds: Int = 10
    var graphicsFrames: Int = 1
    var hideCertificateWarnings = false
    var audioPlaybackEnabled = false
    var dryRun = false
    var json = false
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case missingHost
    case missingCredential(String)
    case missingPasswordEnv(String)
    case invalidPort(String)
    case invalidTimeout(String)
    case invalidGraphicsFrames(String)

    var description: String {
        switch self {
        case let .missingValue(option):
            "missing value for \(option)"
        case .missingHost:
            "missing required --host"
        case let .missingCredential(message):
            message
        case let .missingPasswordEnv(name):
            "password environment variable \(name) is not set or is empty"
        case let .invalidPort(value):
            "invalid --port \(value)"
        case let .invalidTimeout(value):
            "invalid --timeout-seconds \(value)"
        case let .invalidGraphicsFrames(value):
            "invalid --graphics-frames \(value)"
        }
    }
}

func parseArguments(_ values: [String]) throws -> Arguments {
    var args = Arguments()
    var index = 1

    while index < values.count {
        let value = values[index]
        switch value {
        case "--host":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            args.host = values[index]
        case "--port":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard let port = UInt16(values[index]) else { throw CLIError.invalidPort(values[index]) }
            args.port = port
        case "--username":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            args.username = values[index]
        case "--domain":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            args.domain = values[index]
        case "--password-env":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            args.passwordEnv = values[index]
        case "--timeout-seconds":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard let timeout = Int(values[index]), timeout > 0 else {
                throw CLIError.invalidTimeout(values[index])
            }
            args.timeoutSeconds = timeout
        case "--graphics-frames":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard let frames = Int(values[index]), frames > 0 else {
                throw CLIError.invalidGraphicsFrames(values[index])
            }
            args.graphicsFrames = frames
        case "--hide-certificate-warnings":
            args.hideCertificateWarnings = true
        case "--audio":
            args.audioPlaybackEnabled = true
        case "--dry-run":
            args.dryRun = true
        case "--json":
            args.json = true
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            throw CLIError.missingValue("unknown option \(value)")
        }
        index += 1
    }

    guard args.host != nil else { throw CLIError.missingHost }
    return args
}

func loadCredentials(from args: Arguments) throws -> RDPCredentials? {
    let hasAnyCredentialInput = args.username != nil || args.domain != nil || args.passwordEnv != nil
    guard hasAnyCredentialInput else {
        return nil
    }

    guard let username = args.username, !username.isEmpty else {
        throw CLIError.missingCredential("--username is required when credentials are provided")
    }
    guard let passwordEnv = args.passwordEnv, !passwordEnv.isEmpty else {
        throw CLIError.missingCredential("--password-env is required when credentials are provided")
    }
    guard let password = ProcessInfo.processInfo.environment[passwordEnv], !password.isEmpty else {
        throw CLIError.missingPasswordEnv(passwordEnv)
    }

    return RDPCredentials(username: username, domain: args.domain, password: password)
}

func passwordIsConfigured(in args: Arguments?) -> Bool {
    guard let passwordEnv = args?.passwordEnv else {
        return false
    }
    return ProcessInfo.processInfo.environment[passwordEnv]?.isEmpty == false
}

func printUsage() {
    print("""
    Usage: RDPPreflight --host <host> [--port 3389] [--username <name>] [--domain <domain>] [--password-env <env>] [--timeout-seconds 10] [--graphics-frames 1] [--hide-certificate-warnings] [--audio] [--dry-run] [--json]

    Sends X.224/RDP negotiation, upgrades to TLS when selected, joins MCS channels, and sends Client Info.
    Credentials are validated now and used by later authentication stages; passwords are never printed.
    """)
}

func printReport(_ report: RDPPreflightReport, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encodedReport = try encoder.encode(report)
        if let encodedText = String(data: encodedReport, encoding: .utf8) {
            print(encodedText)
        } else {
            print("{\"status\":\"failure\",\"error\":\"Report JSON was not valid UTF-8.\"}")
        }
    } else {
        print("status: \(report.status)")
        print("stage: \(report.stage)")
        print("target: \(report.target)")
        if let username = report.username {
            if let domain = report.domain {
                print("username: \(domain)\\\(username)")
            } else {
                print("username: \(username)")
            }
        }
        print("password configured: \(report.passwordConfigured)")
        print("requested protocols: \(report.requestedProtocols.joined(separator: ", "))")
        print("request: \(report.requestHex)")
        if let responseHex = report.responseHex {
            print("response: \(responseHex)")
        }
        if let negotiationFlags = report.negotiationFlags {
            print("negotiation flags: 0x\(String(format: "%02x", negotiationFlags))")
        }
        if let selected = report.selectedProtocols {
            print("selected protocols: \(selected.joined(separator: ", "))")
        }
        if let failureCode = report.failureCode {
            print("failure code: \(failureCode)")
        }
        if let tlsProtocol = report.tlsProtocol {
            print("tls protocol: \(tlsProtocol)")
        }
        if let tlsCipherSuite = report.tlsCipherSuite {
            print("tls cipher suite: \(tlsCipherSuite)")
        }
        if let certificateTrusted = report.certificateTrusted {
            print("certificate trusted: \(certificateTrusted)")
        }
        if let certificateSHA256 = report.certificateSHA256 {
            print("certificate sha256: \(certificateSHA256)")
        }
        if let mcsConnectInitialHex = report.mcsConnectInitialHex {
            print("mcs connect initial: \(mcsConnectInitialHex)")
        }
        if let mcsConnectResponseHex = report.mcsConnectResponseHex {
            print("mcs connect response: \(mcsConnectResponseHex)")
        }
        if let mcsConnectResult = report.mcsConnectResult {
            print("mcs result: \(mcsConnectResult)")
        }
        if let mcsServerUserDataKey = report.mcsServerUserDataKey {
            print("mcs server key: \(mcsServerUserDataKey)")
        }
        if let mcsIOChannelID = report.mcsIOChannelID {
            print("mcs io channel: \(mcsIOChannelID)")
        }
        if let mcsMessageChannelID = report.mcsMessageChannelID {
            print("mcs message channel: \(mcsMessageChannelID)")
        }
        if let mcsStaticChannels = report.mcsStaticChannels, !mcsStaticChannels.isEmpty {
            let channels = mcsStaticChannels
                .map { "\($0.name)=\($0.channelID)" }
                .joined(separator: ", ")
            print("mcs static channels: \(channels)")
        }
        if let mcsErectDomainRequestHex = report.mcsErectDomainRequestHex {
            print("mcs erect domain request: \(mcsErectDomainRequestHex)")
        }
        if let mcsAttachUserRequestHex = report.mcsAttachUserRequestHex {
            print("mcs attach user request: \(mcsAttachUserRequestHex)")
        }
        if let mcsAttachUserConfirmHex = report.mcsAttachUserConfirmHex {
            print("mcs attach user confirm: \(mcsAttachUserConfirmHex)")
        }
        if let mcsAttachUserResult = report.mcsAttachUserResult {
            print("mcs attach user result: \(mcsAttachUserResult)")
        }
        if let mcsUserChannelID = report.mcsUserChannelID {
            print("mcs user channel: \(mcsUserChannelID)")
        }
        if let mcsJoinedChannels = report.mcsJoinedChannels, !mcsJoinedChannels.isEmpty {
            let channels = mcsJoinedChannels
                .map { "\($0.name)=\($0.channelID):\($0.result)" }
                .joined(separator: ", ")
            print("mcs joined channels: \(channels)")
        }
        if let rdpClientInfoSent = report.rdpClientInfoSent {
            print("rdp client info sent: \(rdpClientInfoSent)")
        }
        if let rdpClientInfoCredentialsIncluded = report.rdpClientInfoCredentialsIncluded {
            print("rdp client info credentials included: \(rdpClientInfoCredentialsIncluded)")
        }
        if let rdpClientInfoRequestBytes = report.rdpClientInfoRequestBytes {
            print("rdp client info request bytes: \(rdpClientInfoRequestBytes)")
        }
        if let rdpClientInfoResponseHex = report.rdpClientInfoResponseHex {
            print("rdp client info response: \(rdpClientInfoResponseHex)")
        }
        if let rdpAutoDetectRequestType = report.rdpAutoDetectRequestType {
            print("rdp auto-detect request: \(rdpAutoDetectRequestType)")
        }
        if let rdpAutoDetectSequenceNumber = report.rdpAutoDetectSequenceNumber {
            print("rdp auto-detect sequence: \(rdpAutoDetectSequenceNumber)")
        }
        if let rdpAutoDetectResponseHex = report.rdpAutoDetectResponseHex {
            print("rdp auto-detect response: \(rdpAutoDetectResponseHex)")
        }
        if let rdpPostAutoDetectResponseHex = report.rdpPostAutoDetectResponseHex {
            print("rdp post auto-detect response: \(rdpPostAutoDetectResponseHex)")
        }
        if let rdpPostAutoDetectResponseType = report.rdpPostAutoDetectResponseType {
            print("rdp post auto-detect response type: \(rdpPostAutoDetectResponseType)")
        }
        if let rdpLicensingResponseType = report.rdpLicensingResponseType {
            print("rdp licensing response type: \(rdpLicensingResponseType)")
        }
        if let rdpLicensingErrorCode = report.rdpLicensingErrorCode {
            print("rdp licensing error code: \(rdpLicensingErrorCode)")
        }
        if let rdpPostLicensingResponseHex = report.rdpPostLicensingResponseHex {
            print("rdp post licensing response: \(rdpPostLicensingResponseHex)")
        }
        if let rdpPostLicensingResponseType = report.rdpPostLicensingResponseType {
            print("rdp post licensing response type: \(rdpPostLicensingResponseType)")
        }
        if let rdpDemandActiveShareID = report.rdpDemandActiveShareID {
            print("rdp demand active share id: \(rdpDemandActiveShareID)")
        }
        if let rdpDemandActiveCapabilitySets = report.rdpDemandActiveCapabilitySets {
            print("rdp demand active capabilities: \(capabilityList(rdpDemandActiveCapabilitySets))")
        }
        if let rdpConfirmActiveRequestHex = report.rdpConfirmActiveRequestHex {
            print("rdp confirm active request: \(rdpConfirmActiveRequestHex)")
        }
        if let rdpConfirmActiveCapabilitySets = report.rdpConfirmActiveCapabilitySets {
            print("rdp confirm active capabilities: \(capabilityList(rdpConfirmActiveCapabilitySets))")
        }
        if let rdpPostConfirmActiveResponseHex = report.rdpPostConfirmActiveResponseHex {
            print("rdp post confirm active response: \(rdpPostConfirmActiveResponseHex)")
        }
        if let rdpPostConfirmActiveResponseType = report.rdpPostConfirmActiveResponseType {
            print("rdp post confirm active response type: \(rdpPostConfirmActiveResponseType)")
        }
        if let rdpClientSynchronizeRequestHex = report.rdpClientSynchronizeRequestHex {
            print("rdp client synchronize request: \(rdpClientSynchronizeRequestHex)")
        }
        if let rdpClientControlCooperateRequestHex = report.rdpClientControlCooperateRequestHex {
            print("rdp client control cooperate request: \(rdpClientControlCooperateRequestHex)")
        }
        if let rdpClientControlRequestHex = report.rdpClientControlRequestHex {
            print("rdp client control request: \(rdpClientControlRequestHex)")
        }
        if let rdpClientFontListRequestHex = report.rdpClientFontListRequestHex {
            print("rdp client font list request: \(rdpClientFontListRequestHex)")
        }
        if let rdpFinalizationResponseTypes = report.rdpFinalizationResponseTypes,
           !rdpFinalizationResponseTypes.isEmpty
        {
            print("rdp finalization response types: \(rdpFinalizationResponseTypes.joined(separator: ", "))")
        }
        if let rdpFinalizationResponseHexes = report.rdpFinalizationResponseHexes {
            for (index, responseHex) in rdpFinalizationResponseHexes.enumerated() {
                print("rdp finalization response \(index + 1): \(responseHex)")
            }
        }
        if let rdpDynamicChannelRequestTypes = report.rdpDynamicChannelRequestTypes,
           !rdpDynamicChannelRequestTypes.isEmpty
        {
            print("rdp dynamic channel requests: \(rdpDynamicChannelRequestTypes.joined(separator: ", "))")
        }
        if let rdpDynamicChannelCapabilitiesVersion = report.rdpDynamicChannelCapabilitiesVersion {
            print("rdp dynamic channel capabilities version: \(rdpDynamicChannelCapabilitiesVersion)")
        }
        if let rdpDynamicChannelCapabilitiesResponseHex = report.rdpDynamicChannelCapabilitiesResponseHex {
            print("rdp dynamic channel capabilities response: \(rdpDynamicChannelCapabilitiesResponseHex)")
        }
        if let rdpGraphicsChannelName = report.rdpGraphicsChannelName {
            print("rdp graphics channel name: \(rdpGraphicsChannelName)")
        }
        if let rdpGraphicsChannelID = report.rdpGraphicsChannelID {
            print("rdp graphics channel id: \(rdpGraphicsChannelID)")
        }
        if let rdpGraphicsChannelCreateResponseHex = report.rdpGraphicsChannelCreateResponseHex {
            print("rdp graphics channel create response: \(rdpGraphicsChannelCreateResponseHex)")
        }
        if let rdpDisplayControlChannelID = report.rdpDisplayControlChannelID {
            print("rdp display control channel id: \(rdpDisplayControlChannelID)")
        }
        if let rdpDisplayControlChannelCreateResponseHex = report.rdpDisplayControlChannelCreateResponseHex {
            print("rdp display control channel create response: \(rdpDisplayControlChannelCreateResponseHex)")
        }
        if let rdpGraphicsCapsAdvertiseHex = report.rdpGraphicsCapsAdvertiseHex {
            print("rdp graphics caps advertise: \(rdpGraphicsCapsAdvertiseHex)")
        }
        if let rdpDisplayControlCaps = report.rdpDisplayControlCaps {
            let capsSummary = "max-monitors=\(rdpDisplayControlCaps.maxNumMonitors), "
                + "area=\(rdpDisplayControlCaps.maxMonitorAreaFactorA)x\(rdpDisplayControlCaps.maxMonitorAreaFactorB)"
            print("rdp display control caps: \(capsSummary)")
        }
        if let rdpDisplayControlCapsHex = report.rdpDisplayControlCapsHex {
            print("rdp display control caps: \(rdpDisplayControlCapsHex)")
        }
        if let rdpClipboardChannelID = report.rdpClipboardChannelID {
            print("rdp clipboard channel id: \(rdpClipboardChannelID)")
        }
        if let rdpClipboardMessages = report.rdpClipboardMessages, !rdpClipboardMessages.isEmpty {
            let messages = rdpClipboardMessages
                .map { "\($0.typeName):flags=0x\(String(format: "%04x", $0.messageFlags)):bytes=\($0.dataLength)" }
                .joined(separator: ", ")
            print("rdp clipboard messages: \(messages)")
        }
        if let rdpClipboardMessageHexes = report.rdpClipboardMessageHexes {
            for (index, messageHex) in rdpClipboardMessageHexes.enumerated() {
                print("rdp clipboard message \(index + 1): \(messageHex)")
            }
        }
        if let rdpAudioChannelID = report.rdpAudioChannelID {
            print("rdp audio channel id: \(rdpAudioChannelID)")
        }
        if let rdpAudioMessages = report.rdpAudioMessages, !rdpAudioMessages.isEmpty {
            let messages = rdpAudioMessages
                .map { "\($0.typeName):bytes=\($0.bodySize)" }
                .joined(separator: ", ")
            print("rdp audio messages: \(messages)")
        }
        if let rdpAudioMessageHexes = report.rdpAudioMessageHexes {
            for (index, messageHex) in rdpAudioMessageHexes.enumerated() {
                print("rdp audio message \(index + 1): \(messageHex)")
            }
        }
        if let rdpGraphicsResponseHex = report.rdpGraphicsResponseHex {
            print("rdp graphics response: \(rdpGraphicsResponseHex)")
        }
        if let rdpGraphicsResponseType = report.rdpGraphicsResponseType {
            print("rdp graphics response type: \(rdpGraphicsResponseType)")
        }
        if let rdpGraphicsSelectedCapabilityVersion = report.rdpGraphicsSelectedCapabilityVersion {
            print("rdp graphics selected capability version: 0x\(String(format: "%08x", rdpGraphicsSelectedCapabilityVersion))")
        }
        if let rdpGraphicsSelectedCapabilityFlags = report.rdpGraphicsSelectedCapabilityFlags {
            print("rdp graphics selected capability flags: 0x\(String(format: "%08x", rdpGraphicsSelectedCapabilityFlags))")
        }
        if let rdpGraphicsUpdateMessages = report.rdpGraphicsUpdateMessages,
           !rdpGraphicsUpdateMessages.isEmpty
        {
            print("rdp graphics update messages: \(graphicsUpdateList(rdpGraphicsUpdateMessages))")
        }
        if let rdpGraphicsUpdateResponseCount = report.rdpGraphicsUpdateResponseCount {
            print("rdp graphics update response count: \(rdpGraphicsUpdateResponseCount)")
        }
        if let rdpGraphicsFrameAcknowledgeHexes = report.rdpGraphicsFrameAcknowledgeHexes {
            for (index, acknowledgeHex) in rdpGraphicsFrameAcknowledgeHexes.enumerated() {
                print("rdp graphics frame acknowledge \(index + 1): \(acknowledgeHex)")
            }
        }
        if let rdpGraphicsFirstFrame = report.rdpGraphicsFirstFrame {
            print("rdp graphics first frame: \(graphicsFrameSummary(rdpGraphicsFirstFrame))")
        }
        if let rdpGraphicsFrames = report.rdpGraphicsFrames,
           rdpGraphicsFrames.count > 1
        {
            for (index, frame) in rdpGraphicsFrames.enumerated() {
                print("rdp graphics frame \(index + 1): \(graphicsFrameSummary(frame))")
            }
        }
        if let rdpGraphicsUpdateResponseHexes = report.rdpGraphicsUpdateResponseHexes {
            for (index, responseHex) in rdpGraphicsUpdateResponseHexes.enumerated() {
                print("rdp graphics update response \(index + 1): \(responseHex)")
            }
        }
        if let rdpDynamicChannelRequestHexes = report.rdpDynamicChannelRequestHexes {
            for (index, requestHex) in rdpDynamicChannelRequestHexes.enumerated() {
                print("rdp dynamic channel request \(index + 1): \(requestHex)")
            }
        }
        for warning in report.warnings {
            print("warning[\(warning.code)]: \(warning.message)")
        }
        if let nextStage = report.nextStage {
            print("next stage: \(nextStage)")
        }
        if let error = report.error {
            print("error: \(error)")
        }
    }
}

func capabilityList(_ capabilities: [RDPCapabilitySetSummary]) -> String {
    capabilities
        .map { "\($0.name)=0x\(String(format: "%04x", $0.type)):\($0.length)" }
        .joined(separator: ", ")
}

func graphicsUpdateList(_ messages: [RDPGFXMessageSummary]) -> String {
    messages
        .map { message in
            var parts = [message.typeName]
            if let surfaceID = message.surfaceID {
                parts.append("surface=\(surfaceID)")
            }
            if let width = message.width, let height = message.height {
                parts.append("size=\(width)x\(height)")
            }
            if let frameID = message.frameID {
                parts.append("frame=\(frameID)")
            }
            if let codecName = message.codecName {
                parts.append("codec=\(codecName)")
            }
            if let bitmapDataLength = message.bitmapDataLength {
                parts.append("bytes=\(bitmapDataLength)")
            }
            if let avc444Layout = message.avc444Layout {
                parts.append("avc444=\(avc444Layout)")
            }
            if let avc444YUV420EncodedBitstreamLength = message.avc444YUV420EncodedBitstreamLength {
                parts.append("avc444-yuv420-bytes=\(avc444YUV420EncodedBitstreamLength)")
            }
            if let avc444Chroma420EncodedBitstreamLength = message.avc444Chroma420EncodedBitstreamLength {
                parts.append("avc444-chroma420-bytes=\(avc444Chroma420EncodedBitstreamLength)")
            }
            return parts.joined(separator: ":")
        }
        .joined(separator: ", ")
}

func graphicsFrameSummary(_ frame: RDPGraphicsFrameSnapshot) -> String {
    var parts = [
        "surface=\(frame.surfaceID)",
        "codec=\(frame.codecName)",
        "video=\(frame.videoCodec.displayName)",
        "size=\(frame.width)x\(frame.height)",
        "video-bytes=\(frame.videoByteCount)",
        "regions=\(frame.regionRects.count)",
    ]
    if let frameID = frame.frameID {
        parts.append("frame=\(frameID)")
    }
    if !frame.videoNalUnitTypes.isEmpty {
        parts.append("nal-types=\(frame.videoNalUnitTypes.map(String.init).joined(separator: "/"))")
    }
    return parts.joined(separator: ":")
}

func failureReport(args: Arguments?, error: Error) -> RDPPreflightReport {
    let host = args?.host ?? "unconfigured"
    let port = args?.port ?? 3389
    let passwordConfigured = passwordIsConfigured(in: args)
    let credentials = args?.username.map {
        RDPCredentials(
            username: $0,
            domain: args?.domain,
            password: ""
        )
    }
    let configuration = RDPConnectionConfiguration(
        host: host,
        port: port,
        credentials: credentials
    )
    var report = RDPPreflightClient().dryRun(configuration: configuration)
    report.status = "failure"
    report.stage = "x224-rdp-negotiation"
    report.passwordConfigured = passwordConfigured
    report.nextStage = nil
    report.error = String(describing: error)
    return report
}

do {
    let args = try parseArguments(CommandLine.arguments)
    guard let host = args.host else {
        printUsage()
        Foundation.exit(2)
    }
    let credentials = try loadCredentials(from: args)
    let configuration = RDPConnectionConfiguration(
        host: host,
        port: args.port,
        credentials: credentials,
        timeoutSeconds: args.timeoutSeconds,
        hideCertificateWarnings: args.hideCertificateWarnings,
        graphicsFrameCaptureLimit: args.graphicsFrames,
        audioPlaybackEnabled: args.audioPlaybackEnabled
    )
    let client = RDPPreflightClient()
    let report = args.dryRun
        ? client.dryRun(configuration: configuration)
        : client.run(configuration: configuration)

    try printReport(report, json: args.json)
    if report.status == "failure" {
        exit(1)
    }
} catch {
    let parsedArgs = try? parseArguments(CommandLine.arguments)
    let report = failureReport(args: parsedArgs, error: error)
    let json = CommandLine.arguments.contains("--json")
    try? printReport(report, json: json)
    if !json {
        printUsage()
    }
    exit(1)
}
