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

    var isFlowControl: Bool {
        flags & RDPStaticVirtualChannelFlags.flowControl != 0
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

    /// `payload` as the MCS Send Data Requests that carry it, split into chunks of at most
    /// `chunkByteCount` bytes with CHANNEL_FLAG_FIRST and CHANNEL_FLAG_LAST marking the ends
    /// ([MS-RDPBCGR] 3.1.5.2.1). `flags` go on every chunk.
    static func encodedTPKTs(
        payload: Data,
        flags: UInt32 = 0,
        chunkByteCount: Int = maximumPayloadByteCount,
        initiator: UInt16,
        channelID: UInt16
    ) -> [Data] {
        precondition((defaultChunkByteCount ... maximumNegotiatedChunkByteCount).contains(chunkByteCount))

        var packets: [Data] = []
        var lowerBound = payload.startIndex
        repeat {
            let upperBound = min(lowerBound + chunkByteCount, payload.endIndex)
            var chunkFlags = flags
            if lowerBound == payload.startIndex {
                chunkFlags |= RDPStaticVirtualChannelFlags.first
            }
            if upperBound == payload.endIndex {
                chunkFlags |= RDPStaticVirtualChannelFlags.last
            }
            packets.append(RDPStaticVirtualChannelPDU(
                totalLength: UInt32(payload.count),
                flags: chunkFlags,
                payload: payload.subdata(in: lowerBound ..< upperBound)
            ).encodedTPKT(initiator: initiator, channelID: channelID))
            lowerBound = upperBound
        } while lowerBound < payload.endIndex
        return packets
    }

    static func parse(
        fromUserData userData: Data,
        maximumChunkByteCount: Int
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

/// The largest chunk the static channels send: CHANNEL_CHUNK_LENGTH until a Demand Active
/// advertises the server's VCChunkSize, which bounds chunks in both directions
/// ([MS-RDPBCGR] 2.2.7.1.10, 3.1.5.2.1). The channel sessions send from other threads.
final class RDPStaticVirtualChannelChunkSize: @unchecked Sendable {
    private let lock = NSLock()
    private var storedByteCount = RDPStaticVirtualChannelPDU.defaultChunkByteCount

    var byteCount: Int {
        get {
            lock.withLock { storedByteCount }
        }
        set {
            lock.withLock { storedByteCount = newValue }
        }
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

    /// Returns the complete message once its last chunk arrives. A FIRST chunk
    /// always starts a new message, and an error drops the partial one, so a
    /// bad chunk costs at most the message it belongs to.
    mutating func append(
        _ pdu: RDPStaticVirtualChannelPDU,
        maximumChunkByteCount: Int
    ) throws -> RDPStaticVirtualChannelPDU? {
        do {
            return try appendChunk(pdu, maximumChunkByteCount: maximumChunkByteCount)
        } catch {
            totalLength = nil
            payload = Data()
            throw error
        }
    }

    private mutating func appendChunk(
        _ pdu: RDPStaticVirtualChannelPDU,
        maximumChunkByteCount: Int
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard pdu.payload.count <= maximumChunkByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        // Suspend/resume carry no channel data; this client does not throttle its sends.
        if pdu.isFlowControl {
            return nil
        }

        if pdu.isFirst {
            totalLength = nil
            payload = Data()
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
