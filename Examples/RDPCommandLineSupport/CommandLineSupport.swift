import Foundation
import RDPKit

public enum RDPCommandLineError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingValue(String)
    case unknownOption(String)
    case invalidValue(option: String, value: String, expected: String)
    case missingRequiredOption(String)
    case missingCredential(String)
    case missingPasswordEnv(String)

    public var description: String {
        switch self {
        case let .missingValue(option):
            "missing value for \(option)"
        case let .unknownOption(option):
            "unknown option \(option)"
        case let .invalidValue(option, value, expected):
            "invalid \(option) \(value); expected \(expected)"
        case let .missingRequiredOption(option):
            "missing required \(option)"
        case let .missingCredential(message):
            message
        case let .missingPasswordEnv(name):
            "password environment variable \(name) is not set or is empty"
        }
    }
}

/// Walks command-line options after the executable name.
public struct RDPCommandLineArguments {
    private var remaining: ArraySlice<String>

    public init(_ arguments: [String]) {
        remaining = arguments.dropFirst()
    }

    public static func requestsHelp(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0 == "-h" || $0 == "--help" }
    }

    public mutating func nextOption() -> String? {
        remaining.popFirst()
    }

    public mutating func value(for option: String) throws -> String {
        guard let value = remaining.popFirst() else {
            throw RDPCommandLineError.missingValue(option)
        }
        return value
    }

    public mutating func value<Value>(
        for option: String,
        expected: String,
        _ parse: (String) -> Value?
    ) throws -> Value {
        let text = try value(for: option)
        guard let value = parse(text) else {
            throw RDPCommandLineError.invalidValue(option: option, value: text, expected: expected)
        }
        return value
    }

    public mutating func positiveInteger(for option: String) throws -> Int {
        try value(for: option, expected: "a positive integer") { text in
            Int(text).flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

/// Connection options shared by the example command-line tools.
public struct RDPCommandLineConnectionOptions: Equatable, Sendable {
    public var host: String?
    public var port: UInt16 = 3389
    public var username: String?
    public var domain: String?
    public var passwordEnv: String?
    public var timeoutSeconds: Int
    public var desktopWidth: UInt16 = 1280
    public var desktopHeight: UInt16 = 720
    public var graphicsCapabilityProfiles: [RDPGraphicsCapabilityProfile] = []
    public var hideCertificateWarnings = false

    public init(timeoutSeconds: Int = 10) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// The last `--graphics-profile` given, or `.automatic`.
    public var graphicsCapabilityProfile: RDPGraphicsCapabilityProfile {
        graphicsCapabilityProfiles.last ?? .automatic
    }

    /// Consumes `option` and its value when it is a shared connection option.
    /// - Returns: `false` when the option belongs to the calling tool.
    public mutating func parse(_ option: String, from arguments: inout RDPCommandLineArguments) throws -> Bool {
        switch option {
        case "--host":
            host = try arguments.value(for: option)
        case "--port":
            port = try arguments.value(for: option, expected: "1...65535") { UInt16($0).flatMap { $0 > 0 ? $0 : nil } }
        case "--username":
            username = try arguments.value(for: option)
        case "--domain":
            domain = try arguments.value(for: option)
        case "--password-env":
            passwordEnv = try arguments.value(for: option)
        case "--timeout-seconds":
            timeoutSeconds = try arguments.positiveInteger(for: option)
        case "--desktop-width":
            desktopWidth = try arguments.value(for: option, expected: "640...8192") { text in
                UInt16(text).flatMap { (640 ... 8192).contains($0) ? $0 : nil }
            }
        case "--desktop-height":
            desktopHeight = try arguments.value(for: option, expected: "480...8192") { text in
                UInt16(text).flatMap { (480 ... 8192).contains($0) ? $0 : nil }
            }
        case "--graphics-profile":
            let expected = RDPGraphicsCapabilityProfile.allCases.map(\.rawValue).joined(separator: "|")
            try graphicsCapabilityProfiles.append(
                arguments.value(for: option, expected: expected) { RDPGraphicsCapabilityProfile(rawValue: $0) }
            )
        case "--hide-certificate-warnings":
            hideCertificateWarnings = true
        default:
            return false
        }
        return true
    }

    public func requiredHost() throws -> String {
        guard let host, host.isEmpty == false else {
            throw RDPCommandLineError.missingRequiredOption("--host")
        }
        return host
    }

    /// Reads the password from the environment variable named by `--password-env`, so it never
    /// appears in the process arguments.
    public func credentials(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RDPCredentials? {
        guard username != nil || domain != nil || passwordEnv != nil else {
            return nil
        }
        guard let username, username.isEmpty == false else {
            throw RDPCommandLineError.missingCredential("--username is required when credentials are provided")
        }
        guard let passwordEnv, passwordEnv.isEmpty == false else {
            throw RDPCommandLineError.missingCredential("--password-env is required when credentials are provided")
        }
        guard let password = environment[passwordEnv], password.isEmpty == false else {
            throw RDPCommandLineError.missingPasswordEnv(passwordEnv)
        }
        return RDPCredentials(username: username, domain: domain, password: password)
    }

    public func configuration(
        credentials: RDPCredentials?,
        graphicsCapabilityProfile: RDPGraphicsCapabilityProfile? = nil,
        graphicsFrameCaptureLimit: Int?,
        clipboardEnabled: Bool = true,
        audioPlaybackEnabled: Bool = false,
        earlyUserAuthorizationEnabled: Bool = false
    ) throws -> RDPConnectionConfiguration {
        try RDPConnectionConfiguration(
            host: requiredHost(),
            port: port,
            credentials: credentials,
            timeoutSeconds: timeoutSeconds,
            hideCertificateWarnings: hideCertificateWarnings,
            graphicsFrameCaptureLimit: graphicsFrameCaptureLimit,
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight,
            clipboardEnabled: clipboardEnabled,
            audioPlaybackEnabled: audioPlaybackEnabled,
            earlyUserAuthorizationEnabled: earlyUserAuthorizationEnabled,
            graphicsCapabilityProfile: graphicsCapabilityProfile ?? self.graphicsCapabilityProfile
        )
    }
}
