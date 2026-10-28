import Foundation

/// CHANNEL_PDU_HEADER flags ([MS-RDPBCGR] 2.2.6.1.1).
enum RDPStaticVirtualChannelFlags {
    static let first: UInt32 = 0x0000_0001
    static let last: UInt32 = 0x0000_0002
    static let showProtocol: UInt32 = 0x0000_0010
    static let suspend: UInt32 = 0x0000_0020
    static let resume: UInt32 = 0x0000_0040
    static let shadowPersistent: UInt32 = 0x0000_0080
    static let compressed: UInt32 = 0x0020_0000
    static let atFront: UInt32 = 0x0040_0000
    static let flushed: UInt32 = 0x0080_0000
    static let compressionTypeMask: UInt32 = 0x000F_0000
    static let complete: UInt32 = first | last
    static let flowControl: UInt32 = suspend | resume
    static let compressionFlags: UInt32 = compressed | atFront | flushed | compressionTypeMask
    static let supportedMask: UInt32 = complete
        | showProtocol
        | flowControl
        | shadowPersistent
        | compressionFlags
}

struct RDPStaticVirtualChannelPDU: Equatable, Sendable {
    static let headerByteCount = 8
    /// CHANNEL_CHUNK_LENGTH, the chunk size used unless the server advertises a
    /// larger VCChunkSize ([MS-RDPBCGR] 2.2.7.1.10, 3.1.5.2.1).
    static let defaultChunkByteCount = 1_600
    static let maximumNegotiatedChunkByteCount = 16_256
    static let maximumPayloadByteCount = defaultChunkByteCount

    var totalLength: UInt32
    var flags: UInt32
    var payload: Data

    init(
        payload: Data,
        flags: UInt32 = RDPStaticVirtualChannelFlags.complete
    ) {
        precondition(payload.count <= Self.maximumPayloadByteCount)

        totalLength = UInt32(payload.count)
        self.flags = flags
        self.payload = payload
    }

    fileprivate init(totalLength: UInt32, flags: UInt32, payload: Data) {
        self.totalLength = totalLength
        self.flags = flags
        self.payload = payload
    }

    fileprivate var isFirst: Bool {
        flags & RDPStaticVirtualChannelFlags.first != 0
    }

    fileprivate var isLast: Bool {
        flags & RDPStaticVirtualChannelFlags.last != 0
    }

    var isComplete: Bool {
        isFirst && isLast && totalLength == payload.count
    }

    /// Data sent without FIRST or LAST outside a chunk sequence is dispatched
    /// as-is ([MS-RDPBCGR] 3.1.5.2.2).
    var isStandalone: Bool {
        !isFirst && !isLast && !isFlowControl && totalLength == payload.count
    }

    var canDispatchPayload: Bool {
        !isFlowControl && (isComplete || isStandalone)
    }

    var isFlowControl: Bool {
        flags & RDPStaticVirtualChannelFlags.flowControl != 0
    }

    static func canEncodeSinglePayload(_ payload: Data) -> Bool {
        payload.count <= maximumPayloadByteCount
    }

    func encodedUserData() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(totalLength)
        data.appendLittleEndianUInt32(flags)
        data.append(payload)
        return data
    }

    func encodedTPKT(initiator: UInt16, channelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: initiator,
            channelID: channelID,
            userData: encodedUserData()
        ).encodedTPKT()
    }

    static func parseIfPresent(
        fromTPKT packet: Data,
        channelID expectedChannelID: UInt16,
        maximumChunkByteCount: Int = maximumPayloadByteCount
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet),
              indication.channelID == expectedChannelID
        else {
            return nil
        }
        return try parse(
            fromUserData: indication.userData,
            maximumChunkByteCount: maximumChunkByteCount
        )
    }

    static func parse(
        fromUserData userData: Data,
        maximumChunkByteCount: Int = maximumPayloadByteCount
    ) throws -> RDPStaticVirtualChannelPDU {
        guard userData.count >= headerByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(userData)
        let pdu = try RDPStaticVirtualChannelPDU(
            totalLength: cursor.readLittleEndianUInt32(),
            flags: cursor.readLittleEndianUInt32(),
            payload: cursor.readRemainingData()
        )
        // The client advertises no virtual channel compression (VCCAPS_NO_COMPR).
        guard pdu.flags & ~RDPStaticVirtualChannelFlags.supportedMask == 0,
              pdu.flags & RDPStaticVirtualChannelFlags.compressionFlags == 0,
              pdu.payload.count <= maximumChunkByteCount,
              Int(pdu.totalLength) >= pdu.payload.count
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        if pdu.isFirst, pdu.isLast, Int(pdu.totalLength) != pdu.payload.count {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        return pdu
    }
}

/// Reassembles chunked virtual channel data from the FIRST and LAST flags
/// ([MS-RDPBCGR] 3.1.5.2.2.1).
struct RDPStaticVirtualChannelReassembler: Sendable {
    /// Upper bound on a server-declared message length, so a hostile length
    /// cannot make the client buffer an unbounded stream of chunks.
    static let defaultMaximumTotalLength = 64 * 1_024 * 1_024

    private let maximumTotalLength: Int
    private var totalLength: UInt32?
    private var payload = Data()

    init(maximumTotalLength: Int = defaultMaximumTotalLength) {
        self.maximumTotalLength = maximumTotalLength
    }

    mutating func append(
        _ pdu: RDPStaticVirtualChannelPDU,
        maximumChunkByteCount: Int = RDPStaticVirtualChannelPDU.maximumPayloadByteCount
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard pdu.payload.count <= maximumChunkByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        // Suspend/resume carry no channel data; this client does not throttle its sends.
        if pdu.isFlowControl {
            return nil
        }

        if pdu.isFirst {
            guard totalLength == nil else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            if pdu.isLast {
                return pdu
            }
            guard Int(pdu.totalLength) <= maximumTotalLength else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            totalLength = pdu.totalLength
            payload = pdu.payload
            return nil
        }

        guard let expectedTotalLength = totalLength else {
            guard pdu.isStandalone else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            return pdu
        }
        guard pdu.totalLength == expectedTotalLength,
              payload.count + pdu.payload.count <= Int(expectedTotalLength)
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        payload.append(pdu.payload)

        guard pdu.isLast else {
            return nil
        }
        guard payload.count == Int(expectedTotalLength) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        let completePDU = RDPStaticVirtualChannelPDU(
            totalLength: expectedTotalLength,
            flags: RDPStaticVirtualChannelFlags.complete,
            payload: payload
        )
        totalLength = nil
        payload = Data()
        return completePDU
    }
}
