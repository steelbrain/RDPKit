import CryptoKit
import Foundation
import Security

struct RDPNTLMStep {
    var outputToken: Data?
    var isComplete: Bool
}

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
        var targetInfo: Data
        var timestamp: UInt64
    }

    private struct MessageField {
        var length: Int
        var offset: Int
    }

    private let credentials: RDPCredentials
    private let randomBytes: (Int) throws -> Data
    private let currentFileTime: () -> UInt64
    private var state: State = .negotiate
    private var negotiateMessage = Data()
    private var sendSigningKey = Data()
    private var receiveSigningKey = Data()
    private var sendSealingKey: RDPNTLMRC4?
    private var receiveSealingKey: RDPNTLMRC4?
    private var sendSequenceNumber: UInt32 = 0
    private var receiveSequenceNumber: UInt32 = 0
    private var negotiatedFlags: UInt32 = 0

    init(
        credentials: RDPCredentials,
        randomBytes: @escaping (Int) throws -> Data = RDPCredSSPNTLMContext.secureRandomData(count:),
        currentFileTime: @escaping () -> UInt64 = RDPCredSSPNTLMContext.nowFileTime
    ) {
        self.credentials = credentials
        self.randomBytes = randomBytes
        self.currentFileTime = currentFileTime
    }

    func initialize(inputToken: Data?) throws -> RDPNTLMStep {
        switch state {
        case .negotiate:
            guard inputToken?.isEmpty != false else {
                throw RDPCredSSPError.ntlm("received a server token before sending NTLM negotiate")
            }
            let token = Self.makeNegotiateMessage()
            negotiateMessage = token
            state = .authenticate
            return RDPNTLMStep(outputToken: token, isComplete: false)

        case .authenticate:
            guard let inputToken, !inputToken.isEmpty else {
                throw RDPCredSSPError.missingToken
            }
            let parsedChallenge = try Self.parseChallengeMessage(inputToken, fallbackFileTime: currentFileTime)
            let token = try makeAuthenticateMessage(for: parsedChallenge)
            state = .final
            return RDPNTLMStep(outputToken: token, isComplete: true)

        case .final:
            throw RDPCredSSPError.ntlm("NTLM authentication is already complete")
        }
    }

    func wrap(_ message: Data) throws -> Data {
        guard state == .final,
              !sendSigningKey.isEmpty,
              let sendSealingKey
        else {
            throw RDPCredSSPError.ntlm("NTLM security context is not complete")
        }

        let sequenceNumber = sendSequenceNumber
        let digest = Self.hmacMD5(
            key: sendSigningKey,
            data: Self.sequenceInput(sequenceNumber: sequenceNumber, data: message)
        )
        let encryptedMessage = sendSealingKey.process(message)
        let checksum = negotiatedFlags & Self.negotiateKeyExchange != 0
            ? sendSealingKey.process(Data(digest.prefix(8)))
            : Data(digest.prefix(8))
        let signature = Self.signature(checksum: checksum, sequenceNumber: sequenceNumber)
        sendSequenceNumber &+= 1
        return signature + encryptedMessage
    }

    func unwrap(_ message: Data) throws -> Data {
        guard state == .final,
              !receiveSigningKey.isEmpty,
              let receiveSealingKey
        else {
            throw RDPCredSSPError.ntlm("NTLM security context is not complete")
        }
        guard message.count >= Self.signatureSize else {
            throw RDPCredSSPError.ntlm("NTLM sealed message is too short")
        }

        let signature = Data(message.prefix(Self.signatureSize))
        let sequenceNumber = try Self.readLittleEndianUInt32(signature, at: 12)
        guard sequenceNumber == receiveSequenceNumber else {
            throw RDPCredSSPError.ntlm(
                "unexpected NTLM sequence number \(sequenceNumber), expected \(receiveSequenceNumber)"
            )
        }

        let encryptedMessage = Data(message.dropFirst(Self.signatureSize))
        let decryptedMessage = receiveSealingKey.process(encryptedMessage)
        let digest = Self.hmacMD5(
            key: receiveSigningKey,
            data: Self.sequenceInput(sequenceNumber: sequenceNumber, data: decryptedMessage)
        )
        let checksum = negotiatedFlags & Self.negotiateKeyExchange != 0
            ? receiveSealingKey.process(Data(digest.prefix(8)))
            : Data(digest.prefix(8))
        let expectedSignature = Self.signature(checksum: checksum, sequenceNumber: sequenceNumber)
        guard signature == expectedSignature else {
            throw RDPCredSSPError.serverBindingMismatch
        }

        receiveSequenceNumber &+= 1
        return decryptedMessage
    }

    private func makeAuthenticateMessage(for challenge: Challenge) throws -> Data {
        let clientChallenge = try randomBytes(Self.challengeSize)
        let ntlmV2Hash = Self.ntlmV2Hash(credentials: credentials)
        let authenticateTargetInfo = try Self.authenticateTargetInfo(from: challenge.targetInfo)
        let lmChallengeResponse = Self.lmV2Response(
            serverChallenge: challenge.serverChallenge,
            clientChallenge: clientChallenge,
            ntlmV2Hash: ntlmV2Hash
        )
        let ntChallenge = Self.ntlmV2Response(
            serverChallenge: challenge.serverChallenge,
            clientChallenge: clientChallenge,
            targetInfo: authenticateTargetInfo,
            timestamp: challenge.timestamp,
            ntlmV2Hash: ntlmV2Hash
        )

        negotiatedFlags = Self.authenticateFlags(from: challenge.flags, credentials: credentials)
        let exportedSessionKey: Data
        let encryptedRandomSessionKey: Data
        if negotiatedFlags & Self.negotiateKeyExchange != 0 {
            exportedSessionKey = try randomBytes(Self.hashSize)
            encryptedRandomSessionKey = RDPNTLMRC4(key: ntChallenge.keyExchangeKey).process(exportedSessionKey)
        } else {
            exportedSessionKey = ntChallenge.keyExchangeKey
            encryptedRandomSessionKey = Data()
        }

        let domain = Self.utf16LittleEndian(credentials.domain ?? "")
        let username = Self.utf16LittleEndian(credentials.username)
        let workstation = Data()
        var payloadOffset = Self.authenticatePayloadOffset
        let domainField = Self.messageField(for: domain, offset: &payloadOffset)
        let usernameField = Self.messageField(for: username, offset: &payloadOffset)
        let workstationField = Self.messageField(for: workstation, offset: &payloadOffset)
        let lmField = Self.messageField(for: lmChallengeResponse, offset: &payloadOffset)
        let ntField = Self.messageField(for: ntChallenge.response, offset: &payloadOffset)
        let encryptedKeyField = Self.messageField(for: encryptedRandomSessionKey, offset: &payloadOffset)

        var message = Data()
        message.append(Self.signatureBytes)
        message.appendLittleEndianUInt32(3)
        Self.append(field: lmField, to: &message)
        Self.append(field: ntField, to: &message)
        Self.append(field: domainField, to: &message)
        Self.append(field: usernameField, to: &message)
        Self.append(field: workstationField, to: &message)
        Self.append(field: encryptedKeyField, to: &message)
        message.appendLittleEndianUInt32(negotiatedFlags)
        message.append(Self.version)
        message.append(Data(repeating: 0, count: Self.micSize))
        message.append(domain)
        message.append(username)
        message.append(workstation)
        message.append(lmChallengeResponse)
        message.append(ntChallenge.response)
        message.append(encryptedRandomSessionKey)

        let mic = Self.hmacMD5(key: exportedSessionKey, data: negotiateMessage + challenge.message + message)
        message.replaceSubrange(Self.micRange, with: mic)
        installKeys(exportedSessionKey: exportedSessionKey)
        return message
    }

    private func installKeys(exportedSessionKey: Data) {
        sendSigningKey = Self.md5(exportedSessionKey + Self.clientSigningMagic)
        receiveSigningKey = Self.md5(exportedSessionKey + Self.serverSigningMagic)
        sendSealingKey = RDPNTLMRC4(key: Self.md5(exportedSessionKey + Self.clientSealingMagic))
        receiveSealingKey = RDPNTLMRC4(key: Self.md5(exportedSessionKey + Self.serverSealingMagic))
    }

    private static func makeNegotiateMessage() -> Data {
        var message = Data()
        message.append(signatureBytes)
        message.appendLittleEndianUInt32(1)
        message.appendLittleEndianUInt32(negotiateFlags)
        append(field: MessageField(length: 0, offset: negotiatePayloadOffset), to: &message)
        append(field: MessageField(length: 0, offset: negotiatePayloadOffset), to: &message)
        message.append(version)
        return message
    }

    private static func parseChallengeMessage(
        _ message: Data,
        fallbackFileTime: () -> UInt64
    ) throws -> Challenge {
        guard message.count >= 48,
              message.prefix(signatureBytes.count) == signatureBytes,
              try readLittleEndianUInt32(message, at: 8) == 2
        else {
            throw RDPCredSSPError.ntlm("invalid NTLM challenge message")
        }

        let flags = try readLittleEndianUInt32(message, at: 20)
        let serverChallenge = try readData(message, at: 24, count: challengeSize)
        let targetInfo = try readSecurityBuffer(message, at: 40)
        return Challenge(
            message: message,
            flags: flags,
            serverChallenge: serverChallenge,
            targetInfo: targetInfo,
            timestamp: try timestamp(from: targetInfo) ?? fallbackFileTime()
        )
    }

    private static func timestamp(from targetInfo: Data) throws -> UInt64? {
        var cursor = ByteCursor(targetInfo)
        while cursor.remaining >= 4 {
            let avID = try cursor.readLittleEndianUInt16()
            let length = Int(try cursor.readLittleEndianUInt16())
            if avID == 0 {
                return nil
            }
            let value = try cursor.readData(count: length)
            if avID == 7 {
                guard value.count == 8 else {
                    throw RDPCredSSPError.ntlm("invalid NTLM timestamp AV pair")
                }
                return try readLittleEndianUInt64(value, at: 0)
            }
        }
        guard cursor.remaining == 0 else {
            throw RDPCredSSPError.ntlm("truncated NTLM target info")
        }
        return nil
    }

    private static func authenticateTargetInfo(from targetInfo: Data) throws -> Data {
        var cursor = ByteCursor(targetInfo)
        var output = Data()
        while cursor.remaining >= 4 {
            let avID = try cursor.readLittleEndianUInt16()
            let length = Int(try cursor.readLittleEndianUInt16())
            if avID == 0 {
                break
            }
            let value = try cursor.readData(count: length)
            output.appendLittleEndianUInt16(avID)
            output.appendLittleEndianUInt16(UInt16(length))
            output.append(value)
        }
        output.appendLittleEndianUInt16(6)
        output.appendLittleEndianUInt16(4)
        output.appendLittleEndianUInt32(0x0000_0002)
        output.appendLittleEndianUInt16(0)
        output.appendLittleEndianUInt16(0)
        output.appendLittleEndianUInt32(0)
        return output
    }

    private static func ntlmV2Hash(credentials: RDPCredentials) -> Data {
        let ntHash = md4(utf16LittleEndian(credentials.password))
        let identity = utf16LittleEndian(credentials.username.uppercased() + (credentials.domain ?? ""))
        return hmacMD5(key: ntHash, data: identity)
    }

    private static func lmV2Response(
        serverChallenge: Data,
        clientChallenge: Data,
        ntlmV2Hash: Data
    ) -> Data {
        let proof = hmacMD5(key: ntlmV2Hash, data: serverChallenge + clientChallenge)
        return proof + clientChallenge
    }

    private static func ntlmV2Response(
        serverChallenge: Data,
        clientChallenge: Data,
        targetInfo: Data,
        timestamp: UInt64,
        ntlmV2Hash: Data
    ) -> (response: Data, keyExchangeKey: Data) {
        var temp = Data()
        temp.append(0x01)
        temp.append(0x01)
        temp.appendLittleEndianUInt16(0)
        temp.appendLittleEndianUInt32(0)
        temp.appendLittleEndianUInt64(timestamp)
        temp.append(clientChallenge)
        temp.appendLittleEndianUInt32(0)
        temp.append(targetInfo)

        let proof = hmacMD5(key: ntlmV2Hash, data: serverChallenge + temp)
        return (
            response: proof + temp,
            keyExchangeKey: hmacMD5(key: ntlmV2Hash, data: proof)
        )
    }

    private static func authenticateFlags(from challengeFlags: UInt32, credentials: RDPCredentials) -> UInt32 {
        var flags = challengeFlags & negotiateKeyExchange
        if credentials.domain?.isEmpty == false {
            flags |= negotiateDomainSupplied
        }
        flags |= negotiate56
            | negotiate128
            | negotiateAlwaysSign
            | negotiateExtendedSessionSecurity
            | negotiateNTLM
            | negotiateRequestTarget
            | negotiateUnicode
            | negotiateTargetInfo
            | negotiateVersion
            | negotiateSeal
            | negotiateSign
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

    private static func readSecurityBuffer(_ data: Data, at offset: Int) throws -> Data {
        let length = Int(try readLittleEndianUInt16(data, at: offset))
        let bufferOffset = Int(try readLittleEndianUInt32(data, at: offset + 4))
        return try readData(data, at: bufferOffset, count: length)
    }

    private static func readData(_ data: Data, at offset: Int, count: Int) throws -> Data {
        guard offset >= 0,
              count >= 0,
              offset <= data.count,
              count <= data.count - offset
        else {
            throw RDPCredSSPError.ntlm("truncated NTLM message")
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        return data.subdata(in: start ..< data.index(start, offsetBy: count))
    }

    private static func readLittleEndianUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else {
            throw RDPCredSSPError.ntlm("truncated NTLM message")
        }
        return UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw RDPCredSSPError.ntlm("truncated NTLM message")
        }
        return UInt32(data[data.index(data.startIndex, offsetBy: offset)])
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)]) << 24
    }

    private static func readLittleEndianUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        let low = UInt64(try readLittleEndianUInt32(data, at: offset))
        let high = UInt64(try readLittleEndianUInt32(data, at: offset + 4))
        return low | high << 32
    }

    private static func sequenceInput(sequenceNumber: UInt32, data: Data) -> Data {
        var input = Data()
        input.appendLittleEndianUInt32(sequenceNumber)
        input.append(data)
        return input
    }

    private static func signature(checksum: Data, sequenceNumber: UInt32) -> Data {
        var signature = Data()
        signature.appendLittleEndianUInt32(1)
        signature.append(checksum.prefix(8))
        signature.appendLittleEndianUInt32(sequenceNumber)
        return signature
    }

    private static func utf16LittleEndian(_ value: String) -> Data {
        var data = Data()
        for codeUnit in value.utf16 {
            data.appendLittleEndianUInt16(codeUnit)
        }
        return data
    }

    private static func md4(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xEFCD_AB89
        var c: UInt32 = 0x98BA_DCFE
        var d: UInt32 = 0x1032_5476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0 ..< 16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset])
                    | UInt32(message[offset + 1]) << 8
                    | UInt32(message[offset + 2]) << 16
                    | UInt32(message[offset + 3]) << 24
            }

            let originalA = a
            let originalB = b
            let originalC = c
            let originalD = d

            for index in 0 ..< 16 {
                let shift = [3, 7, 11, 19][index % 4]
                switch index % 4 {
                case 0:
                    a = rotateLeft(a &+ f(b, c, d) &+ words[index], by: shift)
                case 1:
                    d = rotateLeft(d &+ f(a, b, c) &+ words[index], by: shift)
                case 2:
                    c = rotateLeft(c &+ f(d, a, b) &+ words[index], by: shift)
                default:
                    b = rotateLeft(b &+ f(c, d, a) &+ words[index], by: shift)
                }
            }

            let round2Order = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
            for index in 0 ..< 16 {
                let shift = [3, 5, 9, 13][index % 4]
                let word = words[round2Order[index]]
                switch index % 4 {
                case 0:
                    a = rotateLeft(a &+ g(b, c, d) &+ word &+ 0x5A82_7999, by: shift)
                case 1:
                    d = rotateLeft(d &+ g(a, b, c) &+ word &+ 0x5A82_7999, by: shift)
                case 2:
                    c = rotateLeft(c &+ g(d, a, b) &+ word &+ 0x5A82_7999, by: shift)
                default:
                    b = rotateLeft(b &+ g(c, d, a) &+ word &+ 0x5A82_7999, by: shift)
                }
            }

            let round3Order = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
            for index in 0 ..< 16 {
                let shift = [3, 9, 11, 15][index % 4]
                let word = words[round3Order[index]]
                switch index % 4 {
                case 0:
                    a = rotateLeft(a &+ h(b, c, d) &+ word &+ 0x6ED9_EBA1, by: shift)
                case 1:
                    d = rotateLeft(d &+ h(a, b, c) &+ word &+ 0x6ED9_EBA1, by: shift)
                case 2:
                    c = rotateLeft(c &+ h(d, a, b) &+ word &+ 0x6ED9_EBA1, by: shift)
                default:
                    b = rotateLeft(b &+ h(c, d, a) &+ word &+ 0x6ED9_EBA1, by: shift)
                }
            }

            a &+= originalA
            b &+= originalB
            c &+= originalC
            d &+= originalD
        }

        var digest = Data()
        digest.appendLittleEndianUInt32(a)
        digest.appendLittleEndianUInt32(b)
        digest.appendLittleEndianUInt32(c)
        digest.appendLittleEndianUInt32(d)
        return digest
    }

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func hmacMD5(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key))
    }

    private static func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (~x & z)
    }

    private static func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (x & z) | (y & z)
    }

    private static func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        x ^ y ^ z
    }

    private static func rotateLeft(_ value: UInt32, by shift: Int) -> UInt32 {
        (value << UInt32(shift)) | (value >> UInt32(32 - shift))
    }

    private static func secureRandomData(count: Int) throws -> Data {
        guard count > 0 else {
            return Data()
        }
        var data = Data(repeating: 0, count: count)
        let status = try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw RDPCredSSPError.ntlm("failed to allocate random byte buffer")
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw RDPCredSSPError.ntlm("failed to generate random bytes: \(status)")
        }
        return data
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
    private static let negotiatePayloadOffset = 0
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
