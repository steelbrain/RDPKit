import Foundation

enum RDPStaticVirtualChannelFlags {
    static let first: UInt32 = 0x0000_0001
    static let last: UInt32 = 0x0000_0002
    static let showProtocol: UInt32 = 0x0000_0010
    static let suspend: UInt32 = 0x0000_0020
    static let resume: UInt32 = 0x0000_0040
    static let compressed: UInt32 = 0x0020_0000
    static let atFront: UInt32 = 0x0040_0000
    static let flushed: UInt32 = 0x0080_0000
    static let compressionTypeMask: UInt32 = 0x000F_0000
    static let complete: UInt32 = first | last
    static let completeWithShowProtocol: UInt32 = complete | showProtocol
    static let compressionFlags: UInt32 = compressed | atFront | flushed | compressionTypeMask
    static let shadowPersistent: UInt32 = 0x0000_0080
    static let supportedMask: UInt32 = complete
        | showProtocol
        | suspend
        | resume
        | shadowPersistent
        | compressionFlags
}

struct RDPStaticVirtualChannelPDU: Equatable, Sendable {
    static let headerByteCount = 8
    static let defaultChunkByteCount = 1_600
    static let maximumNegotiatedChunkByteCount = 16_256
    static let maximumPayloadByteCount = min(
        defaultChunkByteCount,
        MCSSendDataRequestPDU.maximumUserDataByteCount - headerByteCount
    )

    var totalLength: UInt32
    var flags: UInt32
    var payload: Data

    init(
        payload: Data,
        flags: UInt32 = RDPStaticVirtualChannelFlags.complete
    ) {
        precondition(payload.count <= Int(UInt32.max))
        precondition(payload.count <= Self.maximumPayloadByteCount)

        totalLength = UInt32(payload.count)
        self.flags = flags
        self.payload = payload
    }

    var isComplete: Bool {
        flags & RDPStaticVirtualChannelFlags.first != 0
            && flags & RDPStaticVirtualChannelFlags.last != 0
            && totalLength == payload.count
    }

    var isStandalone: Bool {
        flags & RDPStaticVirtualChannelFlags.first == 0
            && flags & RDPStaticVirtualChannelFlags.last == 0
            && totalLength == payload.count
            && !isFlowControl
    }

    var canDispatchPayload: Bool {
        isComplete || isStandalone
    }

    var isFlowControl: Bool {
        let flowControlFlags = RDPStaticVirtualChannelFlags.suspend | RDPStaticVirtualChannelFlags.resume
        return flags & flowControlFlags != 0
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
        maximumChunkByteCount: Int = maximumPayloadByteCount,
        requiresShowProtocol: Bool = true
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.channelID == expectedChannelID else {
            return nil
        }
        return try parse(
            fromUserData: indication.userData,
            maximumChunkByteCount: maximumChunkByteCount,
            requiresShowProtocol: requiresShowProtocol
        )
    }

    static func parse(
        fromUserData userData: Data,
        maximumChunkByteCount: Int = maximumPayloadByteCount,
        requiresShowProtocol: Bool = true
    ) throws -> RDPStaticVirtualChannelPDU {
        guard userData.count >= 8 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard isValidChunkByteCount(maximumChunkByteCount) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(userData)
        let totalLength = try cursor.readLittleEndianUInt32()
        let flags = try cursor.readLittleEndianUInt32()
        let payload = cursor.readRemainingData()
        guard flags & ~RDPStaticVirtualChannelFlags.supportedMask == 0 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard flags & RDPStaticVirtualChannelFlags.compressionFlags == 0 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard payload.count <= maximumChunkByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard payload.count <= Int(UInt32.max), totalLength >= UInt32(payload.count) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        let hasFirst = flags & RDPStaticVirtualChannelFlags.first != 0
        let hasLast = flags & RDPStaticVirtualChannelFlags.last != 0
        let hasShowProtocol = flags & RDPStaticVirtualChannelFlags.showProtocol != 0
        let flowControlFlags = RDPStaticVirtualChannelFlags.suspend | RDPStaticVirtualChannelFlags.resume
        let flowControl = flags & flowControlFlags
        let isFlowControl = flowControl != 0
        if isFlowControl {
            let validFlowControlMask = flowControlFlags | RDPStaticVirtualChannelFlags.shadowPersistent
            guard (flowControl == RDPStaticVirtualChannelFlags.suspend
                || flowControl == RDPStaticVirtualChannelFlags.resume),
                flags & ~validFlowControlMask == 0,
                totalLength == 0,
                payload.isEmpty
            else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        }
        if hasFirst && hasLast {
            guard totalLength == UInt32(payload.count) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        } else if isFlowControl {
            guard totalLength == 0, payload.isEmpty else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        } else if hasShowProtocol {
            // A fragment the sender explicitly marked; the reassembler validates the rest.
        } else if requiresShowProtocol {
            // Strict: without CHANNEL_FLAG_SHOW_PROTOCOL only a standalone PDU is accepted.
            guard hasFirst == false, hasLast == false, totalLength == UInt32(payload.count) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        }
        // Lenient: CHANNEL_FLAG_SHOW_PROTOCOL says the channel PDU header is visible to the
        // endpoint (MS-RDPBCGR 2.2.6.1.1) and mirrors CHANNEL_OPTION_SHOW_PROTOCOL on the channel.
        // It is NOT a precondition for fragmentation. Windows chunks a large write across rdpdr
        // with flags=CHANNEL_FLAG_FIRST alone, and rejecting that here dropped every inbound
        // message bigger than one chunk - before the reassembler ever saw it.

        return RDPStaticVirtualChannelPDU(
            totalLength: totalLength,
            flags: flags,
            payload: payload
        )
    }

    fileprivate init(totalLength: UInt32, flags: UInt32, payload: Data) {
        self.totalLength = totalLength
        self.flags = flags
        self.payload = payload
    }

    /// Split a message into wire chunks (MS-RDPBCGR 3.1.5.2.1).
    ///
    /// A static virtual channel carries at most `chunkByteCount` bytes per PDU, so anything larger -
    /// a file read, a long directory name - must be fragmented. Every chunk repeats the full
    /// message length in `totalLength`; only the first carries CHANNEL_FLAG_FIRST and only the last
    /// CHANNEL_FLAG_LAST, and a message that fits in one chunk carries both.
    static func chunks(forPayload payload: Data, chunkByteCount: Int) -> [RDPStaticVirtualChannelPDU] {
        let limit = max(1, min(chunkByteCount, maximumNegotiatedChunkByteCount))
        let totalLength = UInt32(clamping: payload.count)
        guard payload.isEmpty == false else {
            return [RDPStaticVirtualChannelPDU(
                totalLength: 0, flags: RDPStaticVirtualChannelFlags.complete, payload: Data()
            )]
        }
        var chunks: [RDPStaticVirtualChannelPDU] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            let end = payload.index(index, offsetBy: limit, limitedBy: payload.endIndex) ?? payload.endIndex
            var flags: UInt32 = 0
            if index == payload.startIndex { flags |= RDPStaticVirtualChannelFlags.first }
            if end == payload.endIndex { flags |= RDPStaticVirtualChannelFlags.last }
            chunks.append(RDPStaticVirtualChannelPDU(
                totalLength: totalLength, flags: flags, payload: Data(payload[index ..< end])
            ))
            index = end
        }
        return chunks
    }

    private static func isValidChunkByteCount(_ byteCount: Int) -> Bool {
        byteCount >= defaultChunkByteCount
            && byteCount <= maximumNegotiatedChunkByteCount
            && byteCount <= MCSSendDataRequestPDU.maximumUserDataByteCount - headerByteCount
    }
}

struct RDPStaticVirtualChannelReassembler: Sendable {
    /// Largest message that may be reassembled. Far above anything rdpdr, cliprdr or rdpsnd
    /// legitimately sends, and low enough that a hostile server cannot exhaust memory.
    static let maximumMessageByteCount: UInt32 = 8 * 1_024 * 1_024

    private var totalLength: UInt32?
    private var payload = Data()

    /// Drop any half-assembled message. Called when a fragment is rejected, so one bad PDU cannot
    /// wedge the channel by leaving a message that can never complete.
    mutating func reset() {
        totalLength = nil
        payload = Data()
    }

    mutating func append(
        _ pdu: RDPStaticVirtualChannelPDU,
        maximumChunkByteCount: Int = RDPStaticVirtualChannelPDU.maximumPayloadByteCount,
        requiresShowProtocol: Bool = true
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard pdu.payload.count <= maximumChunkByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        if pdu.isFlowControl {
            return nil
        }
        if pdu.isComplete {
            guard totalLength == nil else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            return pdu
        }
        if pdu.isStandalone {
            guard totalLength == nil else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            return pdu
        }

        let hasFirst = pdu.flags & RDPStaticVirtualChannelFlags.first != 0
        let hasLast = pdu.flags & RDPStaticVirtualChannelFlags.last != 0
        // CHANNEL_FLAG_SHOW_PROTOCOL says the channel PDU header is visible to the endpoint
        // (MS-RDPBCGR 2.2.6.1.1); it is not a precondition for fragmentation. A channel opened
        // without CHANNEL_OPTION_SHOW_PROTOCOL still chunks, and rejecting those fragments drops
        // every large message on it.
        guard requiresShowProtocol == false
            || pdu.flags & RDPStaticVirtualChannelFlags.showProtocol != 0
        else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        if hasFirst {
            // Reject an absurd announced length BEFORE any of it is resident. `totalLength` is
            // chosen entirely by the server, and the accumulated buffer was bounded only against
            // that same number - so a first fragment claiming 4 GiB, followed by chunks that never
            // set LAST, grows until the client is killed.
            guard pdu.totalLength <= Self.maximumMessageByteCount else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            guard totalLength == nil, pdu.totalLength >= UInt32(pdu.payload.count) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            totalLength = pdu.totalLength
            payload = pdu.payload
        } else {
            guard let expectedTotalLength = totalLength,
                  pdu.totalLength == expectedTotalLength else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            payload.append(pdu.payload)
        }

        guard let expectedTotalLength = totalLength,
              payload.count <= Int(expectedTotalLength) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        if hasLast {
            guard payload.count == Int(expectedTotalLength) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            let completePDU = RDPStaticVirtualChannelPDU(
                totalLength: expectedTotalLength,
                flags: requiresShowProtocol
                    ? RDPStaticVirtualChannelFlags.completeWithShowProtocol
                    : RDPStaticVirtualChannelFlags.complete,
                payload: payload
            )
            totalLength = nil
            payload = Data()
            return completePDU
        }

        return nil
    }
}

/// Per-channel inbound reassembly state.
///
/// A reference type so one channel's state is shared by every site that dispatches for it: the
/// rdpdr channel, for instance, is serviced both from the main receive loops and from the
/// connection-finalization path, and a fragment that arrives at one must be visible to the other.
final class RDPStaticVirtualChannelInbound: @unchecked Sendable {
    private let lock = NSLock()
    private var reassembler = RDPStaticVirtualChannelReassembler()

    /// Returns the complete message, or nil while one is still being assembled.
    func accept(
        _ pdu: RDPStaticVirtualChannelPDU,
        maximumChunkByteCount: Int
    ) throws -> RDPStaticVirtualChannelPDU? {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try reassembler.append(
                pdu, maximumChunkByteCount: maximumChunkByteCount, requiresShowProtocol: false
            )
        } catch {
            reassembler.reset()   // never stay wedged on a message that can no longer complete
            throw error
        }
    }
}
