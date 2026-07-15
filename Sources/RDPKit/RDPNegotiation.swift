import Foundation

struct RDPSecurityProtocols: OptionSet, Sendable, Equatable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let tls = RDPSecurityProtocols(rawValue: 0x0000_0001)
    static let credSSP = RDPSecurityProtocols(rawValue: 0x0000_0002)
    static let rdSTLS = RDPSecurityProtocols(rawValue: 0x0000_0004)
    static let credSSPWithEarlyUserAuth = RDPSecurityProtocols(rawValue: 0x0000_0008)
    static let rdsAAD = RDPSecurityProtocols(rawValue: 0x0000_0010)

    var names: [String] {
        var values: [String] = []
        if contains(.tls) { values.append("tls") }
        if contains(.credSSP) { values.append("credssp") }
        if contains(.rdSTLS) { values.append("rdstls") }
        if contains(.credSSPWithEarlyUserAuth) { values.append("credssp-early-user-auth") }
        if contains(.rdsAAD) { values.append("rds-aad") }
        if values.isEmpty { values.append("standard-rdp-security") }
        return values
    }
}

enum RDPNegotiationRequestFlags {
    static let restrictedAdminModeRequired: UInt8 = 0x01
    static let redirectedAuthenticationModeRequired: UInt8 = 0x02
    static let correlationInfoPresent: UInt8 = 0x08
    static let supportedMask: UInt8 = restrictedAdminModeRequired
        | redirectedAuthenticationModeRequired
        | correlationInfoPresent
}

enum RDPNegotiationResponseFlags {
    static let extendedClientDataSupported: UInt8 = 0x01
    static let dynamicVirtualChannelGraphicsSupported: UInt8 = 0x02
    static let reserved: UInt8 = 0x04
    static let restrictedAdminModeSupported: UInt8 = 0x08
    static let redirectedAuthenticationModeSupported: UInt8 = 0x10
    static let supportedMask: UInt8 = extendedClientDataSupported
        | dynamicVirtualChannelGraphicsSupported
        | reserved
        | restrictedAdminModeSupported
        | redirectedAuthenticationModeSupported
}

enum RDPNegotiationResult: Equatable, Sendable {
    case selected(RDPSecurityProtocols)
    case failure(UInt32)

    var selectedProtocolNames: [String]? {
        guard case let .selected(protocols) = self else {
            return nil
        }
        return protocols.names
    }
}

enum RDPEarlyUserAuthorizationResult: UInt32, Sendable {
    case success = 0x0000_0000
    case accessDenied = 0x0000_0005
}

struct RDPEarlyUserAuthorizationResultPDU: Equatable, Sendable {
    var rawValue: UInt32

    var result: RDPEarlyUserAuthorizationResult? {
        RDPEarlyUserAuthorizationResult(rawValue: rawValue)
    }

    static func parse(_ data: Data) throws -> RDPEarlyUserAuthorizationResultPDU {
        guard data.count == 4 else {
            throw RDPDecodeError.invalidNegotiationLength(UInt16(clamping: data.count))
        }
        var cursor = ByteCursor(data)
        let rawValue = try cursor.readLittleEndianUInt32()
        guard RDPEarlyUserAuthorizationResult(rawValue: rawValue) != nil else {
            throw RDPDecodeError.invalidNegotiationProtocol(rawValue)
        }
        return RDPEarlyUserAuthorizationResultPDU(rawValue: rawValue)
    }
}

private enum RDPNegotiationFailureCode {
    static let validValues: Set<UInt32> = [
        0x0000_0001,
        0x0000_0002,
        0x0000_0003,
        0x0000_0004,
        0x0000_0005,
        0x0000_0006,
        0x0000_0007,
    ]
}

struct RDPNegotiationResponseMessage: Equatable, Sendable {
    var flags: UInt8
    var result: RDPNegotiationResult
}

extension RDPSecurityProtocols {
    func canSelect(_ selectedProtocols: RDPSecurityProtocols) -> Bool {
        selectedProtocols.isValidServerSelection
            && (selectedProtocols.rawValue == 0 || isSuperset(of: selectedProtocols))
    }

    var usesTLS: Bool {
        contains(.tls) || contains(.credSSP) || contains(.credSSPWithEarlyUserAuth)
    }

    var usesCredSSP: Bool {
        contains(.credSSP) || contains(.credSSPWithEarlyUserAuth)
    }
}

struct RDPNegotiationRequest: Equatable, Sendable {
    var flags: UInt8
    var requestedProtocols: RDPSecurityProtocols

    init(
        flags: UInt8 = 0,
        requestedProtocols: RDPSecurityProtocols = [.tls, .credSSP]
    ) {
        self.flags = flags
        self.requestedProtocols = requestedProtocols.normalizedForNegotiationRequest
    }

    func encoded() -> Data {
        precondition(flags & ~RDPNegotiationRequestFlags.supportedMask == 0)

        var data = Data()
        data.appendUInt8(0x01)
        data.appendUInt8(flags)
        data.appendLittleEndianUInt16(8)
        data.appendLittleEndianUInt32(requestedProtocols.rawValue)
        return data
    }
}

enum RDPNegotiationResponse {
    static func parse(_ data: Data) throws -> RDPNegotiationResult {
        try parseMessage(data).result
    }

    static func parseMessage(_ data: Data) throws -> RDPNegotiationResponseMessage {
        var cursor = ByteCursor(data)
        let type = try cursor.readUInt8()
        let flags = try cursor.readUInt8()
        let length = try cursor.readLittleEndianUInt16()
        guard length == 8 else {
            throw RDPDecodeError.invalidNegotiationLength(length)
        }
        guard data.count == Int(length) else {
            throw RDPDecodeError.invalidNegotiationLength(UInt16(clamping: data.count))
        }

        let value = try cursor.readLittleEndianUInt32()
        switch type {
        case 0x02:
            guard RDPSecurityProtocols(rawValue: value).isValidServerSelection else {
                throw RDPDecodeError.invalidNegotiationProtocol(value)
            }
            return RDPNegotiationResponseMessage(
                flags: flags,
                result: .selected(RDPSecurityProtocols(rawValue: value))
            )
        case 0x03:
            guard flags == 0 else {
                throw RDPDecodeError.invalidNegotiationFlags(flags)
            }
            guard RDPNegotiationFailureCode.validValues.contains(value) else {
                throw RDPDecodeError.invalidNegotiationFailureCode(value)
            }
            return RDPNegotiationResponseMessage(
                flags: flags,
                result: .failure(value)
            )
        default:
            throw RDPDecodeError.invalidNegotiationType(type)
        }
    }
}

private extension RDPSecurityProtocols {
    var normalizedForNegotiationRequest: RDPSecurityProtocols {
        var protocols = self
        if protocols.contains(.credSSPWithEarlyUserAuth) {
            protocols.insert(.credSSP)
        }
        if protocols.contains(.credSSP) {
            protocols.insert(.tls)
        }
        return protocols
    }

    var isValidServerSelection: Bool {
        switch rawValue {
        case 0x0000_0000,
             RDPSecurityProtocols.tls.rawValue,
             RDPSecurityProtocols.credSSP.rawValue,
             RDPSecurityProtocols.rdSTLS.rawValue,
             RDPSecurityProtocols.credSSPWithEarlyUserAuth.rawValue,
             RDPSecurityProtocols.rdsAAD.rawValue:
            true
        default:
            false
        }
    }
}
