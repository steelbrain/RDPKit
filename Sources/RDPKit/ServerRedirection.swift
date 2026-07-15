import Foundation

struct RDPServerRedirectionPDU: Equatable, Sendable {
    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt32

        static let targetNetAddress = Flags(rawValue: 0x0000_0001)
        static let loadBalanceInfo = Flags(rawValue: 0x0000_0002)
        static let username = Flags(rawValue: 0x0000_0004)
        static let domain = Flags(rawValue: 0x0000_0008)
        static let password = Flags(rawValue: 0x0000_0010)
        static let dontStoreUsername = Flags(rawValue: 0x0000_0020)
        static let smartcardLogon = Flags(rawValue: 0x0000_0040)
        static let noRedirect = Flags(rawValue: 0x0000_0080)
        static let targetFQDN = Flags(rawValue: 0x0000_0100)
        static let targetNetBIOSName = Flags(rawValue: 0x0000_0200)
        static let targetNetAddresses = Flags(rawValue: 0x0000_0800)
        static let tsvURL = Flags(rawValue: 0x0000_1000)
        static let serverTSVCapable = Flags(rawValue: 0x0000_2000)
        static let passwordIsPKEncrypted = Flags(rawValue: 0x0000_4000)
        static let redirectionGuid = Flags(rawValue: 0x0000_8000)
        static let targetCertificate = Flags(rawValue: 0x0001_0000)
    }

    var channelID: UInt16
    var totalLength: UInt16
    var pduSource: UInt16
    var redirectionPacketFlags: UInt16
    var redirectionLength: UInt16
    var sessionID: UInt32
    var flags: Flags
    var loadBalanceInfo: Data?
    var targetNetAddress: String?
    var username: String?
    var domain: String?
    var password: String?
    var encryptedPassword: Data?
    var targetFQDN: String?
    var targetNetBIOSName: String?
    var targetNetAddresses: [String]
    var tsvURL: String?
    var redirectionGuid: Data?
    var targetCertificate: Data?

    var routingToken: Data? {
        guard !flags.contains(.targetNetAddress) else {
            return nil
        }
        return loadBalanceInfo
    }

    var targetHost: String? {
        targetFQDN ?? targetNetAddress ?? targetNetAddresses.first ?? targetNetBIOSName
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPServerRedirectionPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.userData.count >= 20 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let totalLength = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let pduSource = try cursor.readLittleEndianUInt16()
        guard pduType & 0x000F == 0x000A else {
            return nil
        }
        let pduVersion = pduType >> 4
        guard (pduVersion == 0 || pduVersion == 1),
              Int(totalLength) >= 20,
              Int(totalLength) <= indication.userData.count
        else {
            throw RDPDecodeError.invalidShareControlHeader
        }

        _ = try cursor.readLittleEndianUInt16()
        let redirectionPacketFlags = try cursor.readLittleEndianUInt16()
        let redirectionLength = try cursor.readLittleEndianUInt16()
        let availableRedirectionBytes = Int(totalLength) - 12
        let declaredRedirectionBodyBytes = Int(redirectionLength) - 4
        guard redirectionPacketFlags == 0x0400,
              redirectionLength >= 12,
              availableRedirectionBytes >= 8,
              declaredRedirectionBodyBytes == availableRedirectionBytes
                  || declaredRedirectionBodyBytes == availableRedirectionBytes + 2
        else {
            throw RDPDecodeError.invalidShareControlHeader
        }

        var redirectionCursor = ByteCursor(try cursor.readData(count: availableRedirectionBytes))
        let sessionID = try redirectionCursor.readLittleEndianUInt32()
        let flags = Flags(rawValue: try redirectionCursor.readLittleEndianUInt32())
        var pdu = RDPServerRedirectionPDU(
            channelID: indication.channelID,
            totalLength: totalLength,
            pduSource: pduSource,
            redirectionPacketFlags: redirectionPacketFlags,
            redirectionLength: redirectionLength,
            sessionID: sessionID,
            flags: flags,
            loadBalanceInfo: nil,
            targetNetAddress: nil,
            username: nil,
            domain: nil,
            password: nil,
            encryptedPassword: nil,
            targetFQDN: nil,
            targetNetBIOSName: nil,
            targetNetAddresses: [],
            tsvURL: nil,
            redirectionGuid: nil,
            targetCertificate: nil
        )

        // Optional redirection fields appear on the wire in ascending flag-bit
        // order. If the server set a flag we don't recognize, we can't know the
        // layout of (or skip past) its field, so parsing any later field risks
        // misalignment. Bail out before reading optionals rather than follow a
        // redirection we can't fully interpret.
        guard flags.rawValue & ~Flags.knownFieldMask == 0 else {
            return pdu
        }

        if flags.contains(.targetNetAddress) {
            pdu.targetNetAddress = try redirectionCursor.readLengthPrefixedUTF16String()
        }
        if flags.contains(.loadBalanceInfo) {
            pdu.loadBalanceInfo = try redirectionCursor.readLengthPrefixedBytes()
        }
        if flags.contains(.username) {
            pdu.username = try redirectionCursor.readLengthPrefixedUTF16String()
        }
        if flags.contains(.domain) {
            pdu.domain = try redirectionCursor.readLengthPrefixedUTF16String()
        }
        if flags.contains(.password) {
            if flags.contains(.passwordIsPKEncrypted) {
                pdu.encryptedPassword = try redirectionCursor.readLengthPrefixedBytes()
            } else {
                pdu.password = try redirectionCursor.readLengthPrefixedUTF16String()
            }
        }
        if flags.contains(.targetFQDN) {
            pdu.targetFQDN = try redirectionCursor.readLengthPrefixedUTF16String()
        }
        if flags.contains(.targetNetBIOSName) {
            pdu.targetNetBIOSName = try redirectionCursor.readLengthPrefixedUTF16String()
        }
        if flags.contains(.tsvURL) {
            pdu.tsvURL = try redirectionCursor.readLengthPrefixedUTF16String()
        }
        if flags.contains(.redirectionGuid) {
            pdu.redirectionGuid = try redirectionCursor.readLengthPrefixedBytes()
        }
        if flags.contains(.targetCertificate) {
            pdu.targetCertificate = try redirectionCursor.readLengthPrefixedBytes()
        }
        if flags.contains(.targetNetAddresses) {
            pdu.targetNetAddresses = try redirectionCursor.readTargetNetAddresses()
        }

        guard redirectionCursor.remaining == 0 || redirectionCursor.remaining == 8 else {
            throw RDPDecodeError.invalidShareControlHeader
        }

        return pdu
    }
}

private extension RDPServerRedirectionPDU.Flags {
    static let knownFieldMask: UInt32 = [
        targetNetAddress,
        loadBalanceInfo,
        username,
        domain,
        password,
        dontStoreUsername,
        smartcardLogon,
        noRedirect,
        targetFQDN,
        targetNetBIOSName,
        targetNetAddresses,
        tsvURL,
        serverTSVCapable,
        passwordIsPKEncrypted,
        redirectionGuid,
        targetCertificate,
    ].reduce(0) { $0 | $1.rawValue }
}

private extension ByteCursor {
    mutating func readLengthPrefixedBytes() throws -> Data {
        let byteCount = try Int(readLittleEndianUInt32())
        return try readData(count: byteCount)
    }

    mutating func readLengthPrefixedUTF16String() throws -> String {
        decodeUTF16LEString(try readLengthPrefixedBytes())
    }

    mutating func readTargetNetAddresses() throws -> [String] {
        let totalByteCount = try Int(readLittleEndianUInt32())
        guard totalByteCount >= 4 else {
            throw RDPDecodeError.invalidShareControlHeader
        }
        var addressCursor = ByteCursor(try readData(count: totalByteCount))
        let count = try Int(addressCursor.readLittleEndianUInt32())
        var addresses: [String] = []
        for _ in 0 ..< count {
            addresses.append(try addressCursor.readLengthPrefixedUTF16String())
        }
        guard addressCursor.remaining == 0 else {
            throw RDPDecodeError.invalidShareControlHeader
        }
        return addresses
    }
}

private func decodeUTF16LEString(_ data: Data) -> String {
    var codeUnits: [UInt16] = []
    var index = data.startIndex
    while index < data.endIndex {
        let next = data.index(after: index)
        guard next < data.endIndex else {
            break
        }
        let value = UInt16(data[index]) | UInt16(data[next]) << 8
        guard value != 0 else {
            break
        }
        codeUnits.append(value)
        index = data.index(after: next)
    }
    return String(decoding: codeUnits, as: UTF16.self)
}
