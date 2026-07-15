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
    var serverInputFlags: UInt16?
    var serverVirtualChannelChunkSize: Int?
    var sessionID: UInt32?

    var requestsMinimalBitmapCodecs: Bool {
        capabilitySets.contains(where: { $0.type == RDPCapabilitySetType.bitmapCodecs && $0.length <= 5 })
    }

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
        guard totalLength == 0x8000 || Int(totalLength) == indication.userData.count else {
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
        var serverInputFlags: UInt16?
        var serverVirtualChannelChunkSize: Int?
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
            let capabilityData = try capabilityCursor.readData(count: Int(length) - 4)
            let virtualChannelChunkSize = try parseServerVirtualChannelChunkSize(
                capabilityType: type,
                capabilityData: capabilityData
            )
            if let virtualChannelChunkSize {
                serverVirtualChannelChunkSize = virtualChannelChunkSize
            }
            let inputFlags = try parseServerInputFlags(capabilityType: type, capabilityData: capabilityData)
            if let inputFlags {
                serverInputFlags = inputFlags
            }
            capabilitySets.append(RDPCapabilitySetSummary(type: type, length: length))
        }
        guard capabilityCursor.remaining == 0 else {
            throw RDPDecodeError.invalidDemandActivePDU
        }

        let sessionID: UInt32?
        switch cursor.remaining {
        case 4:
            sessionID = try cursor.readLittleEndianUInt32()
        default:
            throw RDPDecodeError.invalidDemandActivePDU
        }

        return RDPDemandActivePDU(
            channelID: indication.channelID,
            pduSource: pduSource,
            shareID: shareID,
            sourceDescriptor: sourceDescriptor,
            capabilitySets: capabilitySets,
            serverInputFlags: serverInputFlags,
            serverVirtualChannelChunkSize: serverVirtualChannelChunkSize,
            sessionID: sessionID
        )
    }

    private static func parseServerInputFlags(capabilityType: UInt16, capabilityData: Data) throws -> UInt16? {
        guard capabilityType == RDPCapabilitySetType.input else {
            return nil
        }
        guard capabilityData.count == 84 else {
            throw RDPDecodeError.invalidDemandActivePDU
        }
        var cursor = ByteCursor(capabilityData)
        return try cursor.readLittleEndianUInt16()
    }

    private static func parseServerVirtualChannelChunkSize(
        capabilityType: UInt16,
        capabilityData: Data
    ) throws -> Int? {
        guard capabilityType == 0x0014 else {
            return nil
        }
        guard capabilityData.count == 4 || capabilityData.count == 8 else {
            throw RDPDecodeError.invalidDemandActivePDU
        }
        guard capabilityData.count == 8 else {
            return nil
        }

        var cursor = ByteCursor(capabilityData)
        _ = try cursor.readLittleEndianUInt32()
        let chunkSize = try Int(cursor.readLittleEndianUInt32())
        guard chunkSize >= RDPStaticVirtualChannelPDU.defaultChunkByteCount,
              chunkSize <= RDPStaticVirtualChannelPDU.maximumNegotiatedChunkByteCount,
              chunkSize <= MCSSendDataRequestPDU.maximumUserDataByteCount - RDPStaticVirtualChannelPDU.headerByteCount
        else {
            throw RDPDecodeError.invalidDemandActivePDU
        }
        return chunkSize
    }
}

/// MCS server channel ID used in Confirm Active originatorID and as the default
/// Synchronize targetUser ([MS-RDPBCGR] 2.2.1.13.2.1, 3.2.1.6).
enum RDPServerChannelID {
    static let fixed: UInt16 = 0x03EA
}

struct RDPClientConfirmActivePDU: Equatable, Sendable {
    var shareID: UInt32
    var desktopWidth: UInt16
    var desktopHeight: UInt16
    var sourceDescriptor: Data
    var includeActivationControlShareCapabilities: Bool

    init(
        shareID: UInt32,
        desktopWidth: UInt16 = 1280,
        desktopHeight: UInt16 = 720,
        sourceDescriptor: Data = Data("KRDPSwift".utf8),
        includeActivationControlShareCapabilities: Bool = true
    ) {
        precondition(!sourceDescriptor.isEmpty)
        precondition(sourceDescriptor.count <= Int(UInt16.max))

        self.shareID = shareID
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.sourceDescriptor = sourceDescriptor
        self.includeActivationControlShareCapabilities = includeActivationControlShareCapabilities
    }

    var capabilitySets: [RDPCapabilitySetSummary] {
        encodedCapabilitySets().map { RDPCapabilitySetSummary(type: $0.type, length: UInt16($0.data.count)) }
    }

    var multifragmentUpdateMaxRequestSize: Int {
        includeActivationControlShareCapabilities
            ? RDPMultifragmentUpdateCapability.maxRequestSize
            : RDPMultifragmentUpdateCapability.compactMaxRequestSize
    }

    func encodedPDUData(userChannelID: UInt16) -> Data {
        let capabilities = encodedCapabilitySets()
        let capabilityBytes = capabilities.reduce(into: Data()) { result, capability in
            result.append(capability.data)
        }
        let combinedCapabilitiesLength = 4 + capabilityBytes.count
        // MS-RDPBCGR 2.2.8.1.1.1.1: totalLength is the full packet size in bytes
        // including the Share Control Header. 2.2.1.13.2.1 Confirm Active layout:
        // header(6) + shareId(4) + originatorID(2) + lengthSourceDescriptor(2)
        // + lengthCombinedCapabilities(2) + sourceDescriptor + combinedCapabilities.
        // originatorID MUST be the server channel ID 0x03EA (section 2.2.1.13.2.1).
        let totalLength = 6 + 4 + 2 + 2 + 2 + sourceDescriptor.count + combinedCapabilitiesLength

        precondition(totalLength <= Int(UInt16.max))
        precondition(combinedCapabilitiesLength <= Int(UInt16.max))

        var data = Data()
        data.appendLittleEndianUInt16(UInt16(totalLength))
        data.appendLittleEndianUInt16(0x0013)
        data.appendLittleEndianUInt16(userChannelID)
        data.appendLittleEndianUInt32(shareID)
        data.appendLittleEndianUInt16(RDPServerChannelID.fixed)
        data.appendLittleEndianUInt16(UInt16(sourceDescriptor.count))
        data.appendLittleEndianUInt16(UInt16(combinedCapabilitiesLength))
        data.append(sourceDescriptor)
        data.appendLittleEndianUInt16(UInt16(capabilities.count))
        data.appendLittleEndianUInt16(0)
        data.append(capabilityBytes)
        precondition(data.count == totalLength)
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
        // Compact capability list for servers that request minimal bitmap-codecs.
        // Keep every mandatory CAPSET from MS-RDPBCGR 2.2.7.1, using disabled
        // bodies where the corresponding legacy drawing/cache feature is not
        // supported. Optional CAPSETs that upset this server family stay omitted.
        if !includeActivationControlShareCapabilities {
            return [
                capabilitySet(type: RDPCapabilitySetType.general, body: generalCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.bitmap, body: bitmapCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.order, body: orderCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.bitmapCache, body: bitmapCacheCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.pointer, body: pointerCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.input, body: krdpCompatibleInputCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.font, body: fontCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.brush, body: brushCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.glyphCache, body: glyphCacheCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.offscreenCache, body: offscreenBitmapCacheCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.virtualChannel, body: krdpCompatibleVirtualChannelCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.multifragmentUpdate, body: krdpCompatibleMultifragmentUpdateCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.largePointer, body: krdpCompatibleLargePointerCapabilitySetBody()),
                capabilitySet(type: RDPCapabilitySetType.surfaceCommands, body: surfaceCommandsCapabilitySetBody()),
            ]
        }

        var capabilities = [
            capabilitySet(type: RDPCapabilitySetType.general, body: generalCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.bitmap, body: bitmapCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.order, body: orderCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.bitmapCache, body: bitmapCacheCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.pointer, body: pointerCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.input, body: inputCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.font, body: fontCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.brush, body: brushCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.glyphCache, body: glyphCacheCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.offscreenCache, body: offscreenBitmapCacheCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.virtualChannel, body: virtualChannelCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.sound, body: soundCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.multifragmentUpdate, body: multifragmentUpdateCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.largePointer, body: largePointerCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.surfaceCommands, body: surfaceCommandsCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.bitmapCodecs, body: bitmapCodecsCapabilitySetBody()),
            capabilitySet(type: RDPCapabilitySetType.frameAcknowledge, body: frameAcknowledgeCapabilitySetBody()),
        ]
        capabilities.insert(capabilitySet(
            type: RDPCapabilitySetType.activation,
            body: activationCapabilitySetBody()
        ), at: 4)
        capabilities.insert(capabilitySet(
            type: RDPCapabilitySetType.control,
            body: controlCapabilitySetBody()
        ), at: 5)
        capabilities.insert(capabilitySet(
            type: RDPCapabilitySetType.share,
            body: shareCapabilitySetBody()
        ), at: 7)
        return capabilities
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
        data.appendLittleEndianUInt16(RDPGeneralCapability.osMajorTypeOSX)
        data.appendLittleEndianUInt16(0x0000)
        data.appendLittleEndianUInt16(RDPGeneralCapability.protocolVersion)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(RDPGeneralCapability.extraFlags)
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
        data.appendUInt8(RDPBitmapCapability.drawingFlags)
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

    private func activationCapabilitySetBody() -> Data {
        Data(repeating: 0, count: 8)
    }

    private func controlCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(2)
        data.appendLittleEndianUInt16(2)
        return data
    }

    private func pointerCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(32)
        data.appendLittleEndianUInt16(32)
        return data
    }

    private func shareCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(0)
        data.appendLittleEndianUInt16(0)
        return data
    }

    private func krdpCompatibleInputCapabilitySetBody() -> Data {
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

    private func krdpCompatibleVirtualChannelCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(0)
        // MS-RDPBCGR 2.2.7.1.10 constrains VCChunkSize to 1,600...16,256.
        // Advertise the same chunk size this client actually uses on the full
        // capability path instead of the legacy out-of-range 0xFFFF value.
        data.appendLittleEndianUInt32(UInt32(RDPStaticVirtualChannelPDU.maximumPayloadByteCount))
        return data
    }

    private func krdpCompatibleMultifragmentUpdateCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(UInt32(RDPMultifragmentUpdateCapability.compactMaxRequestSize))
        return data
    }

    private func krdpCompatibleLargePointerCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(1)
        return data
    }

    private func inputCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(RDPInputCapability.inputFlags)
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
        data.appendLittleEndianUInt32(UInt32(RDPStaticVirtualChannelPDU.maximumPayloadByteCount))
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
        data.appendLittleEndianUInt32(UInt32(RDPMultifragmentUpdateCapability.maxRequestSize))
        return data
    }

    private func largePointerCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(RDPLargePointerCapability.supportFlags)
        return data
    }

    private func surfaceCommandsCapabilitySetBody() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(RDPSurfaceCommandsCapability.commandFlags)
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
        data.appendLittleEndianUInt32(RDPFrameAcknowledgeCapability.maxUnacknowledgedFrameCount)
        return data
    }
}

private enum RDPCapabilitySetType {
    static let general: UInt16 = 0x0001
    static let bitmap: UInt16 = 0x0002
    static let order: UInt16 = 0x0003
    static let bitmapCache: UInt16 = 0x0004
    static let control: UInt16 = 0x0005
    static let activation: UInt16 = 0x0007
    static let pointer: UInt16 = 0x0008
    static let share: UInt16 = 0x0009
    static let sound: UInt16 = 0x000C
    static let input: UInt16 = 0x000D
    static let font: UInt16 = 0x000E
    static let brush: UInt16 = 0x000F
    static let glyphCache: UInt16 = 0x0010
    static let offscreenCache: UInt16 = 0x0011
    static let virtualChannel: UInt16 = 0x0014
    static let multifragmentUpdate: UInt16 = 0x001A
    static let largePointer: UInt16 = 0x001B
    static let surfaceCommands: UInt16 = 0x001C
    static let bitmapCodecs: UInt16 = 0x001D
    static let frameAcknowledge: UInt16 = 0x001E
}

private enum RDPGeneralCapability {
    static let osMajorTypeOSX: UInt16 = 0x0006
    static let protocolVersion: UInt16 = 0x0200
    static let fastPathOutputSupported: UInt16 = 0x0001
    static let longCredentialsSupported: UInt16 = 0x0004
    static let noBitmapCompressionHeader: UInt16 = 0x0400
    static let extraFlags = fastPathOutputSupported
        | longCredentialsSupported
        | noBitmapCompressionHeader
}

private enum RDPBitmapCapability {
    static let allowDynamicColorFidelity: UInt8 = 0x02
    static let allowColorSubsampling: UInt8 = 0x04
    static let allowSkipAlpha: UInt8 = 0x08
    static let drawingFlags = allowDynamicColorFidelity
        | allowColorSubsampling
        | allowSkipAlpha
}

private enum RDPInputCapability {
    static let scancodes: UInt16 = 0x0001
    static let mouseExtended: UInt16 = 0x0004
    static let unicode: UInt16 = 0x0010
    static let fastPathInput2: UInt16 = 0x0020
    static let mouseHorizontalWheel: UInt16 = 0x0100
    static let inputFlags = scancodes
        | mouseExtended
        | unicode
        | fastPathInput2
        | mouseHorizontalWheel
}

enum RDPMultifragmentUpdateCapability {
    static let compactMaxRequestSize = 0x0001_0000
    static let maxRequestSize = 0x0080_0000
}

private enum RDPLargePointerCapability {
    static let support96x96: UInt16 = 0x0001
    static let support384x384: UInt16 = 0x0002
    static let supportFlags = support96x96 | support384x384
}

private enum RDPSurfaceCommandsCapability {
    static let setSurfaceBits: UInt32 = 0x0000_0002
    static let frameMarker: UInt32 = 0x0000_0010
    static let streamSurfaceBits: UInt32 = 0x0000_0040
    static let commandFlags = setSurfaceBits | frameMarker | streamSurfaceBits
}

private enum RDPFrameAcknowledgeCapability {
    static let maxUnacknowledgedFrameCount: UInt32 = 2
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
