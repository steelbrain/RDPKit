import Foundation
import Security

public struct RDPStaticVirtualChannelAssignment: Encodable, Equatable, Sendable {
    public var name: String
    public var channelID: UInt16

    public init(name: String, channelID: UInt16) {
        self.name = name
        self.channelID = channelID
    }
}

struct MCSConnectResponse: Equatable, Sendable {
    var result: UInt8
    var calledConnectID: UInt16?
    var serverUserDataKey: String?
    var clientRequestedProtocols: RDPSecurityProtocols?
    var serverEarlyCapabilityFlags: UInt32?
    var ioChannelID: UInt16?
    var messageChannelID: UInt16?
    var staticChannelAssignments: [RDPStaticVirtualChannelAssignment]
    var serverCertificatePublicKey: RDPRSAPublicKey?

    var resultName: String {
        result == 0 ? "rt-successful" : "rt-\(result)"
    }

    var serverSupportsSkipChannelJoin: Bool {
        serverEarlyCapabilityFlags.map { $0 & 0x0000_0008 != 0 } ?? false
    }

    static func parse(
        fromTPKT packet: Data,
        requestedChannels: [RDPStaticVirtualChannel] = [],
        expectedRequestedProtocols: RDPSecurityProtocols? = nil,
        expectedMessageChannelAdvertised: Bool = false
    ) throws -> MCSConnectResponse {
        var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
        let applicationClass = try cursor.readUInt8()
        let applicationType = try cursor.readUInt8()
        guard applicationClass == 0x7F, applicationType == 0x66 else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }

        let connectResponseLength = try cursor.readBERLength()
        var mcsCursor = try ByteCursor(cursor.readData(count: connectResponseLength))
        let resultValue = try mcsCursor.readBEREnumerated()
        guard resultValue <= UInt8.max else {
            throw RDPDecodeError.invalidBERLength
        }
        let result = UInt8(resultValue)

        guard mcsCursor.remaining > 0 else {
            return MCSConnectResponse(
                result: result,
                calledConnectID: nil,
                serverUserDataKey: nil,
                clientRequestedProtocols: nil,
                serverEarlyCapabilityFlags: nil,
                ioChannelID: nil,
                messageChannelID: nil,
                staticChannelAssignments: [],
                serverCertificatePublicKey: nil
            )
        }

        let calledConnectIDValue = try mcsCursor.readBERInteger()
        guard calledConnectIDValue <= UInt16.max else {
            throw RDPDecodeError.invalidBERLength
        }
        let calledConnectID = UInt16(calledConnectIDValue)
        _ = try mcsCursor.readBERSequenceData()
        let userData = try mcsCursor.readBEROctetString()
        let serverData = try parseGCCServerData(
            userData,
            requestedChannels: requestedChannels,
            expectedRequestedProtocols: expectedRequestedProtocols,
            expectedMessageChannelAdvertised: expectedMessageChannelAdvertised
        )

        return MCSConnectResponse(
            result: result,
            calledConnectID: calledConnectID,
            serverUserDataKey: serverData.key,
            clientRequestedProtocols: serverData.clientRequestedProtocols,
            serverEarlyCapabilityFlags: serverData.serverEarlyCapabilityFlags,
            ioChannelID: serverData.ioChannelID,
            messageChannelID: serverData.messageChannelID,
            staticChannelAssignments: serverData.staticChannelAssignments,
            serverCertificatePublicKey: serverData.serverSecurityData?.serverCertificatePublicKey
        )
    }
}

private struct GCCServerData {
    var key: String?
    var clientRequestedProtocols: RDPSecurityProtocols?
    var serverEarlyCapabilityFlags: UInt32?
    var serverSecurityData: ServerSecurityData?
    var ioChannelID: UInt16?
    var messageChannelID: UInt16?
    var staticChannelAssignments: [RDPStaticVirtualChannelAssignment]
}

private struct ServerSecurityData {
    var encryptionMethod: UInt32
    var encryptionLevel: UInt32
    var serverCertificatePublicKey: RDPRSAPublicKey?
}

struct RDPRSAPublicKey: Equatable, Sendable {
    var modulus: Data
    var publicExponent: UInt32
    var keyByteCount: Int

    func encryptRawLittleEndian(_ plaintext: Data) throws -> Data {
        let encrypted = try modPowLittleEndian(
            base: plaintext,
            exponent: publicExponent,
            modulus: modulus
        )
        guard encrypted.count <= keyByteCount else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        return encrypted + Data(repeating: 0, count: keyByteCount - encrypted.count)
    }
}

private func parseGCCServerData(
    _ data: Data,
    requestedChannels: [RDPStaticVirtualChannel],
    expectedRequestedProtocols: RDPSecurityProtocols?,
    expectedMessageChannelAdvertised: Bool
) throws -> GCCServerData {
    let serverKey = Data([0x4D, 0x63, 0x44, 0x6E])
    guard let keyRange = data.range(of: serverKey) else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    var cursor = ByteCursor(Data(data[keyRange.upperBound...]))
    let userDataLength = try cursor.readPERLength()
    let serverBlocks = try cursor.readData(count: userDataLength)
    guard cursor.remaining == 0 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    let serverData = try parseServerDataBlocks(from: serverBlocks)
    if let expectedRequestedProtocols {
        let actualRequestedProtocols = serverData.clientRequestedProtocols ?? RDPSecurityProtocols(rawValue: 0)
        guard actualRequestedProtocols == expectedRequestedProtocols else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        if expectedRequestedProtocols.rawValue != 0, let securityData = serverData.serverSecurityData {
            guard securityData.encryptionMethod == 0, securityData.encryptionLevel == 0 else {
                throw RDPDecodeError.invalidMCSConnectResponseHeader
            }
        }
    }
    if serverData.messageChannelID != nil {
        guard expectedMessageChannelAdvertised else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
    }
    if !requestedChannels.isEmpty {
        guard serverData.channelIDs.count == requestedChannels.count else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
    }

    let assignments = serverData.channelIDs.enumerated().map { index, channelID in
        let name = requestedChannels.indices.contains(index)
            ? requestedChannels[index].name
            : "channel-\(index)"
        return RDPStaticVirtualChannelAssignment(name: name, channelID: channelID)
    }

    return GCCServerData(
        key: "McDn",
        clientRequestedProtocols: serverData.clientRequestedProtocols,
        serverEarlyCapabilityFlags: serverData.serverEarlyCapabilityFlags,
        serverSecurityData: serverData.serverSecurityData,
        ioChannelID: serverData.ioChannelID,
        messageChannelID: serverData.messageChannelID,
        staticChannelAssignments: assignments
    )
}

private func parseServerDataBlocks(
    from serverBlocks: Data
) throws -> (
    clientRequestedProtocols: RDPSecurityProtocols?,
    serverEarlyCapabilityFlags: UInt32?,
    serverSecurityData: ServerSecurityData?,
    ioChannelID: UInt16?,
    channelIDs: [UInt16],
    messageChannelID: UInt16?
) {
    var cursor = ByteCursor(serverBlocks)
    var clientRequestedProtocols: RDPSecurityProtocols?
    var serverEarlyCapabilityFlags: UInt32?
    var serverSecurityData: ServerSecurityData?
    var ioChannelID: UInt16?
    var channelIDs: [UInt16] = []
    var messageChannelID: UInt16?
    var seenKnownBlockTypes = Set<UInt16>()

    while cursor.remaining >= 4 {
        let type = try cursor.readLittleEndianUInt16()
        let length = try cursor.readLittleEndianUInt16()
        guard length >= 4, Int(length) - 4 <= cursor.remaining else {
            throw RDPDecodeError.invalidUserDataBlockLength(length)
        }
        if isKnownServerDataBlock(type) {
            guard seenKnownBlockTypes.insert(type).inserted else {
                throw RDPDecodeError.invalidMCSConnectResponseHeader
            }
        }

        let body = try cursor.readData(count: Int(length) - 4)
        switch type {
        case 0x0C01:
            guard body.count == 4 || body.count == 8 || body.count == 12 else {
                throw RDPDecodeError.invalidMCSConnectResponseHeader
            }
            if body.count >= 8 {
                var bodyCursor = ByteCursor(body)
                _ = try bodyCursor.readLittleEndianUInt32()
                clientRequestedProtocols = RDPSecurityProtocols(rawValue: try bodyCursor.readLittleEndianUInt32())
                if body.count == 12 {
                    serverEarlyCapabilityFlags = try bodyCursor.readLittleEndianUInt32()
                }
            }
        case 0x0C02:
            serverSecurityData = try parseServerSecurityData(body)
        case 0x0C03:
            guard body.count >= 4 else {
                throw RDPDecodeError.invalidMCSConnectResponseHeader
            }
            var bodyCursor = ByteCursor(body)
            ioChannelID = try bodyCursor.readLittleEndianUInt16()
            let channelCount = try Int(bodyCursor.readLittleEndianUInt16())
            channelIDs = []
            for _ in 0 ..< channelCount {
                try channelIDs.append(bodyCursor.readLittleEndianUInt16())
            }
            if channelCount.isMultiple(of: 2) {
                guard bodyCursor.remaining == 0 else {
                    throw RDPDecodeError.invalidMCSConnectResponseHeader
                }
            } else {
                guard bodyCursor.remaining == 2 else {
                    throw RDPDecodeError.invalidMCSConnectResponseHeader
                }
                _ = try bodyCursor.readLittleEndianUInt16()
            }
        case 0x0C04:
            guard body.count == 2 else {
                throw RDPDecodeError.invalidMCSConnectResponseHeader
            }
            var bodyCursor = ByteCursor(body)
            messageChannelID = try bodyCursor.readLittleEndianUInt16()
        case 0x0C08:
            guard body.count == 4 else {
                throw RDPDecodeError.invalidMCSConnectResponseHeader
            }
        default:
            continue
        }
    }
    guard cursor.remaining == 0 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    guard seenKnownBlockTypes.isSuperset(of: [0x0C01, 0x0C02, 0x0C03]) else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    return (
        clientRequestedProtocols,
        serverEarlyCapabilityFlags,
        serverSecurityData,
        ioChannelID,
        channelIDs,
        messageChannelID
    )
}

private func isKnownServerDataBlock(_ type: UInt16) -> Bool {
    switch type {
    case 0x0C01, 0x0C02, 0x0C03, 0x0C04, 0x0C08:
        true
    default:
        false
    }
}

private func parseServerSecurityData(_ body: Data) throws -> ServerSecurityData {
    guard body.count >= 8 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    var cursor = ByteCursor(body)
    let encryptionMethod = try cursor.readLittleEndianUInt32()
    let encryptionLevel = try cursor.readLittleEndianUInt32()
    guard [0, 1, 2, 8, 16].contains(encryptionMethod),
          [0, 1, 2, 3, 4].contains(encryptionLevel) else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    if encryptionMethod == 0, encryptionLevel == 0 {
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
    } else {
        guard cursor.remaining >= 8 else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        let serverRandomLength = try cursor.readLittleEndianUInt32()
        let serverCertificateLength = try cursor.readLittleEndianUInt32()
        let encryptedPayloadLength = Int(serverRandomLength) + Int(serverCertificateLength)
        guard serverRandomLength == 32,
              serverCertificateLength > 0,
              cursor.remaining == encryptedPayloadLength else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        _ = try cursor.readData(count: Int(serverRandomLength))
        let serverCertificate = try cursor.readData(count: Int(serverCertificateLength))
        let publicKey = try rdpServerCertificatePublicKey(serverCertificate)
        return ServerSecurityData(
            encryptionMethod: encryptionMethod,
            encryptionLevel: encryptionLevel,
            serverCertificatePublicKey: publicKey
        )
    }

    return ServerSecurityData(
        encryptionMethod: encryptionMethod,
        encryptionLevel: encryptionLevel,
        serverCertificatePublicKey: nil
    )
}

func validateRDPServerCertificate(_ data: Data) throws {
    _ = try rdpServerCertificatePublicKey(data)
}

func rdpServerCertificatePublicKey(_ data: Data) throws -> RDPRSAPublicKey {
    var cursor = ByteCursor(data)
    let version = try cursor.readLittleEndianUInt32()
    switch version & 0x7FFF_FFFF {
    case 1:
        return try parseProprietaryServerCertificatePublicKey(version: version, cursor: &cursor)
    case 2:
        return try parseX509ServerCertificateChainPublicKey(cursor: &cursor)
    default:
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
}

private func parseProprietaryServerCertificatePublicKey(
    version: UInt32,
    cursor: inout ByteCursor
) throws -> RDPRSAPublicKey {
    guard version == 1,
          try cursor.readLittleEndianUInt32() == 1,
          try cursor.readLittleEndianUInt32() == 1,
          try cursor.readLittleEndianUInt16() == 0x0006 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    let publicKeyBlobLength = try Int(cursor.readLittleEndianUInt16())
    let publicKey = try parseRSAPublicKey(try cursor.readData(count: publicKeyBlobLength))
    guard try cursor.readLittleEndianUInt16() == 0x0008 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    let signatureBlobLength = try Int(cursor.readLittleEndianUInt16())
    guard signatureBlobLength > 0,
          signatureBlobLength <= cursor.remaining else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    _ = try cursor.readData(count: signatureBlobLength)
    guard cursor.remaining == 0 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    return publicKey
}

private func parseRSAPublicKey(_ data: Data) throws -> RDPRSAPublicKey {
    var cursor = ByteCursor(data)
    let magic = try cursor.readLittleEndianUInt32()
    let keyLength = try cursor.readLittleEndianUInt32()
    let bitLength = try cursor.readLittleEndianUInt32()
    let dataLength = try cursor.readLittleEndianUInt32()
    let publicExponent = try cursor.readLittleEndianUInt32()
    let modulusByteCount = bitLength / 8
    let keyByteCount = Int(keyLength)

    guard magic == 0x3141_5352,
          bitLength > 0,
          bitLength.isMultiple(of: 8),
          keyLength == modulusByteCount + 8,
          dataLength == modulusByteCount - 1,
          keyByteCount <= cursor.remaining else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    let modulus = try cursor.readData(count: keyByteCount)
    guard cursor.remaining == 0,
          modulus.suffix(8).allSatisfy({ $0 == 0 }) else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    return RDPRSAPublicKey(
        modulus: Data(modulus.prefix(Int(modulusByteCount))),
        publicExponent: publicExponent,
        keyByteCount: keyByteCount
    )
}

private func parseX509ServerCertificateChainPublicKey(cursor: inout ByteCursor) throws -> RDPRSAPublicKey {
    let certificateCount = try cursor.readLittleEndianUInt32()
    guard (2 ... 200).contains(certificateCount) else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    var terminalServerCertificate = Data()
    for _ in 0 ..< certificateCount {
        let certificateLength = try Int(cursor.readLittleEndianUInt32())
        guard certificateLength > 0,
              certificateLength <= cursor.remaining else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        terminalServerCertificate = try cursor.readData(count: certificateLength)
    }

    let expectedPaddingLength = 8 + 4 * Int(certificateCount)
    guard cursor.remaining == expectedPaddingLength else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    _ = cursor.readRemainingData()
    return try parseX509CertificateRSAPublicKey(terminalServerCertificate)
}

private func parseX509CertificateRSAPublicKey(_ certificateDER: Data) throws -> RDPRSAPublicKey {
    guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
          let publicKey = SecCertificateCopyKey(certificate),
          let externalRepresentation = SecKeyCopyExternalRepresentation(publicKey, nil) else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    // SecKeyCopyExternalRepresentation returns PKCS #1 RSAPublicKey for RSA keys.
    return try parseDERPKCS1RSAPublicKey(externalRepresentation as Data)
}

private func parseDERPKCS1RSAPublicKey(_ der: Data) throws -> RDPRSAPublicKey {
    var cursor = DERCursor(der)
    var sequence = try DERCursor(cursor.readValue(tag: 0x30))
    let modulus = try derPositiveInteger(sequence.readValue(tag: 0x02))
    let exponent = try derUInt32(sequence.readValue(tag: 0x02))
    guard cursor.isAtEnd, sequence.isAtEnd, !modulus.isEmpty else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    return RDPRSAPublicKey(
        modulus: Data(modulus.reversed()),
        publicExponent: exponent,
        keyByteCount: modulus.count + 8
    )
}

private func derPositiveInteger(_ bytes: Data) throws -> Data {
    guard !bytes.isEmpty else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    let normalized = bytes.first == 0 ? Data(bytes.dropFirst()) : bytes
    guard !normalized.isEmpty else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }
    return normalized
}

private func derUInt32(_ bytes: Data) throws -> UInt32 {
    let normalized = try derPositiveInteger(bytes)
    guard normalized.count <= 4 else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    var value: UInt32 = 0
    for byte in normalized {
        value = value << 8 | UInt32(byte)
    }
    return value
}

/// Raw RSA (`base^exponent mod modulus`) on little-endian integers. Raw RSA
/// requires `base < modulus`; the size cap bounds the work a server-supplied
/// key can cause.
private func modPowLittleEndian(base: Data, exponent: UInt32, modulus: Data) throws -> Data {
    let modulus = littleEndianLimbs(modulus)
    let base = littleEndianLimbs(base)
    guard exponent > 0,
          (1 ... 512).contains(modulus.count),
          modulus[0] & 1 == 1,
          modulus != [1],
          base.count < modulus.count
          || base.count == modulus.count && isLess(base, modulus)
    else {
        throw RDPDecodeError.invalidMCSConnectResponseHeader
    }

    let result = MontgomeryModulus(modulus).power(base, exponent)
    var bytes = Data(capacity: result.count * 4)
    for limb in result {
        bytes.appendLittleEndianUInt32(limb)
    }
    while bytes.last == 0 {
        bytes.removeLast()
    }
    return bytes
}

private func littleEndianLimbs(_ bytes: Data) -> [UInt32] {
    var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
    for (offset, byte) in bytes.enumerated() {
        limbs[offset / 4] |= UInt32(byte) << (8 * (offset % 4))
    }
    while limbs.last == 0 {
        limbs.removeLast()
    }
    return limbs
}

/// Compares equal-length little-endian limb arrays.
private func isLess(_ lhs: [UInt32], _ rhs: [UInt32]) -> Bool {
    for index in lhs.indices.reversed() where lhs[index] != rhs[index] {
        return lhs[index] < rhs[index]
    }
    return false
}

/// Montgomery arithmetic modulo an odd modulus of 32-bit little-endian limbs.
private struct MontgomeryModulus {
    let limbs: [UInt32]
    /// `-limbs[0]^-1 mod 2^32`.
    private let negativeInverse: UInt32

    init(_ limbs: [UInt32]) {
        self.limbs = limbs
        var inverse: UInt32 = 1
        for _ in 0 ..< 5 {
            inverse = inverse &* (2 &- limbs[0] &* inverse)
        }
        negativeInverse = 0 &- inverse
    }

    func power(_ base: [UInt32], _ exponent: UInt32) -> [UInt32] {
        let montgomeryBase = toMontgomery(base)
        var result = toMontgomery([1])
        for bit in (0 ..< UInt32.bitWidth - exponent.leadingZeroBitCount).reversed() {
            result = multiply(result, result)
            if (exponent >> bit) & 1 == 1 {
                result = multiply(result, montgomeryBase)
            }
        }
        return multiply(result, padded([1]))
    }

    private func padded(_ value: [UInt32]) -> [UInt32] {
        value + [UInt32](repeating: 0, count: limbs.count - value.count)
    }

    /// `value * 2^(32 * limbs.count) mod n` by modular doubling; `value < n`.
    private func toMontgomery(_ value: [UInt32]) -> [UInt32] {
        var result = padded(value)
        for _ in 0 ..< UInt32.bitWidth * limbs.count {
            var carry: UInt32 = 0
            for index in result.indices {
                let limb = result[index]
                result[index] = limb << 1 | carry
                carry = limb >> 31
            }
            if carry != 0 || !isLess(result, limbs) {
                subtractModulus(from: &result)
            }
        }
        return result
    }

    /// `lhs * rhs * 2^-(32 * limbs.count) mod n` (CIOS).
    private func multiply(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        let count = limbs.count
        var accumulator = [UInt32](repeating: 0, count: count + 2)
        for outer in 0 ..< count {
            var carry: UInt64 = 0
            for inner in 0 ..< count {
                let sum = UInt64(accumulator[inner]) + UInt64(lhs[inner]) * UInt64(rhs[outer]) + carry
                accumulator[inner] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var sum = UInt64(accumulator[count]) + carry
            accumulator[count] = UInt32(truncatingIfNeeded: sum)
            accumulator[count + 1] = UInt32(sum >> 32)

            let factor = accumulator[0] &* negativeInverse
            sum = UInt64(accumulator[0]) + UInt64(factor) * UInt64(limbs[0])
            carry = sum >> 32
            for inner in 1 ..< count {
                sum = UInt64(accumulator[inner]) + UInt64(factor) * UInt64(limbs[inner]) + carry
                accumulator[inner - 1] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            sum = UInt64(accumulator[count]) + carry
            accumulator[count - 1] = UInt32(truncatingIfNeeded: sum)
            accumulator[count] = accumulator[count + 1] + UInt32(sum >> 32)
        }

        var result = Array(accumulator[0 ..< count])
        if accumulator[count] != 0 || !isLess(result, limbs) {
            subtractModulus(from: &result)
        }
        return result
    }

    private func subtractModulus(from value: inout [UInt32]) {
        var borrow = false
        for index in value.indices {
            let (partial, firstBorrow) = value[index].subtractingReportingOverflow(limbs[index])
            let (difference, secondBorrow) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            value[index] = difference
            borrow = firstBorrow || secondBorrow
        }
    }
}

private struct DERCursor {
    private let bytes: Data
    private var offset = 0

    init(_ data: Data) {
        bytes = data
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func readValue(tag expectedTag: UInt8) throws -> Data {
        let tag = try readByte()
        guard tag == expectedTag else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        let length = try readLength()
        guard length <= remaining else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        let end = bytes.index(start, offsetBy: length)
        offset += length
        return Data(bytes[start ..< end])
    }

    private var remaining: Int {
        bytes.count - offset
    }

    private mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }
        defer { offset += 1 }
        return bytes[bytes.index(bytes.startIndex, offsetBy: offset)]
    }

    private mutating func readLength() throws -> Int {
        let first = try readByte()
        guard first & 0x80 != 0 else {
            return Int(first)
        }

        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4 else {
            throw RDPDecodeError.invalidMCSConnectResponseHeader
        }

        var length = 0
        for _ in 0 ..< byteCount {
            length = length << 8 | Int(try readByte())
        }
        return length
    }
}

private extension ByteCursor {
    mutating func readBERLength() throws -> Int {
        let first = try readUInt8()
        guard first & 0x80 != 0 else {
            return Int(first)
        }

        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4 else {
            throw RDPDecodeError.invalidBERLength
        }

        var value = 0
        for _ in 0 ..< byteCount {
            value = try (value << 8) | Int(readUInt8())
        }
        return value
    }

    mutating func readBEREnumerated() throws -> UInt32 {
        try readBERUnsignedValue(expectedTag: 0x0A)
    }

    mutating func readBERInteger() throws -> UInt32 {
        try readBERUnsignedValue(expectedTag: 0x02)
    }

    mutating func readBEROctetString() throws -> Data {
        let tag = try readUInt8()
        guard tag == 0x04 else {
            throw RDPDecodeError.invalidBERTag(expected: 0x04, actual: tag)
        }

        return try readData(count: readBERLength())
    }

    mutating func readBERSequenceData() throws -> Data {
        let tag = try readUInt8()
        guard tag == 0x30 else {
            throw RDPDecodeError.invalidBERTag(expected: 0x30, actual: tag)
        }

        return try readData(count: readBERLength())
    }

    mutating func readBERUnsignedValue(expectedTag: UInt8) throws -> UInt32 {
        let tag = try readUInt8()
        guard tag == expectedTag else {
            throw RDPDecodeError.invalidBERTag(expected: expectedTag, actual: tag)
        }

        let length = try readBERLength()
        guard length > 0, length <= 4 else {
            throw RDPDecodeError.invalidBERLength
        }

        var value: UInt32 = 0
        for _ in 0 ..< length {
            value = try (value << 8) | UInt32(readUInt8())
        }
        return value
    }
}
