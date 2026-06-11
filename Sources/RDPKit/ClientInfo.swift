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

    init(
        credentials: RDPCredentials?,
        clientAddress: String = "0.0.0.0",
        clientDirectory: String = "KRDPSwift"
    ) {
        self.credentials = credentials
        self.clientAddress = clientAddress
        self.clientDirectory = clientDirectory
    }

    var credentialsIncluded: Bool {
        credentials != nil
    }

    func encodedPDUData() throws -> Data {
        let domain = try rdpUnicodeString(
            credentials?.domain ?? "",
            name: "domain",
            maxBytesIncludingNull: 512
        )
        let username = try rdpUnicodeString(
            credentials?.username ?? "",
            name: "username",
            maxBytesIncludingNull: 512
        )
        let password = try rdpUnicodeString(
            credentials?.password ?? "",
            name: "password",
            maxBytesIncludingNull: 512
        )
        let alternateShell = try rdpUnicodeString(
            "",
            name: "alternateShell",
            maxBytesIncludingNull: 512
        )
        let workingDirectory = try rdpUnicodeString(
            "",
            name: "workingDirectory",
            maxBytesIncludingNull: 512
        )
        let clientAddress = try rdpUnicodeString(
            clientAddress,
            name: "clientAddress",
            maxBytesIncludingNull: 80
        )
        let clientDirectory = try rdpUnicodeString(
            clientDirectory,
            name: "clientDirectory",
            maxBytesIncludingNull: 512
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
        data.appendLittleEndianUInt16(0x0002)
        data.appendLittleEndianUInt16(clientAddress.byteCountIncludingTerminator)
        data.append(clientAddress.bytes)
        data.appendLittleEndianUInt16(clientDirectory.byteCountIncludingTerminator)
        data.append(clientDirectory.bytes)
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
        flags |= 0x0000_0001
        flags |= 0x0000_0002
        if credentials != nil {
            flags |= 0x0000_0008
        }
        flags |= 0x0000_0010
        flags |= 0x0000_0040
        flags |= 0x0000_0100
        flags |= 0x0000_4000
        return flags
    }
}

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
