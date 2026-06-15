import Foundation

public struct RDPCapabilitySetSummary: Encodable, Equatable, Sendable {
    public var type: UInt16
    public var name: String
    public var length: UInt16

    public init(type: UInt16, length: UInt16) {
        self.type = type
        name = rdpCapabilityName(type)
        self.length = length
    }
}

struct RDPDemandActivePDU: Equatable, Sendable {
    var channelID: UInt16
    var pduSource: UInt16
    var shareID: UInt32
    var sourceDescriptor: Data
    var capabilitySets: [RDPCapabilitySetSummary]
    var sessionID: UInt32?

    var sourceDescriptorText: String {
        String(data: sourceDescriptor, encoding: .ascii) ?? sourceDescriptor.rdpHexString
    }

    static func parseIfPresent(fromTPKT packet: Data) throws -> RDPDemandActivePDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.userData.count >= 18 else {
            return nil
        }

        var cursor = ByteCursor(indication.userData)
        let totalLength = try cursor.readLittleEndianUInt16()
        let pduType = try cursor.readLittleEndianUInt16()
        let pduSource = try cursor.readLittleEndianUInt16()
        guard pduType & 0x000F == 0x0001, pduType >> 4 == 0x0001 else {
            return nil
        }
        guard totalLength == 0x8000 || Int(totalLength) <= indication.userData.count else {
            throw RDPDecodeError.invalidDemandActivePDU
        }

        let shareID = try cursor.readLittleEndianUInt32()
        let sourceDescriptorLength = try Int(cursor.readLittleEndianUInt16())
        let combinedCapabilitiesLength = try Int(cursor.readLittleEndianUInt16())
        guard sourceDescriptorLength <= cursor.remaining, combinedCapabilitiesLength >= 4 else {
            throw RDPDecodeError.invalidDemandActivePDU
        }

        let sourceDescriptor = try cursor.readData(count: sourceDescriptorLength)
        guard combinedCapabilitiesLength <= cursor.remaining else {
            throw RDPDecodeError.invalidDemandActivePDU
        }

        var capabilityCursor = try ByteCursor(cursor.readData(count: combinedCapabilitiesLength))
        let capabilityCount = try Int(capabilityCursor.readLittleEndianUInt16())
        _ = try capabilityCursor.readLittleEndianUInt16()

        var capabilitySets: [RDPCapabilitySetSummary] = []
        capabilitySets.reserveCapacity(capabilityCount)
        for _ in 0 ..< capabilityCount {
            guard capabilityCursor.remaining >= 4 else {
                throw RDPDecodeError.invalidDemandActivePDU
            }
            let type = try capabilityCursor.readLittleEndianUInt16()
            let length = try capabilityCursor.readLittleEndianUInt16()
            guard length >= 4, Int(length) - 4 <= capabilityCursor.remaining else {
                throw RDPDecodeError.invalidDemandActivePDU
            }
            _ = try capabilityCursor.readData(count: Int(length) - 4)
            capabilitySets.append(RDPCapabilitySetSummary(type: type, length: length))
        }

        let sessionID = cursor.remaining >= 4
            ? try cursor.readLittleEndianUInt32()
            : nil

        return RDPDemandActivePDU(
            channelID: indication.channelID,
            pduSource: pduSource,
            shareID: shareID,
            sourceDescriptor: sourceDescriptor,
            capabilitySets: capabilitySets,
            sessionID: sessionID
        )
    }
}

struct RDPClientConfirmActivePDU: Equatable, Sendable {
    var shareID: UInt32
    var desktopWidth: UInt16
    var desktopHeight: UInt16
    var sourceDescriptor: Data

    init(
        shareID: UInt32,
        desktopWidth: UInt16 = 1280,
        desktopHeight: UInt16 = 720,
        sourceDescriptor: Data = Data("KRDPSwift".utf8)
    ) {
        precondition(!sourceDescriptor.isEmpty)
        precondition(sourceDescriptor.count <= Int(UInt16.max))

        self.shareID = shareID
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.sourceDescriptor = sourceDescriptor
    }

    var capabilitySets: [RDPCapabilitySetSummary] {
        encodedCapabilitySets().map { RDPCapabilitySetSummary(type: $0.type, length: UInt16($0.data.count)) }
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        let capabilities = encodedCapabilitySets()
        let capabilityBytes = capabilities.reduce(into: Data()) { result, capability in
            result.append(capability.data)
        }
        let combinedCapabilitiesLength = 4 + capabilityBytes.count
        let totalLength = 6 + 4 + 2 + 2 + sourceDescriptor.count + combinedCapabilitiesLength

        precondition(totalLength <= Int(UInt16.max))
        precondition(combinedCapabilitiesLength <= Int(UInt16.max))

        var data = Data()
        data.appendLittleEndianUInt16(UInt16(totalLength))
        data.appendLittleEndianUInt16(0x0013)
        data.appendLittleEndianUInt16(userChannelID)
        data.appendLittleEndianUInt32(shareID)
        data.appendLittleEndianUInt16(0x03EA)
        data.appendLittleEndianUInt16(UInt16(sourceDescriptor.count))
        data.appendLittleEndianUInt16(UInt16(combinedCapabilitiesLength))
        data.append(sourceDescriptor)
        data.appendLittleEndianUInt16(UInt16(capabilities.count))
        data.appendLittleEndianUInt16(0)
        data.append(capabilityBytes)
        return data
    }

    func encodedTPKT(userChannelID: UInt16, ioChannelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: userChannelID,
            channelID: ioChannelID,
            userData: encodedPDUData(userChannelID: userChannelID)
        ).encodedTPKT()
    }

    private func encodedCapabilitySets() -> [(type: UInt16, data: Data)] {
        [
            capabilitySet(type: 0x0001, body: generalCapabilitySetBody()),
            capabilitySet(type: 0x0002, body: bitmapCapabilitySetBody()),
            capabilitySet(type: 0x0003, body: orderCapabilitySetBody()),
            capabilitySet(type: 0x0004, body: bitmapCacheCapabilitySetBody()),
            capabilitySet(type: 0x0008, body: pointerCapabilitySetBody()),
            capabilitySet(type: 0x000D, body: inputCapabilitySetBody()),
            capabilitySet(type: 0x000E, body: fontCapabilitySetBody()),
            capabilitySet(type: 0x000F, body: brushCapabilitySetBody()),
            capabilitySet(type: 0x0010, body: glyphCacheCapabilitySetBody()),
            capabilitySet(type: 0x0011, body: offscreenBitmapCacheCapabilitySetBody()),
            capabilitySet(type: 0x0014, body: virtualChannelCapabilitySetBody()),
            capabilitySet(type: 0x000C, body: soundCapabilitySetBody()),
            capabilitySet(type: 0x001A, body: multifragmentUpdateCapabilitySetBody()),
            capabilitySet(type: 0x001B, body: largePointerCapabilitySetBody()),
            capabilitySet(type: 0x001C, body: surfaceCommandsCapabilitySetBody()),
            capabilitySet(type: 0x001D, body: bitmapCodecsCapabilitySetBody()),
            capabilitySet(type: 0x001E, body: frameAcknowledgeCapabilitySetBody()),
        ]
    }

    private func capabilitySet(type: UInt16, body: Data) -> (type: UInt16, data: Data) {
        precondition(body.count + 4 <= Int(UInt16.max))

        var data = Data()
        data.appendLittleEndianUInt16(type)
        data.appendLittleEndianUInt16(UInt16(body.count + 4))
        data.append(body)
        return (type, data)
    }

    private func generalCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0x0006)
        data.appendLittleEndianUInt16(0x0000)
        data.appendLittleEndianUInt16(0x0200)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0x0404)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendUInt8(0)
        data.appendUInt8(0)
        return data
    }

    private func bitmapCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(32)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(desktopWidth)
        data.appendLittleEndianUInt16(desktopHeight)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(1)
        data.appendUInt8(0)
        data.appendUInt8(0x0E)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(0)
        return data
    }

    private func orderCapabilitySetBody() -> Data {
        var data = Data()
        data.append(Data(repeating: 0, count: 16))
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(20)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0x000A)
        data.append(Data(repeating: 0, count: 32))
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        return data
    }

    private func bitmapCacheCapabilitySetBody() -> Data {
        Data(repeating: 0, count: 36)
    }

    private func pointerCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(32)
        data.appendLittleEndianUInt16(32)
        return data
    }

    private func inputCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0x0131)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt32(0x0000_0409)
        data.appendLittleEndianUInt32(4)
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(12)
        data.append(Data(repeating: 0, count: 64))
        return data
    }

    private func fontCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(0)
        return data
    }

    private func brushCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(0)
        return data
    }

    private func glyphCacheCapabilitySetBody() -> Data {
        Data(repeating: 0, count: 48)
    }

    private func offscreenBitmapCacheCapabilitySetBody() -> Data {
        Data(repeating: 0, count: 8)
    }

    private func virtualChannelCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0xFFFF)
        return data
    }

    private func soundCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        return data
    }

    private func multifragmentUpdateCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(0x0080_0000)
        return data
    }

    private func largePointerCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(3)
        return data
    }

    private func surfaceCommandsCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(0)
        data.appendLittleEndianUInt32(0)
        return data
    }

    private func bitmapCodecsCapabilitySetBody() -> Data {
        var data = Data()
        data.appendUInt8(2)
        data.append(remoteFXCodecGUID())
        data.appendUInt8(3)
        data.append(remoteFXClientCapabilityContainer())
        data.append(nsCodecGUID())
        data.appendUInt8(1)
        data.append(nsCodecCapabilitySet())
        return data
    }

    private func remoteFXCodecGUID() -> Data {
        Data([
            0x12, 0x2F, 0x77, 0x76,
            0x72, 0xBD,
            0x63, 0x44,
            0xAF, 0xB3, 0xB7, 0x3C, 0x9C, 0x6F, 0x78, 0x86,
        ])
    }

    private func remoteFXClientCapabilityContainer() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(49)
        data.appendLittleEndianUInt32(49)
        data.appendLittleEndianUInt32(1)
        data.appendLittleEndianUInt32(37)
        data.appendLittleEndianUInt16(0xCBC0)
        data.appendLittleEndianUInt32(8)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(0xCBC1)
        data.appendLittleEndianUInt32(29)
        data.appendUInt8(1)
        data.appendLittleEndianUInt16(0xCFC0)
        data.appendLittleEndianUInt16(2)
        data.appendLittleEndianUInt16(8)
        appendRemoteFXImageCodecCapability(
            to: &data,
            flags: 0,
            entropyAlgorithm: 1
        )
        appendRemoteFXImageCodecCapability(
            to: &data,
            flags: 2,
            entropyAlgorithm: 4
        )
        return data
    }

    private func nsCodecGUID() -> Data {
        Data([
            0xB9, 0x1B, 0x8D, 0xCA,
            0x0F, 0x00,
            0x4F, 0x15,
            0x58, 0x9F, 0xAE, 0x2D, 0x1A, 0x87, 0xE2, 0xD6,
        ])
    }

    private func nsCodecCapabilitySet() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(3)
        data.appendUInt8(1)
        data.appendUInt8(1)
        data.appendUInt8(3)
        return data
    }

    private func appendRemoteFXImageCodecCapability(
        to data: inout Data,
        flags: UInt8,
        entropyAlgorithm: UInt8
    ) {
        data.appendLittleEndianUInt16(0x0100)
        data.appendLittleEndianUInt16(0x0040)
        data.appendUInt8(flags)
        data.appendUInt8(1)
        data.appendUInt8(1)
        data.appendUInt8(entropyAlgorithm)
    }

    private func frameAcknowledgeCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(2)
        return data
    }
}

func rdpCapabilityName(_ type: UInt16) -> String {
    switch type {
    case 0x0001:
        "general"
    case 0x0002:
        "bitmap"
    case 0x0003:
        "order"
    case 0x0004:
        "bitmap-cache"
    case 0x0005:
        "control"
    case 0x0007:
        "activation"
    case 0x0008:
        "pointer"
    case 0x0009:
        "share"
    case 0x000A:
        "color-cache"
    case 0x000C:
        "sound"
    case 0x000D:
        "input"
    case 0x000E:
        "font"
    case 0x000F:
        "brush"
    case 0x0010:
        "glyph-cache"
    case 0x0011:
        "offscreen-cache"
    case 0x0012:
        "bitmap-cache-host-support"
    case 0x0013:
        "bitmap-cache-v2"
    case 0x0014:
        "virtual-channel"
    case 0x001A:
        "multifragment-update"
    case 0x001B:
        "large-pointer"
    case 0x001C:
        "surface-commands"
    case 0x001D:
        "bitmap-codecs"
    case 0x001E:
        "frame-acknowledge"
    default:
        "capability-0x\(String(format: "%04x", type))"
    }
}
