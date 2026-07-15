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
    var desktopWidth: UInt16 = 1280
    var desktopHeight: UInt16 = 720
    var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile = .automatic
    var hideCertificateWarnings = false
    var audioPlaybackEnabled = false
    var earlyUserAuthorizationEnabled = false
    var probeClipboardText: String?
    var probeWindowsClipboardText: String?
    var probeWindowsPasteClipboard = false
    var probeInputText: String?
    var probeInputPointer = false
    var probeWindowsKey = false
    var probeWindowsAudio = false
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
    case invalidDesktopWidth(String)
    case invalidDesktopHeight(String)
    case invalidGraphicsProfile(String)
    case invalidProbeClipboardText
    case invalidProbeWindowsClipboardText

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
        case let .invalidDesktopWidth(value):
            "invalid --desktop-width \(value); expected 640...8192"
        case let .invalidDesktopHeight(value):
            "invalid --desktop-height \(value); expected 480...8192"
        case let .invalidGraphicsProfile(value):
            "invalid --graphics-profile \(value)"
        case .invalidProbeClipboardText:
            "--probe-clipboard-text exceeds the CLIPRDR single-message text limit"
        case .invalidProbeWindowsClipboardText:
            "--probe-windows-clipboard-text must be non-empty ASCII text up to 96 code units"
        }
    }
}

final class PreflightProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let windowsClipboardProbeText: String?
    private var clipboardProbeTextUTF16CodeUnitCount: Int?
    private var clipboardReceivedTextUTF16CodeUnitCount: Int?
    private var clipboardReceivedTextMatchesProbe: Bool?
    private var inputProbeEvents: [String] = []
    private var inputSession: RDPInputSession?
    private var inputProbeSent = false

    init(windowsClipboardProbeText: String?) {
        self.windowsClipboardProbeText = windowsClipboardProbeText
    }

    func publishClipboardText(_ text: String, on session: RDPClipboardSession) {
        session.publishLocalUnicodeText(text)

        lock.lock()
        clipboardProbeTextUTF16CodeUnitCount = text.utf16.count
        lock.unlock()
    }

    func recordClipboardText(_ text: String) {
        lock.lock()
        clipboardReceivedTextUTF16CodeUnitCount = text.utf16.count
        if let windowsClipboardProbeText {
            clipboardReceivedTextMatchesProbe = text == windowsClipboardProbeText
        }
        lock.unlock()
    }

    func recordInputSession(_ session: RDPInputSession) {
        lock.lock()
        inputSession = session
        lock.unlock()
    }

    func sendInputProbeAfterFirstFrame(
        text: String?,
        movePointerToCenter: Bool,
        toggleWindowsStart: Bool,
        pasteClipboardOnWindows: Bool,
        windowsClipboardText: String?,
        triggerWindowsAudio: Bool
    ) {
        let session: RDPInputSession
        lock.lock()
        guard inputProbeSent == false, let recordedSession = inputSession else {
            lock.unlock()
            return
        }
        inputProbeSent = true
        session = recordedSession
        lock.unlock()

        var events: [RDPSlowPathInputEvent] = []
        var eventNames: [String] = []

        if movePointerToCenter {
            events.append(.pointerMove(x: 640, y: 360))
            eventNames.append("pointer-move:640x360")
        }

        if let text, text.isEmpty == false {
            for codeUnit in text.utf16 {
                events.append(.unicode(codeUnit: codeUnit, isReleased: false))
                events.append(.unicode(codeUnit: codeUnit, isReleased: true))
            }
            eventNames.append("unicode-text:\(text.utf16.count)-code-units")
        }

        if events.isEmpty == false {
            session.send(events)
        }

        if toggleWindowsStart {
            sendWindowsKeyTimingProbe(on: session)
            eventNames.append("windows-key:initial")
            eventNames.append("windows-key:after-500ms")
            eventNames.append("windows-key:after-2000ms")
        }

        if pasteClipboardOnWindows {
            sendWindowsClipboardPasteProbe(on: session)
            eventNames.append("windows-clipboard-paste")
            Thread.sleep(forTimeInterval: 0.8)
        }
        if let windowsClipboardText {
            sendWindowsRunCommand(windowsClipboardCommand(for: windowsClipboardText), on: session)
            eventNames.append("windows-clipboard-command:\(windowsClipboardText.utf16.count)-code-units")
            Thread.sleep(forTimeInterval: 0.8)
        }
        if triggerWindowsAudio {
            sendWindowsRunPowerShellCommand(
                "$p=New-Object System.Media.SoundPlayer 'C:\\Windows\\Media\\Windows Notify.wav';1..6|%{$p.PlaySync()}",
                on: session
            )
            eventNames.append("windows-audio-command")
        }

        guard eventNames.isEmpty == false else {
            return
        }

        lock.lock()
        inputProbeEvents.append(contentsOf: eventNames)
        lock.unlock()
    }

    private func sendWindowsKeyTimingProbe(on session: RDPInputSession) {
        let leftWindows = RDPKeyboardScancode(code: 0x005B, isExtended: true)
        session.send(keyStroke(leftWindows))
        Thread.sleep(forTimeInterval: 0.5)
        session.send(keyStroke(leftWindows))
        Thread.sleep(forTimeInterval: 2.0)
        session.send(keyStroke(leftWindows))
    }

    private func sendWindowsClipboardPasteProbe(on session: RDPInputSession) {
        let escape = RDPKeyboardScancode(code: 0x0001)
        let leftWindows = RDPKeyboardScancode(code: 0x005B, isExtended: true)
        let rKey = RDPKeyboardScancode(code: 0x0013)
        let leftControl = RDPKeyboardScancode(code: 0x001D)
        let aKey = RDPKeyboardScancode(code: 0x001E)
        let vKey = RDPKeyboardScancode(code: 0x002F)
        let backspace = RDPKeyboardScancode(code: 0x000E)

        session.send(keyStroke(escape))
        Thread.sleep(forTimeInterval: 0.2)
        session.send(keyChord(modifier: leftWindows, key: rKey))
        Thread.sleep(forTimeInterval: 1.25)
        session.send(keyChord(modifier: leftControl, key: aKey))
        session.send(keyStroke(backspace))
        Thread.sleep(forTimeInterval: 0.2)
        session.send(keyChord(modifier: leftControl, key: vKey))
        Thread.sleep(forTimeInterval: 0.5)
        session.send(keyStroke(escape))
    }

    private func sendWindowsRunPowerShellCommand(_ command: String, on session: RDPInputSession) {
        sendWindowsRunCommand("powershell -NoProfile -Command \"\(command)\"", on: session)
    }

    private func sendWindowsRunCommand(_ command: String, on session: RDPInputSession) {
        let escape = RDPKeyboardScancode(code: 0x0001)
        let leftWindows = RDPKeyboardScancode(code: 0x005B, isExtended: true)
        let rKey = RDPKeyboardScancode(code: 0x0013)
        let leftControl = RDPKeyboardScancode(code: 0x001D)
        let aKey = RDPKeyboardScancode(code: 0x001E)
        let backspace = RDPKeyboardScancode(code: 0x000E)
        let enter = RDPKeyboardScancode(code: 0x001C)

        session.send(keyStroke(escape))
        Thread.sleep(forTimeInterval: 0.2)
        session.send(keyChord(modifier: leftWindows, key: rKey))
        Thread.sleep(forTimeInterval: 1.25)
        session.send(keyChord(modifier: leftControl, key: aKey))
        session.send(keyStroke(backspace))
        Thread.sleep(forTimeInterval: 0.2)
        session.send(unicodeInputEvents(for: command))
        Thread.sleep(forTimeInterval: 0.2)
        session.send(keyStroke(enter))
    }

    private func keyStroke(_ scancode: RDPKeyboardScancode) -> [RDPSlowPathInputEvent] {
        [
            .keyboard(scancode: scancode, isReleased: false),
            .keyboard(scancode: scancode, isReleased: true),
        ]
    }

    private func keyChord(
        modifier: RDPKeyboardScancode,
        key: RDPKeyboardScancode
    ) -> [RDPSlowPathInputEvent] {
        [
            .keyboard(scancode: modifier, isReleased: false),
            .keyboard(scancode: key, isReleased: false),
            .keyboard(scancode: key, isReleased: true),
            .keyboard(scancode: modifier, isReleased: true),
        ]
    }

    private func unicodeInputEvents(for text: String) -> [RDPSlowPathInputEvent] {
        text.utf16.flatMap { codeUnit in
            [
                RDPSlowPathInputEvent.unicode(codeUnit: codeUnit, isReleased: false),
                RDPSlowPathInputEvent.unicode(codeUnit: codeUnit, isReleased: true),
            ]
        }
    }

    private func windowsClipboardCommand(for text: String) -> String {
        "cmd /c <nul set /p \"=\(text)\"|clip"
    }

    func apply(to report: inout RDPPreflightReport) {
        lock.lock()
        let clipboardProbeTextUTF16CodeUnitCount = clipboardProbeTextUTF16CodeUnitCount
        let clipboardReceivedTextUTF16CodeUnitCount = clipboardReceivedTextUTF16CodeUnitCount
        let clipboardReceivedTextMatchesProbe = clipboardReceivedTextMatchesProbe
        let inputProbeEvents = inputProbeEvents
        lock.unlock()

        report.rdpClipboardProbeTextUTF16CodeUnitCount = clipboardProbeTextUTF16CodeUnitCount
        report.rdpClipboardReceivedTextUTF16CodeUnitCount = clipboardReceivedTextUTF16CodeUnitCount
        report.rdpClipboardReceivedTextMatchesProbe = clipboardReceivedTextMatchesProbe
        report.rdpInputProbeEvents = inputProbeEvents.isEmpty ? nil : inputProbeEvents
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
        case "--desktop-width":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard let width = UInt16(values[index]), (640 ... 8192).contains(width) else {
                throw CLIError.invalidDesktopWidth(values[index])
            }
            args.desktopWidth = width
        case "--desktop-height":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard let height = UInt16(values[index]), (480 ... 8192).contains(height) else {
                throw CLIError.invalidDesktopHeight(values[index])
            }
            args.desktopHeight = height
        case "--graphics-profile":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard let profile = RDPGraphicsCapabilityProfile(rawValue: values[index]) else {
                throw CLIError.invalidGraphicsProfile(values[index])
            }
            args.graphicsCapabilityProfile = profile
        case "--hide-certificate-warnings":
            args.hideCertificateWarnings = true
        case "--early-user-authorization":
            args.earlyUserAuthorizationEnabled = true
        case "--audio":
            args.audioPlaybackEnabled = true
        case "--probe-clipboard-text":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard RDPClipboardLimits.canPublishUnicodeText(values[index]) else {
                throw CLIError.invalidProbeClipboardText
            }
            args.probeClipboardText = values[index]
        case "--probe-windows-clipboard-text":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            guard isValidWindowsClipboardProbeText(values[index]) else {
                throw CLIError.invalidProbeWindowsClipboardText
            }
            args.probeWindowsClipboardText = values[index]
        case "--probe-windows-paste-clipboard":
            args.probeWindowsPasteClipboard = true
        case "--probe-input-text":
            index += 1
            guard index < values.count else { throw CLIError.missingValue(value) }
            args.probeInputText = values[index]
        case "--probe-input-pointer":
            args.probeInputPointer = true
        case "--probe-windows-key":
            args.probeWindowsKey = true
        case "--probe-windows-audio":
            args.audioPlaybackEnabled = true
            args.probeWindowsAudio = true
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

func isValidWindowsClipboardProbeText(_ text: String) -> Bool {
    let allowedPunctuation = " -_:."
    return text.isEmpty == false
        && text.count <= 96
        && text.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || allowedPunctuation.contains(character))
        }
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
    Usage: RDPPreflight --host <host> [--port 3389] [--username <name>] [--domain <domain>] [--password-env <env>] [--timeout-seconds 10] [--graphics-frames 1] [--desktop-width 1280] [--desktop-height 720] [--graphics-profile automatic|avcThinClient|avc420|legacy] [--hide-certificate-warnings] [--early-user-authorization] [--audio] [--probe-clipboard-text <text>] [--probe-windows-key] [--probe-windows-paste-clipboard] [--probe-windows-clipboard-text <text>] [--probe-input-text <text>] [--probe-input-pointer] [--probe-windows-audio] [--dry-run] [--json]

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
        if let errorInfoName = report.rdpRemoteTerminationErrorInfoName {
            print("rdp remote termination error info: \(errorInfoName)")
        }
        if let disconnectReasonName = report.rdpRemoteTerminationDisconnectReasonName {
            print("rdp remote termination disconnect reason: \(disconnectReasonName)")
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
        if let rdpClipboardSentMessages = report.rdpClipboardSentMessages, !rdpClipboardSentMessages.isEmpty {
            let messages = rdpClipboardSentMessages
                .map { "\($0.typeName):flags=0x\(String(format: "%04x", $0.messageFlags)):bytes=\($0.dataLength)" }
                .joined(separator: ", ")
            print("rdp clipboard sent messages: \(messages)")
        }
        if let rdpClipboardMessageHexes = report.rdpClipboardMessageHexes {
            for (index, messageHex) in rdpClipboardMessageHexes.enumerated() {
                print("rdp clipboard message \(index + 1): \(messageHex)")
            }
        }
        if let rdpClipboardSentMessageHexes = report.rdpClipboardSentMessageHexes {
            for (index, messageHex) in rdpClipboardSentMessageHexes.enumerated() {
                print("rdp clipboard sent message \(index + 1): \(messageHex)")
            }
        }
        if let rdpClipboardProbeTextUTF16CodeUnitCount = report.rdpClipboardProbeTextUTF16CodeUnitCount {
            print("rdp clipboard probe text code units: \(rdpClipboardProbeTextUTF16CodeUnitCount)")
        }
        if let rdpClipboardReceivedTextUTF16CodeUnitCount = report.rdpClipboardReceivedTextUTF16CodeUnitCount {
            print("rdp clipboard received text code units: \(rdpClipboardReceivedTextUTF16CodeUnitCount)")
        }
        if let rdpClipboardReceivedTextMatchesProbe = report.rdpClipboardReceivedTextMatchesProbe {
            print("rdp clipboard received text matches probe: \(rdpClipboardReceivedTextMatchesProbe)")
        }
        if let rdpInputProbeEvents = report.rdpInputProbeEvents, !rdpInputProbeEvents.isEmpty {
            print("rdp input probe events: \(rdpInputProbeEvents.joined(separator: ", "))")
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
        print("rdp graphics requested capability profile: \(report.rdpGraphicsCapabilityProfile.rawValue)")
        print("rdp graphics path: \(RDPGraphicsPathDescription.describe(report: report))")
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
        if let failureIndex = report.rdpGraphicsFailureUpdateMessageIndex {
            print("rdp graphics failure update message index: \(failureIndex)")
        }
        if let failureMessages = report.rdpGraphicsFailureUpdateMessages,
           !failureMessages.isEmpty
        {
            print("rdp graphics failure update messages: \(graphicsUpdateList(failureMessages))")
        }
        if let failurePayloadHex = report.rdpGraphicsFailureUpdatePayloadHex {
            print("rdp graphics failure update payload: \(failurePayloadHex)")
        }
        if let failureResponseHex = report.rdpGraphicsFailureUpdateResponseHex {
            print("rdp graphics failure update response: \(failureResponseHex)")
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
            if let codecContextID = message.codecContextID {
                parts.append("ctx=\(codecContextID)")
            }
            if let progressiveBlockTypeNames = message.progressiveBlockTypeNames,
               !progressiveBlockTypeNames.isEmpty
            {
                parts.append("progressive=\(progressiveBlockTypeNames.joined(separator: "+"))")
            }
            if let progressiveRegionTileCount = message.progressiveRegionTileCount {
                parts.append("tiles=\(progressiveRegionTileCount)")
            }
            if let progressiveTileFirstCount = message.progressiveTileFirstCount,
               progressiveTileFirstCount > 0
            {
                parts.append("tile-first=\(progressiveTileFirstCount)")
            }
            if let progressiveTileUpgradeCount = message.progressiveTileUpgradeCount,
               progressiveTileUpgradeCount > 0
            {
                parts.append("tile-upgrade=\(progressiveTileUpgradeCount)")
            }
            if let cavideoBlockTypeNames = message.cavideoBlockTypeNames,
               !cavideoBlockTypeNames.isEmpty
            {
                parts.append("remotefx=\(cavideoBlockTypeNames.joined(separator: "+"))")
            }
            if let cavideoTileCount = message.cavideoTileCount {
                parts.append("rfx-tiles=\(cavideoTileCount)")
            }
            if let entropy = message.cavideoTileSetEntropyAlgorithms?.last {
                parts.append("rfx-entropy=\(entropy)")
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
        "content=\(frame.contentKind.rawValue)",
        "size=\(frame.width)x\(frame.height)",
        "payload-bytes=\(frame.payloadByteCount)",
        "regions=\(frame.regionRects.count)",
    ]
    if frame.contentKind == .video {
        parts.append("video=\(frame.videoCodec.displayName)")
    }
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
        credentials: credentials,
        desktopWidth: args?.desktopWidth ?? 1280,
        desktopHeight: args?.desktopHeight ?? 720,
        graphicsCapabilityProfile: args?.graphicsCapabilityProfile ?? .automatic
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
        desktopWidth: args.desktopWidth,
        desktopHeight: args.desktopHeight,
        audioPlaybackEnabled: args.audioPlaybackEnabled,
        earlyUserAuthorizationEnabled: args.earlyUserAuthorizationEnabled,
        graphicsCapabilityProfile: args.graphicsCapabilityProfile
    )
    let client = RDPPreflightClient()
    let probeRecorder = PreflightProbeRecorder(windowsClipboardProbeText: args.probeWindowsClipboardText)
    let report = args.dryRun
        ? client.dryRun(configuration: configuration)
        : client.run(
            configuration: configuration,
            onGraphicsFrame: { _ in
                probeRecorder.sendInputProbeAfterFirstFrame(
                    text: args.probeInputText,
                    movePointerToCenter: args.probeInputPointer,
                    toggleWindowsStart: args.probeWindowsKey,
                    pasteClipboardOnWindows: args.probeWindowsPasteClipboard,
                    windowsClipboardText: args.probeWindowsClipboardText,
                    triggerWindowsAudio: args.probeWindowsAudio
                )
            },
            onInputReady: { session in
                probeRecorder.recordInputSession(session)
            },
            onClipboardReady: { session in
                if let probeClipboardText = args.probeClipboardText {
                    probeRecorder.publishClipboardText(probeClipboardText, on: session)
                }
            },
            onClipboardText: { text in
                probeRecorder.recordClipboardText(text)
            }
        )
    var annotatedReport = report
    probeRecorder.apply(to: &annotatedReport)

    try printReport(annotatedReport, json: args.json)
    if annotatedReport.status == "failure" {
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
