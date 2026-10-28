import CryptoKit
import Foundation
import Security

struct RDPNTLMStep {
    var outputToken: Data?
    var isComplete: Bool
}

/// NTLMv2 client with extended session security, as CredSSP uses it (MS-NLMP).
final class RDPCredSSPNTLMContext {
    private enum State {
        case negotiate
        case authenticate
        case final
    }

    private struct Challenge {
        var message: Data
        var flags: UInt32
        var serverChallenge: Data
        var targetInfo: [AVPair]
        var timestamp: UInt64?
    }

    private struct AVPair {
        var id: UInt16
        var value: Data
    }

    private struct MessageField {
        var length: Int
        var offset: Int
    }

    /// MS-NLMP 2.2.2.1 AvId values.
    private enum AVID {
        static let eol: UInt16 = 0x0000
        static let flags: UInt16 = 0x0006
        static let timestamp: UInt16 = 0x0007
        static let channelBindings: UInt16 = 0x000A
    }

    private let username: String
    private let domain: String
    private let responseKey: Data
    private let workstationName: String
    private let channelBindingsHash: Data?
    private let randomBytes: (Int) throws -> Data
    private let currentFileTime: () -> UInt64
    private var state: State = .negotiate
    private var negotiateMessage = Data()
    private var negotiatedFlags: UInt32 = 0
    private var sendSigningKey = Data()
    private var receiveSigningKey = Data()
    private var sendSealingKey: RDPNTLMRC4?
    private var receiveSealingKey: RDPNTLMRC4?
    private var sendSequenceNumber: UInt32 = 0
    private var receiveSequenceNumber: UInt32 = 0

    init(
        credentials: RDPCredentials,
        workstationName: String = "KRDPSWIFT",
        channelBindingsHash: Data? = nil,
        randomBytes: @escaping (Int) throws -> Data = RDPCredSSPNTLMContext.secureRandomData(count:),
        currentFileTime: @escaping () -> UInt64 = RDPCredSSPNTLMContext.nowFileTime
    ) {
        if let channelBindingsHash {
            precondition(channelBindingsHash.count == Self.hashSize)
        }
        username = credentials.username
        domain = credentials.domain ?? ""
        responseKey = Self.ntowfV2(
            password: credentials.password,
            username: credentials.username,
            domain: credentials.domain ?? ""
        )
        self.workstationName = workstationName
        self.channelBindingsHash = channelBindingsHash
        self.randomBytes = randomBytes
        self.currentFileTime = currentFileTime
    }

    func initialize(inputToken: Data?) throws -> RDPNTLMStep {
        switch state {
        case .negotiate:
            guard inputToken?.isEmpty != false else {
                throw RDPCredSSPError.ntlm("received a server token before sending NTLM negotiate")
            }
            negotiateMessage = Self.makeNegotiateMessage()
            state = .authenticate
            return RDPNTLMStep(outputToken: negotiateMessage, isComplete: false)

        case .authenticate:
            guard let inputToken, !inputToken.isEmpty else {
                throw RDPCredSSPError.missingToken
            }
            let token = try makeAuthenticateMessage(for: Self.parseChallengeMessage(inputToken))
            state = .final
            return RDPNTLMStep(outputToken: token, isComplete: true)

        case .final:
            throw RDPCredSSPError.ntlm("NTLM authentication is already complete")
        }
    }

    /// MS-NLMP 3.4.3 SEAL: the signature followed by the sealed message.
    func wrap(_ message: Data) throws -> Data {
        guard let sendSealingKey else {
            throw RDPCredSSPError.ntlm("NTLM security context is not complete")
        }
        let sealedMessage = sendSealingKey.process(message)
        let signature = messageSignature(
            for: message,
            sequenceNumber: sendSequenceNumber,
            signingKey: sendSigningKey,
            sealingKey: sendSealingKey
        )
        sendSequenceNumber &+= 1
        return signature + sealedMessage
    }

    func unwrap(_ message: Data) throws -> Data {
        guard let receiveSealingKey else {
            throw RDPCredSSPError.ntlm("NTLM security context is not complete")
        }
        guard message.count >= Self.signatureSize else {
            throw RDPCredSSPError.ntlm("NTLM sealed message is too short")
        }
        let decryptedMessage = receiveSealingKey.process(message.dropFirst(Self.signatureSize))
        let expectedSignature = messageSignature(
            for: decryptedMessage,
            sequenceNumber: receiveSequenceNumber,
            signingKey: receiveSigningKey,
            sealingKey: receiveSealingKey
        )
        guard message.prefix(Self.signatureSize) == expectedSignature else {
            throw RDPCredSSPError.ntlm("NTLM message signature did not verify")
        }
        receiveSequenceNumber &+= 1
        return decryptedMessage
    }

    /// MS-NLMP 3.4.4.2 MAC with extended session security.
    private func messageSignature(
        for message: Data,
        sequenceNumber: UInt32,
        signingKey: Data,
        sealingKey: RDPNTLMRC4
    ) -> Data {
        var input = Data()
        input.appendLittleEndianUInt32(sequenceNumber)
        input.append(message)
        var checksum = Self.hmacMD5(key: signingKey, data: input).prefix(8)
        if negotiatedFlags & Self.negotiateKeyExchange != 0 {
            checksum = sealingKey.process(checksum)
        }
        var signature = Data()
        signature.appendLittleEndianUInt32(1)
        signature.append(checksum)
        signature.appendLittleEndianUInt32(sequenceNumber)
        return signature
    }

    /// MS-NLMP 3.1.5.1.2: builds the AUTHENTICATE_MESSAGE and installs the session keys.
    private func makeAuthenticateMessage(for challenge: Challenge) throws -> Data {
        negotiatedFlags = try Self.authenticateFlags(from: challenge.flags, domainSupplied: !domain.isEmpty)
        let clientChallenge = try randomBytes(Self.challengeSize)
        let ntChallenge = Self.ntlmV2Response(
            responseKey: responseKey,
            serverChallenge: challenge.serverChallenge,
            clientChallenge: clientChallenge,
            time: challenge.timestamp ?? currentFileTime(),
            serverName: Self.authenticateTargetInfo(from: challenge.targetInfo, channelBindingsHash: channelBindingsHash)
        )
        // With MsvAvTimestamp the client sends Z(24) instead of the LMv2 response.
        let lmChallengeResponse = challenge.timestamp == nil
            ? Self.hmacMD5(key: responseKey, data: challenge.serverChallenge + clientChallenge) + clientChallenge
            : Data(count: 24)

        let exportedSessionKey: Data
        let encryptedRandomSessionKey: Data
        if negotiatedFlags & Self.negotiateKeyExchange != 0 {
            exportedSessionKey = try randomBytes(Self.hashSize)
            encryptedRandomSessionKey = RDPNTLMRC4(key: ntChallenge.sessionBaseKey).process(exportedSessionKey)
        } else {
            exportedSessionKey = ntChallenge.sessionBaseKey
            encryptedRandomSessionKey = Data()
        }

        let domainName = Self.utf16LittleEndian(domain)
        let userName = Self.utf16LittleEndian(username)
        let workstation = negotiatedFlags & Self.negotiateVersion != 0
            ? Self.utf16LittleEndian(workstationName)
            : Data()
        // Payload in Windows order; the header below lists the fields in MS-NLMP 2.2.1.3 order.
        let payload = [
            domainName,
            userName,
            workstation,
            lmChallengeResponse,
            ntChallenge.response,
            encryptedRandomSessionKey,
        ]
        guard payload.allSatisfy({ $0.count <= UInt16.max }) else {
            throw RDPCredSSPError.ntlm("NTLM authenticate message field is too long")
        }
        var payloadOffset = Self.authenticatePayloadOffset
        let domainField = Self.messageField(for: domainName, offset: &payloadOffset)
        let usernameField = Self.messageField(for: userName, offset: &payloadOffset)
        let workstationField = Self.messageField(for: workstation, offset: &payloadOffset)
        let lmField = Self.messageField(for: lmChallengeResponse, offset: &payloadOffset)
        let ntField = Self.messageField(for: ntChallenge.response, offset: &payloadOffset)
        let encryptedKeyField = Self.messageField(for: encryptedRandomSessionKey, offset: &payloadOffset)

        var message = Self.signatureBytes
        message.appendLittleEndianUInt32(3)
        Self.append(field: lmField, to: &message)
        Self.append(field: ntField, to: &message)
        Self.append(field: domainField, to: &message)
        Self.append(field: usernameField, to: &message)
        Self.append(field: workstationField, to: &message)
        Self.append(field: encryptedKeyField, to: &message)
        message.appendLittleEndianUInt32(negotiatedFlags)
        message.append(negotiatedFlags & Self.negotiateVersion != 0
            ? Self.version
            : Data(count: Self.version.count))
        message.append(Data(count: Self.micSize))
        for field in payload {
            message.append(field)
        }

        let mic = Self.hmacMD5(key: exportedSessionKey, data: negotiateMessage + challenge.message + message)
        message.replaceSubrange(Self.micRange, with: mic)
        installKeys(exportedSessionKey: exportedSessionKey)
        return message
    }

    /// MS-NLMP 3.4.5.2 SIGNKEY and 3.4.5.3 SEALKEY.
    private func installKeys(exportedSessionKey: Data) {
        sendSigningKey = Self.md5(exportedSessionKey + Self.clientSigningMagic)
        receiveSigningKey = Self.md5(exportedSessionKey + Self.serverSigningMagic)
        let sealingMaterial: Data
        if negotiatedFlags & Self.negotiate128 != 0 {
            sealingMaterial = exportedSessionKey
        } else if negotiatedFlags & Self.negotiate56 != 0 {
            sealingMaterial = exportedSessionKey.prefix(7)
        } else {
            sealingMaterial = exportedSessionKey.prefix(5)
        }
        sendSealingKey = RDPNTLMRC4(key: Self.md5(sealingMaterial + Self.clientSealingMagic))
        receiveSealingKey = RDPNTLMRC4(key: Self.md5(sealingMaterial + Self.serverSealingMagic))
    }

    private static func makeNegotiateMessage() -> Data {
        var message = signatureBytes
        message.appendLittleEndianUInt32(1)
        message.appendLittleEndianUInt32(negotiateFlags)
        append(field: MessageField(length: 0, offset: 0), to: &message)
        append(field: MessageField(length: 0, offset: 0), to: &message)
        message.append(version)
        return message
    }

    /// MS-NLMP 2.2.1.2 CHALLENGE_MESSAGE.
    private static func parseChallengeMessage(_ message: Data) throws -> Challenge {
        var cursor = ByteCursor(message)
        guard message.count >= 48,
              try cursor.readData(count: signatureBytes.count) == signatureBytes,
              try cursor.readLittleEndianUInt32() == 2
        else {
            throw RDPCredSSPError.ntlm("invalid NTLM challenge message")
        }
        _ = try cursor.readData(count: 8)
        let flags = try cursor.readLittleEndianUInt32()
        let serverChallenge = try cursor.readData(count: challengeSize)
        _ = try cursor.readData(count: 8)
        let targetInfoLength = Int(try cursor.readLittleEndianUInt16())
        _ = try cursor.readLittleEndianUInt16()
        let targetInfoOffset = Int(try cursor.readLittleEndianUInt32())
        let targetInfo = try parseTargetInfo(readData(message, at: targetInfoOffset, count: targetInfoLength))
        let timestamp = try targetInfo.first(where: { $0.id == AVID.timestamp }).map { pair in
            var cursor = ByteCursor(pair.value)
            return try cursor.readLittleEndianUInt64()
        }
        return Challenge(
            message: message,
            flags: flags,
            serverChallenge: serverChallenge,
            targetInfo: targetInfo,
            timestamp: timestamp
        )
    }

    private static func parseTargetInfo(_ targetInfo: Data) throws -> [AVPair] {
        var cursor = ByteCursor(targetInfo)
        var pairs: [AVPair] = []
        while cursor.remaining >= 4 {
            let id = try cursor.readLittleEndianUInt16()
            let length = Int(try cursor.readLittleEndianUInt16())
            if id == AVID.eol {
                guard length == 0, cursor.remaining == 0 else {
                    throw RDPCredSSPError.ntlm("invalid NTLM target info terminator")
                }
                return pairs
            }
            switch id {
            case AVID.flags where length != 4:
                throw RDPCredSSPError.ntlm("invalid NTLM flags AV pair")
            case AVID.timestamp where length != 8:
                throw RDPCredSSPError.ntlm("invalid NTLM timestamp AV pair")
            default:
                pairs.append(AVPair(id: id, value: try cursor.readData(count: length)))
            }
        }
        throw RDPCredSSPError.ntlm(
            cursor.remaining == 0 ? "missing NTLM target info terminator" : "truncated NTLM target info"
        )
    }

    /// The server's AV pairs with the MIC bit set in MsvAvFlags and this client's channel bindings,
    /// as MS-NLMP 3.1.5.1.2 requires.
    private static func authenticateTargetInfo(from pairs: [AVPair], channelBindingsHash: Data?) -> Data {
        let micPresent: UInt8 = 0x02
        var output = Data()
        func append(_ id: UInt16, _ value: Data) {
            output.appendLittleEndianUInt16(id)
            output.appendLittleEndianUInt16(UInt16(value.count))
            output.append(value)
        }

        var hasFlags = false
        for pair in pairs {
            switch pair.id {
            case AVID.flags:
                var flags = pair.value
                flags[flags.startIndex] |= micPresent
                append(AVID.flags, flags)
                hasFlags = true
            case AVID.channelBindings where channelBindingsHash != nil:
                continue
            default:
                append(pair.id, pair.value)
            }
        }
        if !hasFlags {
            append(AVID.flags, Data([micPresent, 0, 0, 0]))
        }
        if let channelBindingsHash {
            append(AVID.channelBindings, channelBindingsHash)
        }
        append(AVID.eol, Data())
        return output
    }

    /// MS-NLMP 3.3.2 NTOWFv2. Windows upper-cases the user name code point by code point
    /// (RtlUpcaseUnicodeString), so "ß" stays "ß" instead of expanding to "SS".
    static func ntowfV2(password: String, username: String, domain: String) -> Data {
        var uppercasedUsername = String.UnicodeScalarView()
        for scalar in username.unicodeScalars {
            let mapping = scalar.properties.uppercaseMapping.unicodeScalars
            if mapping.count == 1, let uppercased = mapping.first {
                uppercasedUsername.append(uppercased)
            } else {
                uppercasedUsername.append(scalar)
            }
        }
        return hmacMD5(
            key: md4(utf16LittleEndian(password)),
            data: utf16LittleEndian(String(uppercasedUsername) + domain)
        )
    }

    /// MS-NLMP 3.3.2 NTLMv2 ComputeResponse.
    private static func ntlmV2Response(
        responseKey: Data,
        serverChallenge: Data,
        clientChallenge: Data,
        time: UInt64,
        serverName: Data
    ) -> (response: Data, sessionBaseKey: Data) {
        var temp = Data([0x01, 0x01])
        temp.append(Data(count: 6))
        temp.appendLittleEndianUInt64(time)
        temp.append(clientChallenge)
        temp.append(Data(count: 4))
        temp.append(serverName)
        temp.append(Data(count: 4))

        let proof = hmacMD5(key: responseKey, data: serverChallenge + temp)
        return (proof + temp, hmacMD5(key: responseKey, data: proof))
    }

    private static func authenticateFlags(from challengeFlags: UInt32, domainSupplied: Bool) throws -> UInt32 {
        guard challengeFlags & negotiateUnicode != 0 else {
            throw RDPCredSSPError.ntlm("server did not negotiate NTLM Unicode encoding")
        }
        // wrap/unwrap implement only extended session security sealing (MS-NLMP 3.4.4.2),
        // which CredSSP needs for pubKeyAuth and authInfo.
        let requiredFlags = negotiateExtendedSessionSecurity | negotiateSeal
        guard challengeFlags & requiredFlags == requiredFlags else {
            throw RDPCredSSPError.ntlm("server did not negotiate NTLM extended session security and sealing")
        }

        var flags = challengeFlags & authenticateSupportedFlags
        if domainSupplied {
            flags |= negotiateDomainSupplied
        }
        return flags
    }

    private static func messageField(for data: Data, offset: inout Int) -> MessageField {
        let field = MessageField(length: data.count, offset: offset)
        offset += data.count
        return field
    }

    private static func append(field: MessageField, to data: inout Data) {
        data.appendLittleEndianUInt16(UInt16(field.length))
        data.appendLittleEndianUInt16(UInt16(field.length))
        data.appendLittleEndianUInt32(UInt32(field.offset))
    }

    private static func readData(_ data: Data, at offset: Int, count: Int) throws -> Data {
        guard offset <= data.count, count <= data.count - offset else {
            throw RDPCredSSPError.ntlm("truncated NTLM message")
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        return data.subdata(in: start ..< data.index(start, offsetBy: count))
    }

    static func utf16LittleEndian(_ value: String) -> Data {
        var data = Data()
        for codeUnit in value.utf16 {
            data.appendLittleEndianUInt16(codeUnit)
        }
        return data
    }

    /// RFC 1320 MD4, which NTOWFv2 needs and CryptoKit does not provide.
    static func md4(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> shift))
        }

        var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476]
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let words = (0 ..< 16).map { index in
                let offset = chunkStart + index * 4
                return UInt32(message[offset])
                    | UInt32(message[offset + 1]) << 8
                    | UInt32(message[offset + 2]) << 16
                    | UInt32(message[offset + 3]) << 24
            }
            var working = state
            for round in MD4Round.all {
                for step in 0 ..< 16 {
                    // Steps update A, D, C, B in turn; the other three words follow in that cycle.
                    let target = (4 - step % 4) % 4
                    let mixed = round.function(
                        working[(target + 1) % 4],
                        working[(target + 2) % 4],
                        working[(target + 3) % 4]
                    )
                    let sum = working[target] &+ mixed &+ words[round.wordOrder[step]] &+ round.constant
                    let shift = round.shifts[step % 4]
                    working[target] = sum << shift | sum >> (32 - shift)
                }
            }
            for index in 0 ..< 4 {
                state[index] &+= working[index]
            }
        }

        var digest = Data()
        for word in state {
            digest.appendLittleEndianUInt32(word)
        }
        return digest
    }

    private struct MD4Round {
        var function: @Sendable (UInt32, UInt32, UInt32) -> UInt32
        var constant: UInt32
        var wordOrder: [Int]
        var shifts: [Int]

        static let all = [
            MD4Round(
                function: { x, y, z in (x & y) | (~x & z) },
                constant: 0,
                wordOrder: Array(0 ..< 16),
                shifts: [3, 7, 11, 19]
            ),
            MD4Round(
                function: { x, y, z in (x & y) | (x & z) | (y & z) },
                constant: 0x5A82_7999,
                wordOrder: [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15],
                shifts: [3, 5, 9, 13]
            ),
            MD4Round(
                function: { x, y, z in x ^ y ^ z },
                constant: 0x6ED9_EBA1,
                wordOrder: [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15],
                shifts: [3, 9, 11, 15]
            ),
        ]
    }

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func hmacMD5(key: Data, data: Data) -> Data {
        Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw RDPCredSSPError.ntlm("failed to generate random bytes: \(status)")
        }
        return Data(bytes)
    }

    private static func nowFileTime() -> UInt64 {
        let windowsEpochOffset: TimeInterval = 11_644_473_600
        return UInt64((Date().timeIntervalSince1970 + windowsEpochOffset) * 10_000_000)
    }

    private static let signatureBytes = Data("NTLMSSP\u{0}".utf8)
    private static let challengeSize = 8
    private static let hashSize = 16
    private static let signatureSize = 16
    private static let micSize = 16
    private static let authenticatePayloadOffset = 88
    private static let micRange = 72 ..< 88
    private static let version = Data([0x06, 0x01, 0xB1, 0x1D, 0x00, 0x00, 0x00, 0x0F])
    private static let clientSigningMagic = Data("session key to client-to-server signing key magic constant\u{0}".utf8)
    private static let serverSigningMagic = Data("session key to server-to-client signing key magic constant\u{0}".utf8)
    private static let clientSealingMagic = Data("session key to client-to-server sealing key magic constant\u{0}".utf8)
    private static let serverSealingMagic = Data("session key to server-to-client sealing key magic constant\u{0}".utf8)

    private static let negotiateUnicode: UInt32 = 0x0000_0001
    private static let negotiateOEM: UInt32 = 0x0000_0002
    private static let negotiateRequestTarget: UInt32 = 0x0000_0004
    private static let negotiateSign: UInt32 = 0x0000_0010
    private static let negotiateSeal: UInt32 = 0x0000_0020
    private static let negotiateLMKey: UInt32 = 0x0000_0080
    private static let negotiateNTLM: UInt32 = 0x0000_0200
    private static let negotiateDomainSupplied: UInt32 = 0x0000_1000
    private static let negotiateAlwaysSign: UInt32 = 0x0000_8000
    private static let negotiateExtendedSessionSecurity: UInt32 = 0x0008_0000
    private static let negotiateTargetInfo: UInt32 = 0x0080_0000
    private static let negotiateVersion: UInt32 = 0x0200_0000
    private static let negotiate128: UInt32 = 0x2000_0000
    private static let negotiateKeyExchange: UInt32 = 0x4000_0000
    private static let negotiate56: UInt32 = 0x8000_0000

    private static let negotiateFlags: UInt32 = negotiate56
        | negotiateOEM
        | negotiate128
        | negotiateAlwaysSign
        | negotiateExtendedSessionSecurity
        | negotiateNTLM
        | negotiateRequestTarget
        | negotiateUnicode
        | negotiateVersion
        | negotiateLMKey
        | negotiateSeal
        | negotiateKeyExchange
        | negotiateSign

    private static let authenticateSupportedFlags: UInt32 = negotiate56
        | negotiate128
        | negotiateAlwaysSign
        | negotiateExtendedSessionSecurity
        | negotiateNTLM
        | negotiateRequestTarget
        | negotiateUnicode
        | negotiateTargetInfo
        | negotiateVersion
        | negotiateSeal
        | negotiateKeyExchange
        | negotiateSign
}

private final class RDPNTLMRC4 {
    private var i = 0
    private var j = 0
    private var state = [UInt8](0 ... 255)

    init(key: Data) {
        precondition(key.isEmpty == false)
        var j = 0
        let keyBytes = [UInt8](key)
        for i in 0 ..< 256 {
            j = (j + Int(state[i]) + Int(keyBytes[i % keyBytes.count])) & 0xFF
            state.swapAt(i, j)
        }
    }

    func process(_ input: Data) -> Data {
        var output = Data()
        output.reserveCapacity(input.count)
        for byte in input {
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            let keyIndex = (Int(state[i]) + Int(state[j])) & 0xFF
            output.append(byte ^ state[keyIndex])
        }
        return output
    }
}
