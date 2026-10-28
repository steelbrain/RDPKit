import Foundation
@testable import RDPKit
import Testing

// Helpers shared by the test files: byte parsing, the packets servers send,
// the captured fixtures and state that callbacks share with a test.

// MARK: Bytes

/// The bytes of whitespace-separated hex such as "03 00 00 13". Malformed hex
/// is a test failure, not silently missing bytes.
func hexData(_ value: String, sourceLocation: SourceLocation = #_sourceLocation) -> Data {
    guard let data = Data(rdpHexString: value) else {
        Issue.record("invalid hex: \(value)", sourceLocation: sourceLocation)
        return Data()
    }
    return data
}

extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        let index = startIndex + offset
        return UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndianUInt16(at: offset)) | UInt32(littleEndianUInt16(at: offset + 2)) << 16
    }

    func containsSubsequence(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}

func utf16LittleEndian(_ value: String, nullTerminated: Bool = false) -> Data {
    var data = Data()
    for codeUnit in value.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    if nullTerminated {
        data.appendLittleEndianUInt16(0)
    }
    return data
}

func utf16LENullTerminated(_ value: String) -> Data {
    utf16LittleEndian(value, nullTerminated: true)
}

func berOctetString(_ value: Data) -> Data {
    Data([0x04]) + berLength(value.count) + value
}

func berLength(_ length: Int) -> Data {
    if length < 0x80 {
        return Data([UInt8(length)])
    }
    return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
}

/// The BGRA pixel at (x, y) of a decoded bitmap.
func pixel(atX x: Int, y: Int, data: Data, bytesPerRow: Int) -> [UInt8] {
    let offset = y * bytesPerRow + x * 4
    return Array(data[offset ..< offset + 4])
}

// MARK: Packets

/// A server MCS Send Data Indication ([T.125] 11.33) in X.224 Data and TPKT.
/// The client ignores the initiator, so any user ID will do.
func mcsSendDataIndication(channelID: UInt16, initiator: UInt16 = 1007, flags: UInt8 = 0x70, userData: Data) -> Data {
    var data = Data()
    data.appendUInt8(0x68)
    data.appendBigEndianUInt16(initiator - 1001)
    data.appendBigEndianUInt16(channelID)
    data.appendUInt8(flags)
    data.appendPERLength(userData.count)
    data.append(userData)
    return X224DataTPDU.wrap(data)
}

/// Unwraps a client MCS Send Data Request ([T.125] 11.32) from X.224 Data and TPKT.
func mcsSendDataRequest(fromTPKT packet: Data) throws -> (initiator: UInt16, channelID: UInt16, userData: Data) {
    var cursor = try ByteCursor(X224DataTPDU.unwrap(packet))
    let header = try cursor.readUInt8()
    let initiator = try mcsUserID(fromOffset: cursor.readBigEndianUInt16())
    let channelID = try cursor.readBigEndianUInt16()
    let priority = try cursor.readUInt8()
    let userData = try cursor.readData(count: cursor.readPERLength())
    guard header == 0x64, priority == 0x70, cursor.remaining == 0 else {
        throw RDPDecodeError.invalidMCSSendDataIndication
    }
    return (initiator, channelID, userData)
}

/// A server Share Data PDU ([MS-RDPBCGR] 2.2.8.1.1.1.2) on the I/O channel.
func shareDataPacket(
    type: UInt8,
    pduSource: UInt16 = 1005,
    streamID: UInt8 = 1,
    compressedType: UInt8 = 0,
    compressedLength: UInt16 = 0,
    payload: Data
) -> Data {
    var userData = Data()
    userData.appendLittleEndianUInt16(UInt16(18 + payload.count))
    userData.appendLittleEndianUInt16(0x0017)
    userData.appendLittleEndianUInt16(pduSource)
    userData.appendLittleEndianUInt32(0x0001_0000)
    userData.appendUInt8(0)
    userData.appendUInt8(streamID)
    userData.appendLittleEndianUInt16(UInt16(payload.count + 4))
    userData.appendUInt8(type)
    userData.appendUInt8(compressedType)
    userData.appendLittleEndianUInt16(compressedLength)
    userData.append(payload)
    return mcsSendDataIndication(channelID: 1003, userData: userData)
}

/// A Server Proprietary Certificate ([MS-RDPBCGR] 2.2.1.4.3.1.1) with a 512-bit key.
func proprietaryServerCertificate() -> Data {
    var publicKey = Data()
    publicKey.appendLittleEndianUInt32(0x3141_5352)
    publicKey.appendLittleEndianUInt32(72)
    publicKey.appendLittleEndianUInt32(512)
    publicKey.appendLittleEndianUInt32(63)
    publicKey.appendLittleEndianUInt32(0x0001_0001)
    publicKey.append(Data(repeating: 0xA5, count: 64))
    publicKey.append(Data(repeating: 0, count: 8))

    var certificate = Data()
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt32(1)
    certificate.appendLittleEndianUInt16(0x0006)
    certificate.appendLittleEndianUInt16(UInt16(publicKey.count))
    certificate.append(publicKey)
    certificate.appendLittleEndianUInt16(0x0008)
    certificate.appendLittleEndianUInt16(72)
    certificate.append(Data(repeating: 0x5A, count: 72))
    return certificate
}

/// A fast-path output PDU ([MS-RDPBCGR] 2.2.9.1.2) holding `updates`.
func fastPathPacket(_ updates: [Data]) -> Data {
    fastPathPacket(updates.reduce(into: Data()) { $0.append($1) })
}

func fastPathPacket(_ updates: Data) -> Data {
    let length = 1 + (updates.count + 2 < 0x80 ? 1 : 2) + updates.count
    var data = Data()
    data.appendUInt8(0x00)
    if length < 0x80 {
        data.appendUInt8(UInt8(length))
    } else {
        data.appendUInt8(0x80 | UInt8((length >> 8) & 0x7F))
        data.appendUInt8(UInt8(length & 0xFF))
    }
    data.append(updates)
    return data
}

/// One TS_FP_UPDATE ([MS-RDPBCGR] 2.2.9.1.2.1).
func fastPathUpdate(
    code: UInt8,
    fragmentation: UInt8 = 0,
    compressionFlags: UInt8? = nil,
    payload: Data
) -> Data {
    var data = Data()
    var header = code | (fragmentation << 4)
    if compressionFlags != nil {
        header |= 0x80
    }
    data.appendUInt8(header)
    if let compressionFlags {
        data.appendUInt8(compressionFlags)
    }
    data.appendLittleEndianUInt16(UInt16(payload.count))
    data.append(payload)
    return data
}

/// A TS_FRAME_MARKER surface command ([MS-RDPBCGR] 2.2.9.2.3).
func surfaceFrameMarker(action: UInt16, frameID: UInt32) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(0x0004)
    data.appendLittleEndianUInt16(action)
    data.appendLittleEndianUInt32(frameID)
    return data
}

/// An RDPGFX PDU: RDPGFX_HEADER ([MS-RDPEGFX] 2.2.1.5) and `payload`.
func graphicsMessage(commandID: UInt16, payload: Data) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(commandID)
    data.appendLittleEndianUInt16(0)
    data.appendLittleEndianUInt32(UInt32(8 + payload.count))
    data.append(payload)
    return data
}

/// An RDPGFX_RECT16 ([MS-RDPEGFX] 2.2.1.2).
func rectangleData(_ rect: RDPGFXRect16) -> Data {
    var data = Data()
    data.appendLittleEndianUInt16(rect.left)
    data.appendLittleEndianUInt16(rect.top)
    data.appendLittleEndianUInt16(rect.right)
    data.appendLittleEndianUInt16(rect.bottom)
    return data
}

/// A ClearCodec stream ([MS-RDPEGFX] 2.2.4.1) whose residual layer is one raw BGR run.
func clearCodecRawRegionStream(width: UInt16, height: UInt16, pixels: [UInt8]) -> Data {
    var stream = Data([0x00, 0x00])
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(13 + pixels.count))
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(0)
    stream.appendLittleEndianUInt16(width)
    stream.appendLittleEndianUInt16(height)
    stream.appendLittleEndianUInt32(UInt32(pixels.count))
    stream.appendUInt8(0)
    stream.append(contentsOf: pixels)
    return stream
}

/// A ClearCodec stream with only a bands layer ([MS-RDPEGFX] 2.2.4.1.1.2).
func clearCodecBandsStream(seqNumber: UInt8, bandsData: Data) -> Data {
    var stream = Data([0x00, seqNumber])
    stream.appendLittleEndianUInt32(0)
    stream.appendLittleEndianUInt32(UInt32(bandsData.count))
    stream.appendLittleEndianUInt32(0)
    stream.append(bandsData)
    return stream
}

/// One band two columns wide and three rows tall over a black background:
/// a short vertical bar of two pixels (rows 1-2) in column 0 and of one pixel
/// (row 0) in column 1.
func clearCodecTwoColumnBandsData() -> Data {
    var bandsData = Data()
    bandsData.appendLittleEndianUInt16(0)
    bandsData.appendLittleEndianUInt16(1)
    bandsData.appendLittleEndianUInt16(0)
    bandsData.appendLittleEndianUInt16(2)
    bandsData.append(contentsOf: [0x00, 0x00, 0x00])
    bandsData.appendLittleEndianUInt16(0x0301)
    bandsData.append(contentsOf: [
        0x10, 0x20, 0x30,
        0x40, 0x50, 0x60,
    ])
    bandsData.appendLittleEndianUInt16(0x0100)
    bandsData.append(contentsOf: [
        0x70, 0x80, 0x90,
    ])
    return bandsData
}

// MARK: Captured transcripts

/// A wire transcript captured from a real server (`Fixtures/<name>.json`).
func loadTranscriptFixture(_ name: String) throws -> [RDPWireEvent] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([RDPWireEvent].self, from: Data(contentsOf: url))
}

/// Replays a captured transcript to the client until its first graphics frame.
func replayTranscriptFixture(_ name: String) throws -> (report: RDPConnectionReport, clientPackets: [Data]) {
    let credentials = RDPCredentials(username: "rdp-user", password: "rdp-user")
    let server = try RDPTranscriptReplayServer.start(transcript: loadTranscriptFixture(name), credentials: credentials)
    defer { server.stop() }

    let report = RDPClient().run(configuration: RDPConnectionConfiguration(
        host: "127.0.0.1",
        port: server.port,
        credentials: credentials,
        timeoutSeconds: 10,
        hideCertificateWarnings: true,
        clipboardEnabled: false,
        graphicsCapabilityProfile: .avcThinClient
    ))
    return (report, server.clientPackets.value)
}

// MARK: Test servers

/// The bytes a test server has received from the client, split the way the
/// client splits what it receives: TPKT or fast-path packets, or the DER
/// TSRequests of the CredSSP exchange.
struct ClientByteStream {
    private var bytes = Data()

    mutating func append(_ received: [UInt8]) {
        bytes.append(contentsOf: received)
    }

    mutating func nextPacket() throws -> Data? {
        try take(RDPTransportPacketFraming.packetLength(from: bytes))
    }

    mutating func nextCredSSPMessage() throws -> Data? {
        let bytes = bytes
        return try take(RDPTransportPacketFraming.credSSPMessageLength(readableByteCount: bytes.count) {
            bytes[bytes.startIndex + $0]
        })
    }

    private mutating func take(_ length: Int?) -> Data? {
        guard let length, bytes.count >= length else {
            return nil
        }
        let message = Data(bytes.prefix(length))
        bytes.removeFirst(length)
        return message
    }
}

// MARK: Shared state

/// A value that callbacks on other threads update and the test then reads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        withLock { $0 }
    }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}
