import Foundation

struct RDPSecurityProtocols: OptionSet, Sendable, Equatable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let tls = RDPSecurityProtocols(rawValue: 0x0000_0001)
    static let credSSP = RDPSecurityProtocols(rawValue: 0x0000_0002)
    static let credSSPWithEarlyUserAuth = RDPSecurityProtocols(rawValue: 0x0000_0008)
    static let rdSTLS = RDPSecurityProtocols(rawValue: 0x0000_0010)

    var names: [String] {
        var values: [String] = []
        if contains(.tls) { values.append("tls") }
        if contains(.credSSP) { values.append("credssp") }
        if contains(.credSSPWithEarlyUserAuth) { values.append("credssp-early-user-auth") }
        if contains(.rdSTLS) { values.append("rdstls") }
        if values.isEmpty { values.append("standard-rdp-security") }
        return values
    }
}

enum RDPNegotiationResponseFlags {
    static let extendedClientDataSupported: UInt8 = 0x01
    static let dynamicVirtualChannelGraphicsSupported: UInt8 = 0x02
    static let restrictedAdminModeSupported: UInt8 = 0x08
    static let redirectedAuthenticationModeSupported: UInt8 = 0x10
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

struct RDPNegotiationResponseMessage: Equatable, Sendable {
    var flags: UInt8
    var result: RDPNegotiationResult
}

struct RDPNegotiationRequest: Equatable, Sendable {
    var flags: UInt8
    var requestedProtocols: RDPSecurityProtocols

    init(
        flags: UInt8 = 0,
        requestedProtocols: RDPSecurityProtocols = [.tls, .credSSP]
    ) {
        self.flags = flags
        self.requestedProtocols = requestedProtocols
    }

    func encoded() -> Data {
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

        let value = try cursor.readLittleEndianUInt32()
        switch type {
        case 0x02:
            return RDPNegotiationResponseMessage(
                flags: flags,
                result: .selected(RDPSecurityProtocols(rawValue: value))
            )
        case 0x03:
            return RDPNegotiationResponseMessage(
                flags: flags,
                result: .failure(value)
            )
        default:
            throw RDPDecodeError.invalidNegotiationType(type)
        }
    }
}
