import Foundation

enum RDPClientInfoEncodingError: Error, Equatable, CustomStringConvertible {
    case fieldTooLong(name: String, maxBytesIncludingNull: Int, actualBytesIncludingNull: Int)

    var description: String {
        switch self {
        case let .fieldTooLong(name, maxBytesIncludingNull, actualBytesIncludingNull):
            "\(name) is \(actualBytesIncludingNull) bytes including terminator; maximum is \(maxBytesIncludingNull)"
        }
    }
}

struct RDPClientInfoPDU: Equatable, Sendable {
    var credentials: RDPCredentials?
    var clientAddress: String
    var clientDirectory: String
    var audioPlaybackEnabled: Bool

    init(
        credentials: RDPCredentials?,
        clientAddress: String = "0.0.0.0",
        clientDirectory: String = "KRDPSwift",
        audioPlaybackEnabled: Bool = false
    ) {
        self.credentials = credentials
        self.clientAddress = clientAddress
        self.clientDirectory = clientDirectory
        self.audioPlaybackEnabled = audioPlaybackEnabled
    }

    var credentialsIncluded: Bool {
        credentials != nil
    }

    func encodedPDUData() throws -> Data {
        let domain = try rdpUnicodeString(
            credentials?.domain ?? "",
            name: "domain",
            maxBytesIncludingNull: RDPClientInfoLimits.standardFieldByteCount
        )
        let username = try rdpUnicodeString(
            credentials?.username ?? "",
            name: "username",
            maxBytesIncludingNull: RDPClientInfoLimits.standardFieldByteCount
        )
        let password = try rdpUnicodeString(
            credentials?.password ?? "",
            name: "password",
            maxBytesIncludingNull: RDPClientInfoLimits.standardFieldByteCount
        )
        let alternateShell = try rdpUnicodeString(
            "",
            name: "alternateShell",
            maxBytesIncludingNull: RDPClientInfoLimits.standardFieldByteCount
        )
        let workingDirectory = try rdpUnicodeString(
            "",
            name: "workingDirectory",
            maxBytesIncludingNull: RDPClientInfoLimits.standardFieldByteCount
        )
        let clientAddress = try rdpUnicodeString(
            clientAddress,
            name: "clientAddress",
            maxBytesIncludingNull: RDPClientInfoLimits.clientAddressByteCount
        )
        let clientDirectory = try rdpUnicodeString(
            clientDirectory,
            name: "clientDirectory",
            maxBytesIncludingNull: RDPClientInfoLimits.standardFieldByteCount
        )

        var data = Data()
        data.appendLittleEndianUInt16(0x0040)
        data.appendLittleEndianUInt16(0x0000)
        data.appendLittleEndianUInt32(0x0000_0409)
        data.appendLittleEndianUInt32(infoFlags)
        data.appendLittleEndianUInt16(domain.byteCountExcludingTerminator)
        data.appendLittleEndianUInt16(username.byteCountExcludingTerminator)
        data.appendLittleEndianUInt16(password.byteCountExcludingTerminator)
        data.appendLittleEndianUInt16(alternateShell.byteCountExcludingTerminator)
        data.appendLittleEndianUInt16(workingDirectory.byteCountExcludingTerminator)
        data.append(domain.bytes)
        data.append(username.bytes)
        data.append(password.bytes)
        data.append(alternateShell.bytes)
        data.append(workingDirectory.bytes)
        // MS-RDPBCGR 2.2.1.11.1.1.1 Extended Info Packet (optional for RDP 5.0+).
        data.appendLittleEndianUInt16(clientAddressFamily)
        data.appendLittleEndianUInt16(clientAddress.byteCountIncludingTerminator)
        data.append(clientAddress.bytes)
        data.appendLittleEndianUInt16(clientDirectory.byteCountIncludingTerminator)
        data.append(clientDirectory.bytes)
        data.append(clientTimeZone)
        data.appendLittleEndianUInt32(0) // clientSessionId
        data.appendLittleEndianUInt32(0) // performanceFlags
        data.appendLittleEndianUInt16(0) // cbAutoReconnectCookie
        return data
    }

    func encodedTPKT(userChannelID: UInt16, ioChannelID: UInt16) throws -> Data {
        try MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: ioChannelID,
            userData: encodedPDUData()
        ).encodedTPKT()
    }

    private var infoFlags: UInt32 {
        var flags: UInt32 = 0
        flags |= RDPClientInfoFlags.mouse
        flags |= RDPClientInfoFlags.disableCtrlAltDel
        if credentials != nil {
            flags |= RDPClientInfoFlags.autoLogon
        }
        flags |= RDPClientInfoFlags.unicode
        flags |= RDPClientInfoFlags.logonNotify
        flags |= RDPClientInfoFlags.enableWindowsKey
        flags |= RDPClientInfoFlags.forceEncryptedClientToServerPDU
        flags |= RDPClientInfoFlags.mouseHasWheel
        if !audioPlaybackEnabled {
            flags |= RDPClientInfoFlags.noAudioPlayback
        }
        return flags
    }

    private var clientAddressFamily: UInt16 {
        clientAddress.contains(":") ? 0x0017 : 0x0002
    }
}

private enum RDPClientInfoFlags {
    static let mouse: UInt32 = 0x0000_0001
    static let disableCtrlAltDel: UInt32 = 0x0000_0002
    static let autoLogon: UInt32 = 0x0000_0008
    static let unicode: UInt32 = 0x0000_0010
    static let logonNotify: UInt32 = 0x0000_0040
    static let enableWindowsKey: UInt32 = 0x0000_0100
    static let forceEncryptedClientToServerPDU: UInt32 = 0x0000_4000
    static let mouseHasWheel: UInt32 = 0x0002_0000
    static let noAudioPlayback: UInt32 = 0x0008_0000
}

private enum RDPClientInfoLimits {
    static let standardFieldByteCount = 512
    static let clientAddressByteCount = 80
}

private let clientTimeZone = Data(repeating: 0, count: 172)

private struct RDPUnicodeString: Equatable {
    var bytes: Data

    var byteCountExcludingTerminator: UInt16 {
        UInt16(bytes.count - 2)
    }

    var byteCountIncludingTerminator: UInt16 {
        UInt16(bytes.count)
    }
}

private func rdpUnicodeString(
    _ value: String,
    name: String,
    maxBytesIncludingNull: Int
) throws -> RDPUnicodeString {
    var bytes = Data()
    for codeUnit in value.utf16 {
        bytes.appendLittleEndianUInt16(codeUnit)
    }
    bytes.appendLittleEndianUInt16(0)

    guard bytes.count <= maxBytesIncludingNull else {
        throw RDPClientInfoEncodingError.fieldTooLong(
            name: name,
            maxBytesIncludingNull: maxBytesIncludingNull,
            actualBytesIncludingNull: bytes.count
        )
    }

    return RDPUnicodeString(bytes: bytes)
}
