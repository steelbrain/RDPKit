import Foundation

public enum RDPDecodeError: Error, Equatable, CustomStringConvertible {
    case truncated(needed: Int, remaining: Int)
    case invalidTPKTVersion(UInt8)
    case invalidTPKTLength(declared: Int, actual: Int)
    case invalidX224Length(declared: Int, actual: Int)
    case invalidX224Type(UInt8)
    case invalidNegotiationType(UInt8)
    case invalidNegotiationLength(UInt16)
    case invalidX224DataTPDU
    case invalidMCSConnectResponseHeader
    case invalidMCSAttachUserConfirm
    case invalidMCSChannelJoinConfirm
    case invalidMCSSendDataIndication
    case invalidAutoDetectRequest
    case invalidShareControlHeader
    case invalidShareDataHeader
    case invalidDemandActivePDU
    case invalidLicensePDU
    case invalidStaticVirtualChannelPDU
    case invalidDynamicVirtualChannelPDU
    case invalidClipboardPDU
    case invalidAudioPDU
    case invalidRDPGFXPDU
    case invalidCredSSPMessage
    case invalidBERTag(expected: UInt8, actual: UInt8)
    case invalidBERLength
    case invalidUserDataBlockLength(UInt16)

    public var description: String {
        switch self {
        case let .truncated(needed, remaining):
            "truncated input: needed \(needed) bytes, had \(remaining)"
        case let .invalidTPKTVersion(version):
            "invalid TPKT version \(version)"
        case let .invalidTPKTLength(declared, actual):
            "invalid TPKT length \(declared), actual \(actual)"
        case let .invalidX224Length(declared, actual):
            "invalid X.224 length \(declared), actual \(actual)"
        case let .invalidX224Type(type):
            "invalid X.224 TPDU type 0x\(String(type, radix: 16))"
        case let .invalidNegotiationType(type):
            "invalid RDP negotiation type \(type)"
        case let .invalidNegotiationLength(length):
            "invalid RDP negotiation length \(length)"
        case .invalidX224DataTPDU:
            "invalid X.224 Data TPDU"
        case .invalidMCSConnectResponseHeader:
            "invalid MCS Connect Response header"
        case .invalidMCSAttachUserConfirm:
            "invalid MCS Attach User Confirm"
        case .invalidMCSChannelJoinConfirm:
            "invalid MCS Channel Join Confirm"
        case .invalidMCSSendDataIndication:
            "invalid MCS Send Data Indication"
        case .invalidAutoDetectRequest:
            "invalid RDP Auto-Detect Request"
        case .invalidShareControlHeader:
            "invalid RDP Share Control Header"
        case .invalidShareDataHeader:
            "invalid RDP Share Data Header"
        case .invalidDemandActivePDU:
            "invalid RDP Demand Active PDU"
        case .invalidLicensePDU:
            "invalid RDP License PDU"
        case .invalidStaticVirtualChannelPDU:
            "invalid RDP Static Virtual Channel PDU"
        case .invalidDynamicVirtualChannelPDU:
            "invalid RDP Dynamic Virtual Channel PDU"
        case .invalidClipboardPDU:
            "invalid RDP Clipboard PDU"
        case .invalidAudioPDU:
            "invalid RDP Audio PDU"
        case .invalidRDPGFXPDU:
            "invalid RDP Graphics Pipeline PDU"
        case .invalidCredSSPMessage:
            "invalid CredSSP message"
        case let .invalidBERTag(expected, actual):
            "invalid BER tag 0x\(String(actual, radix: 16)), expected 0x\(String(expected, radix: 16))"
        case .invalidBERLength:
            "invalid BER length"
        case let .invalidUserDataBlockLength(length):
            "invalid user data block length \(length)"
        }
    }
}

struct ByteCursor {
    private let bytes: Data
    private var offset = 0

    init(_ data: Data) {
        bytes = data
    }

    var remaining: Int {
        bytes.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[index(at: offset)]
    }

    mutating func readBigEndianUInt16() throws -> UInt16 {
        try require(2)
        let value = UInt16(bytes[index(at: offset)]) << 8
            | UInt16(bytes[index(at: offset + 1)])
        offset += 2
        return value
    }

    mutating func readLittleEndianUInt16() throws -> UInt16 {
        try require(2)
        let value = UInt16(bytes[index(at: offset)])
            | UInt16(bytes[index(at: offset + 1)]) << 8
        offset += 2
        return value
    }

    mutating func readLittleEndianUInt32() throws -> UInt32 {
        try require(4)
        let value = UInt32(bytes[index(at: offset)])
            | UInt32(bytes[index(at: offset + 1)]) << 8
            | UInt32(bytes[index(at: offset + 2)]) << 16
            | UInt32(bytes[index(at: offset + 3)]) << 24
        offset += 4
        return value
    }

    mutating func readLittleEndianUInt64() throws -> UInt64 {
        let low = try readLittleEndianUInt32()
        let high = try readLittleEndianUInt32()
        return UInt64(low) | UInt64(high) << 32
    }

    mutating func readRemainingData() -> Data {
        let data = bytes.subdata(in: index(at: offset) ..< bytes.endIndex)
        offset = bytes.count
        return data
    }

    mutating func readData(count: Int) throws -> Data {
        try require(count)
        defer { offset += count }
        return bytes.subdata(in: index(at: offset) ..< index(at: offset + count))
    }

    private func require(_ count: Int) throws {
        guard remaining >= count else {
            throw RDPDecodeError.truncated(needed: count, remaining: remaining)
        }
    }

    private func index(at offset: Int) -> Data.Index {
        bytes.index(bytes.startIndex, offsetBy: offset)
    }
}

extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendBigEndianUInt16(_ value: UInt16) {
        appendUInt8(UInt8((value >> 8) & 0xFF))
        appendUInt8(UInt8(value & 0xFF))
    }

    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        appendUInt8(UInt8(value & 0xFF))
        appendUInt8(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        appendUInt8(UInt8(value & 0xFF))
        appendUInt8(UInt8((value >> 8) & 0xFF))
        appendUInt8(UInt8((value >> 16) & 0xFF))
        appendUInt8(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLittleEndianUInt64(_ value: UInt64) {
        appendLittleEndianUInt32(UInt32(value & 0xFFFF_FFFF))
        appendLittleEndianUInt32(UInt32((value >> 32) & 0xFFFF_FFFF))
    }
}

extension Data {
    var rdpHexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
