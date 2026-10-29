import CryptoKit
import Foundation

/// The auto-reconnect cookie a server sends once the user is logged on
/// ([MS-RDPBCGR] 2.2.4.2, 5.5); a session's report keeps the latest one in
/// ``RDPConnectionReport/rdpAutoReconnectCookie``. Passed back as
/// ``RDPConnectionConfiguration/autoReconnectCookie``, it asks the server to put
/// the next connection into the same session, for instance after a dropped one.
///
/// Like a password, it is a secret: descriptions, mirrors and encoding leave out
/// its random bits.
public struct RDPAutoReconnectCookie: Equatable, Sendable {
    /// The session the cookie reconnects to.
    public let logonID: UInt32
    /// The server's 16 random bytes, ArcRandomBits.
    public let arcRandomBits: Data

    /// Nil unless `arcRandomBits` is 16 bytes.
    public init?(logonID: UInt32, arcRandomBits: Data) {
        guard arcRandomBits.count == 16 else {
            return nil
        }
        self.logonID = logonID
        self.arcRandomBits = Data(arcRandomBits)
    }

    /// The ARC_CS_PRIVATE_PACKET for the Client Info PDU's autoReconnectCookie
    /// ([MS-RDPBCGR] 2.2.4.3).
    var clientPacket: Data {
        var data = Data()
        data.appendLittleEndianUInt32(28) // cbLen
        data.appendLittleEndianUInt32(1) // Version: AUTO_RECONNECT_VERSION_1
        data.appendLittleEndianUInt32(logonID)
        data.append(securityVerifier)
        return data
    }

    /// HMAC-MD5 keyed with ArcRandomBits over the client random ([MS-RDPBCGR] 5.5).
    /// Only standard RDP security exchanges a client random (2.2.1.10), and RDPKit
    /// connects with TLS or CredSSP only. For those FreeRDP uses 32 zero bytes
    /// (rdp_compute_client_auto_reconnect_cookie copies the client random only when
    /// the selected protocol is PROTOCOL_RDP).
    var securityVerifier: Data {
        Data(HMAC<Insecure.MD5>.authenticationCode(for: Data(count: 32), using: SymmetricKey(data: arcRandomBits)))
    }
}

/// Encoding, descriptions and mirrors keep only the logon ID, so a report or
/// configuration that holds a cookie can be logged without it.
extension RDPAutoReconnectCookie: Encodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum CodingKeys: String, CodingKey {
        case logonID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(logonID, forKey: .logonID)
    }

    public var description: String {
        "RDPAutoReconnectCookie(logonID: \(logonID), arcRandomBits: <redacted>)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["logonID": logonID, "arcRandomBits": "<redacted>"], displayStyle: .struct)
    }
}
