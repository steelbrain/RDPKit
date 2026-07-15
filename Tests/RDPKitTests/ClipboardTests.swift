import Foundation
@testable import RDPKit
import Testing

@Test func clipboardCapabilitiesEncodeLongFormatNamesAndFileStreaming() {
    #expect(RDPClipboardCapabilitiesPDU().encoded() == hexData("""
    07 00 00 00 10 00 00 00
    01 00 00 00
    01 00 0c 00 02 00 00 00 06 00 00 00
    """))
}

@Test func clipboardCapabilitiesRejectInvalidFlagsAndTrailingData() throws {
    let invalidFlags = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        messageFlags: RDPClipboardMessageFlags.responseOK,
        payload: Data([0x00, 0x00, 0x00, 0x00])
    ).encoded())

    var trailingPayload = Data()
    trailingPayload.appendLittleEndianUInt16(0)
    trailingPayload.appendLittleEndianUInt16(0)
    trailingPayload.appendLittleEndianUInt16(0xBEEF)
    let trailingData = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: trailingPayload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardCapabilitiesPDU.parseIfPresent(from: invalidFlags)
    }
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardCapabilitiesPDU.parseIfPresent(from: trailingData)
    }
}

@Test func clipboardCapabilitiesRejectGeneralCapabilityWithInvalidLength() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(16)
    payload.appendLittleEndianUInt32(2)
    payload.appendLittleEndianUInt32(RDPClipboardCapabilityFlags.useLongFormatNames)
    payload.appendLittleEndianUInt32(0)
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: payload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardCapabilitiesPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardCapabilitiesRejectUnknownCapabilityType() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(0xBEEF)
    payload.appendLittleEndianUInt16(4)
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: payload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardCapabilitiesPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardCapabilitiesTreatVersionAsInformationalAndRejectUnknownFlags() throws {
    let futureVersion = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: clipboardGeneralCapabilityPayload(version: 3)
    ).encoded())
    let unknownFlag = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: clipboardGeneralCapabilityPayload(generalFlags: 0x0000_0040)
    ).encoded())

    let capabilities = try #require(try RDPClipboardCapabilitiesPDU.parseIfPresent(from: futureVersion))
    #expect(capabilities.version == 3)
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardCapabilitiesPDU.parseIfPresent(from: unknownFlag)
    }
}

@Test func clipboardCapabilitiesRejectDuplicateGeneralCapabilitySet() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(2)
    payload.appendLittleEndianUInt16(0)
    for _ in 0 ..< 2 {
        payload.appendLittleEndianUInt16(1)
        payload.appendLittleEndianUInt16(12)
        payload.appendLittleEndianUInt32(2)
        payload.appendLittleEndianUInt32(RDPClipboardCapabilityFlags.useLongFormatNames)
    }
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: payload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardCapabilitiesPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardSessionAdvertisesOnlyServerSupportedClientCapabilities() {
    #expect(RDPClipboardSession.clientGeneralFlags(serverGeneralFlags: 0) == 0)
    #expect(RDPClipboardSession.clientGeneralFlags(
        serverGeneralFlags: RDPClipboardCapabilityFlags.useLongFormatNames
    ) == RDPClipboardCapabilityFlags.useLongFormatNames)
    #expect(RDPClipboardSession.clientGeneralFlags(
        serverGeneralFlags: RDPClipboardCapabilityFlags.supportedMask
    ) == RDPClipboardCapabilitiesPDU.defaultGeneralFlags)
}

@Test func clipboardPDUParsesHeaderAndPayload() throws {
    let pdu = try RDPClipboardPDU.parse(from: hexData("""
    04 00 00 00 04 00 00 00 0d 00 00 00
    """))

    #expect(pdu.header.messageType == RDPClipboardMessageType.formatDataRequest)
    #expect(pdu.header.messageFlags == 0)
    #expect(pdu.header.dataLength == 4)
    #expect(pdu.payload == Data([0x0D, 0x00, 0x00, 0x00]))
}

@Test func clipboardPDUIgnoresWindowsTrailingBytesNotCountedInDataLen() throws {
    let pdu = try RDPClipboardPDU.parse(from: hexData("""
    04 00 00 00 04 00 00 00
    0d 00 00 00
    de ad be ef
    """))

    #expect(pdu.header.messageType == RDPClipboardMessageType.formatDataRequest)
    #expect(pdu.header.dataLength == 4)
    #expect(pdu.payload == Data([0x0D, 0x00, 0x00, 0x00]))
    #expect(pdu.encoded() == hexData("""
    04 00 00 00 04 00 00 00 0d 00 00 00
    """))
}

@Test func clipboardPDURejectsUndocumentedTrailingByteCount() {
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardPDU.parse(from: hexData("""
        04 00 00 00 04 00 00 00
        0d 00 00 00
        de ad be
        """))
    }
}

@Test func clipboardUnicodeFormatListEncodesLongFormatNameEntry() {
    #expect(RDPClipboardFormatListPDU.unicodeText().encoded() == hexData("""
    02 00 00 00 06 00 00 00 0d 00 00 00 00 00
    """))
}

@Test func clipboardFormatListEncodesShortNamesWhenLongNamesAreNotNegotiated() {
    let list = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(
            formatID: RDPClipboardLocalFormatID.fileContents,
            formatName: RDPClipboardRegisteredFormatName.fileContents
        ),
    ])

    #expect(list.encoded(useLongFormatNames: false) == hexData("""
    02 00 04 00 48 00 00 00
    0d 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    01 c0 00 00
    46 69 6c 65 43 6f 6e 74 65 6e 74 73 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """))
}

@Test func clipboardTemporaryDirectoryEncodesFixedUTF16PathBuffer() throws {
    let encoded = RDPClipboardTemporaryDirectoryPDU(path: "/tmp").encoded()
    let pdu = try RDPClipboardPDU.parse(from: encoded)

    #expect(encoded.count == 528)
    #expect(pdu.typeName == "clipboard-temporary-directory")
    #expect(pdu.header.dataLength == 520)
    #expect(pdu.payload.prefix(10) == Data([
        0x2F, 0x00,
        0x74, 0x00,
        0x6D, 0x00,
        0x70, 0x00,
        0x00, 0x00,
    ]))
    #expect(pdu.payload.dropFirst(10).allSatisfy { $0 == 0 })
}

@Test func clipboardFormatListParsesLongAndShortNameVariants() throws {
    let long = try RDPClipboardPDU.parse(from: hexData("""
    02 00 00 00 06 00 00 00 0d 00 00 00 00 00
    """))
    let short = try RDPClipboardPDU.parse(from: hexData("""
    02 00 04 00 24 00 00 00
    0d 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    """))

    #expect(try RDPClipboardFormatListPDU.parseIfPresent(from: long)?.formatIDs == [13])
    #expect(try RDPClipboardFormatListPDU.parseIfPresent(from: short)?.formatIDs == [13])
    #expect(try RDPClipboardFormatListPDU.parseIfPresent(from: long)?.entries.first?.formatName == nil)
    #expect(try RDPClipboardFormatListPDU.parseIfPresent(from: short)?.entries.first?.formatName == nil)
}

@Test func clipboardFormatListParsesShortUnicodeNamesWhenLongNamesAreNotNegotiated() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(0xC006)
    for codeUnit in "Files".utf16 {
        payload.appendLittleEndianUInt16(codeUnit)
    }
    payload.append(Data(repeating: 0, count: 32 - "Files".utf16.count * 2))
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.formatList,
        payload: payload
    ).encoded())
    let parsed = try #require(try RDPClipboardFormatListPDU.parseIfPresent(
        from: pdu,
        useLongFormatNames: false
    ))

    #expect(parsed.entries == [
        RDPClipboardFormatListEntry(formatID: 0xC006, formatName: "Files"),
    ])
}

@Test func clipboardFormatListRoundTripsLongNamedFormats() throws {
    let list = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(
            formatID: 0xC006,
            formatName: RDPClipboardRegisteredFormatName.fileGroupDescriptorW
        ),
        RDPClipboardFormatListEntry(
            formatID: 0xC007,
            formatName: RDPClipboardRegisteredFormatName.fileContents
        ),
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ])
    let pdu = try RDPClipboardPDU.parse(from: list.encoded())
    let parsed = try #require(try RDPClipboardFormatListPDU.parseIfPresent(from: pdu))

    #expect(parsed.entries == list.entries)
    #expect(parsed.formatIDs == [0xC006, 0xC007, RDPClipboardFormatID.unicodeText])
    #expect(parsed.fileGroupDescriptorWFormatID == 0xC006)
    #expect(parsed.fileContentsFormatID == 0xC007)
}

@Test func clipboardFormatListParsesASCIINamedFormats() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(0xC006)
    payload.append(Data(RDPClipboardRegisteredFormatName.fileGroupDescriptorW.utf8))
    payload.append(Data(
        repeating: 0,
        count: 32 - RDPClipboardRegisteredFormatName.fileGroupDescriptorW.utf8.count
    ))
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.formatList,
        messageFlags: RDPClipboardMessageFlags.asciiNames,
        payload: payload
    ).encoded())
    let parsed = try #require(try RDPClipboardFormatListPDU.parseIfPresent(from: pdu))

    #expect(parsed.entries == [
        RDPClipboardFormatListEntry(
            formatID: 0xC006,
            formatName: RDPClipboardRegisteredFormatName.fileGroupDescriptorW
        ),
    ])
    #expect(parsed.fileGroupDescriptorWFormatID == 0xC006)
}

@Test func clipboardFormatListRejectsUnknownFlags() throws {
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.formatList,
        messageFlags: RDPClipboardMessageFlags.asciiNames | RDPClipboardMessageFlags.responseOK,
        payload: Data()
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardFormatListPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardFormatDataRequestParsesRequestedFormat() throws {
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardFormatDataRequestPDU(
        formatID: RDPClipboardFormatID.unicodeText
    ).encoded())
    let request = try #require(try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: pdu))

    #expect(request.formatID == RDPClipboardFormatID.unicodeText)
}

@Test func clipboardFormatDataRequestRejectsNonzeroFlags() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(RDPClipboardFormatID.unicodeText)
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.formatDataRequest,
        messageFlags: RDPClipboardMessageFlags.responseOK,
        payload: payload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardFormatDataResponseRoundTripsUnicodeText() throws {
    let response = RDPClipboardFormatDataResponsePDU.unicodeText("hello")
    let pdu = try RDPClipboardPDU.parse(from: response.encoded())
    let parsed = try #require(try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu))

    #expect(parsed.ok)
    #expect(try parsed.decodedUnicodeText() == "hello")
}

@Test func clipboardFormatDataResponseRejectsInvalidResponseFlags() throws {
    for flags in [
        UInt16(0),
        RDPClipboardMessageFlags.responseOK | RDPClipboardMessageFlags.responseFail,
        RDPClipboardMessageFlags.responseOK | RDPClipboardMessageFlags.asciiNames,
    ] {
        let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatDataResponse,
            messageFlags: flags,
            payload: Data()
        ).encoded())

        #expect(throws: RDPDecodeError.invalidClipboardPDU) {
            try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu)
        }
    }
}

@Test func clipboardFormatDataResponseRejectsOversizedUnicodeText() throws {
    let maximumCodeUnitCount = RDPClipboardLimits.maximumUnicodeTextUTF16CodeUnitCount
    let fittingText = String(repeating: "a", count: maximumCodeUnitCount)
    let fittingResponse = try #require(RDPClipboardFormatDataResponsePDU.unicodeTextIfEncodable(fittingText))

    #expect(RDPClipboardLimits.canPublishUnicodeText(fittingText))
    #expect(RDPStaticVirtualChannelPDU.canEncodeSinglePayload(fittingResponse.encoded()))

    let oversizedText = fittingText + "a"

    #expect(!RDPClipboardLimits.canPublishUnicodeText(oversizedText))
    #expect(RDPClipboardFormatDataResponsePDU.unicodeTextIfEncodable(oversizedText) == nil)
}

@Test func clipboardLockClipDataEncodesAndParsesClipDataID() throws {
    let lock = RDPClipboardLockClipDataPDU(clipDataID: 0xAABB_CCDD)
    let pdu = try RDPClipboardPDU.parse(from: lock.encoded())
    let parsed = try #require(try RDPClipboardLockClipDataPDU.parseIfPresent(from: pdu))

    #expect(pdu.typeName == "clipboard-lock-clipdata")
    #expect(pdu.encoded() == hexData("""
    0a 00 00 00 04 00 00 00 dd cc bb aa
    """))
    #expect(parsed == lock)
}

@Test func clipboardUnlockClipDataEncodesAndParsesClipDataID() throws {
    let unlock = RDPClipboardUnlockClipDataPDU(clipDataID: 0x1122_3344)
    let pdu = try RDPClipboardPDU.parse(from: unlock.encoded())
    let parsed = try #require(try RDPClipboardUnlockClipDataPDU.parseIfPresent(from: pdu))

    #expect(pdu.typeName == "clipboard-unlock-clipdata")
    #expect(pdu.encoded() == hexData("""
    0b 00 00 00 04 00 00 00 44 33 22 11
    """))
    #expect(parsed == unlock)
}

@Test func clipboardLockAndUnlockClipDataRejectInvalidHeadersAndPayloads() throws {
    let invalidLockFlags = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.lockClipdata,
        messageFlags: RDPClipboardMessageFlags.responseOK,
        payload: Data([0x01, 0x00, 0x00, 0x00])
    ).encoded())
    let invalidUnlockFlags = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.unlockClipdata,
        messageFlags: RDPClipboardMessageFlags.responseOK,
        payload: Data([0x01, 0x00, 0x00, 0x00])
    ).encoded())
    let invalidLockPayloadLength = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.lockClipdata,
        payload: Data([0x01, 0x00, 0x00])
    ).encoded())
    let invalidUnlockPayloadLength = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.unlockClipdata,
        payload: Data([0x01, 0x00, 0x00])
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        _ = try RDPClipboardLockClipDataPDU.parseIfPresent(from: invalidLockFlags)
    }
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        _ = try RDPClipboardUnlockClipDataPDU.parseIfPresent(from: invalidUnlockFlags)
    }
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        _ = try RDPClipboardLockClipDataPDU.parseIfPresent(from: invalidLockPayloadLength)
    }
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        _ = try RDPClipboardUnlockClipDataPDU.parseIfPresent(from: invalidUnlockPayloadLength)
    }
}

@Test func clipboardFormatDataResponseRoundTripsFileGroupDescriptor() throws {
    let descriptorList = RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardLocalFile(fileName: "notes.txt", contents: Data([0x01, 0x02])).descriptor,
    ])
    let response = RDPClipboardFormatDataResponsePDU.fileGroupDescriptorW(descriptorList)
    let pdu = try RDPClipboardPDU.parse(from: response.encoded())
    let parsed = try #require(try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu))

    #expect(parsed.ok)
    #expect(try parsed.decodedFileGroupDescriptorW() == descriptorList)
}

@Test func clipboardFileGroupDescriptorParsesFileMetadata() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(2)
    appendFileDescriptor(
        to: &payload,
        flags: RDPClipboardFileDescriptorFlags.attributes
            | RDPClipboardFileDescriptorFlags.fileSize
            | RDPClipboardFileDescriptorFlags.unicode,
        fileAttributes: 0x0000_0020,
        creationTime: 0x0102_0304_0506_0708,
        lastAccessTime: 0x1112_1314_1516_1718,
        lastWriteTime: 0x2122_2324_2526_2728,
        fileSizeHigh: 0x0000_0001,
        fileSizeLow: 0x0000_0002,
        fileName: "notes.txt"
    )
    appendFileDescriptor(
        to: &payload,
        flags: RDPClipboardFileDescriptorFlags.attributes
            | RDPClipboardFileDescriptorFlags.unicode,
        fileAttributes: RDPClipboardFileAttributes.directory,
        fileName: "Folder"
    )
    let response = RDPClipboardFormatDataResponsePDU(ok: true, data: payload)
    let parsed = try response.decodedFileGroupDescriptorW()

    #expect(parsed.descriptors.count == 2)
    #expect(parsed.descriptors[0].fileName == "notes.txt")
    #expect(parsed.descriptors[0].fileAttributes == 0x0000_0020)
    #expect(parsed.descriptors[0].creationTime == 0)
    #expect(parsed.descriptors[0].lastAccessTime == 0)
    #expect(parsed.descriptors[0].lastWriteTime == 0x2122_2324_2526_2728)
    #expect(parsed.descriptors[0].fileSize == 0x0000_0001_0000_0002)
    #expect(parsed.descriptors[0].isDirectory == false)
    #expect(parsed.descriptors[1].fileName == "Folder")
    #expect(parsed.descriptors[1].fileSize == 0)
    #expect(parsed.descriptors[1].isDirectory)
}

@Test func clipboardFileGroupDescriptorRejectsInvalidCount() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(2)
    appendFileDescriptor(to: &payload, fileName: "only-one.txt")

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardFileGroupDescriptorW.parse(from: payload)
    }
}

@Test func clipboardLocalFileGroupDescriptorEncodesFileMetadata() throws {
    let localFile = RDPClipboardLocalFile(
        fileName: "notes.txt",
        contents: Data([0x01, 0x02, 0x03])
    )
    let data = RDPClipboardFileGroupDescriptorW(descriptors: [localFile.descriptor]).encoded()
    let parsed = try RDPClipboardFileGroupDescriptorW.parse(from: data)
    let descriptor = try #require(parsed.descriptors.first)

    #expect(parsed.descriptors.count == 1)
    #expect(descriptor.flags == RDPClipboardFileDescriptorFlags.attributes
        | RDPClipboardFileDescriptorFlags.fileSize
        | RDPClipboardFileDescriptorFlags.unicode)
    #expect(descriptor.fileAttributes == RDPClipboardFileAttributes.archive)
    #expect(descriptor.fileSize == 3)
    #expect(descriptor.fileName == "notes.txt")
    #expect(descriptor.isDirectory == false)
}

@Test func clipboardFileDescriptorEncodesReservedFieldsAsZeros() throws {
    let descriptor = RDPClipboardFileDescriptorW(
        flags: RDPClipboardFileDescriptorFlags.attributes
            | RDPClipboardFileDescriptorFlags.fileSize
            | RDPClipboardFileDescriptorFlags.creationTime
            | RDPClipboardFileDescriptorFlags.lastAccessTime
            | RDPClipboardFileDescriptorFlags.lastWriteTime
            | RDPClipboardFileDescriptorFlags.unicode,
        fileAttributes: RDPClipboardFileAttributes.archive,
        creationTime: 0x0102_0304_0506_0708,
        lastAccessTime: 0x1112_1314_1516_1718,
        lastWriteTime: 0x2122_2324_2526_2728,
        fileSize: 5,
        fileName: "notes.txt"
    )
    let encoded = descriptor.encoded()
    var cursor = ByteCursor(encoded)
    let parsed = try RDPClipboardFileDescriptorW.parse(from: &cursor)

    #expect(encoded[4 ..< 36].allSatisfy { $0 == 0 })
    #expect(encoded[40 ..< 56].allSatisfy { $0 == 0 })
    #expect(encoded[56 ..< 64] == Data([0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21]))
    #expect(parsed.creationTime == 0)
    #expect(parsed.lastAccessTime == 0)
    #expect(parsed.lastWriteTime == 0x2122_2324_2526_2728)
}

@Test func clipboardFileContentsSizeRequestEncodesAndParses() throws {
    let request = RDPClipboardFileContentsRequestPDU.size(
        streamID: 0x1122_3344,
        fileIndex: -2
    )
    let pdu = try RDPClipboardPDU.parse(from: request.encoded())
    let parsed = try #require(try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: pdu))

    #expect(pdu.typeName == "clipboard-file-contents-request")
    #expect(pdu.encoded() == hexData("""
    08 00 00 00 18 00 00 00
    44 33 22 11
    fe ff ff ff
    01 00 00 00
    00 00 00 00 00 00 00 00
    08 00 00 00
    """))
    #expect(parsed == request)
}

@Test func clipboardFileContentsRangeRequestEncodesAndParsesClipDataID() throws {
    let request = RDPClipboardFileContentsRequestPDU.range(
        streamID: 7,
        fileIndex: 3,
        position: 0x0000_0001_0000_0004,
        requestedByteCount: 0x1000,
        clipDataID: 0xAABB_CCDD
    )
    let pdu = try RDPClipboardPDU.parse(from: request.encoded())
    let parsed = try #require(try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: pdu))

    #expect(pdu.encoded() == hexData("""
    08 00 00 00 1c 00 00 00
    07 00 00 00
    03 00 00 00
    02 00 00 00
    04 00 00 00 01 00 00 00
    00 10 00 00
    dd cc bb aa
    """))
    #expect(parsed == request)
}

@Test func clipboardFileContentsRequestRejectsInvalidFlags() {
    let conflictingRequest = RDPClipboardFileContentsRequestPDU(
        streamID: 1,
        fileIndex: 0,
        flags: RDPClipboardFileContentsFlags.size | RDPClipboardFileContentsFlags.range,
        position: 0,
        requestedByteCount: 8
    )
    let unknownFlagRequest = RDPClipboardFileContentsRequestPDU(
        streamID: 1,
        fileIndex: 0,
        flags: RDPClipboardFileContentsFlags.range | 0x0000_0004,
        position: 0,
        requestedByteCount: 8
    )

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try conflictingRequest.encoded()
    }
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try unknownFlagRequest.encoded()
    }
}

@Test func clipboardFileContentsRequestRejectsUnknownParsedFlags() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(1)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(RDPClipboardFileContentsFlags.range | 0x0000_0004)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(8)
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.fileContentsRequest,
        payload: payload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardFileContentsRequestRejectsNonzeroMessageFlags() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(1)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(RDPClipboardFileContentsFlags.size)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(0)
    payload.appendLittleEndianUInt32(8)
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.fileContentsRequest,
        messageFlags: RDPClipboardMessageFlags.responseOK,
        payload: payload
    ).encoded())

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: pdu)
    }
}

@Test func clipboardFileContentsResponseRoundTripsFileSize() throws {
    let response = RDPClipboardFileContentsResponsePDU.fileSize(
        streamID: 0x0102_0304,
        byteCount: 0x0000_0001_0000_0002
    )
    let pdu = try RDPClipboardPDU.parse(from: response.encoded())
    let parsed = try #require(try RDPClipboardFileContentsResponsePDU.parseIfPresent(from: pdu))

    #expect(pdu.typeName == "clipboard-file-contents-response")
    #expect(pdu.encoded() == hexData("""
    09 00 01 00 0c 00 00 00
    04 03 02 01
    02 00 00 00 01 00 00 00
    """))
    #expect(parsed == response)
    #expect(try parsed.decodedFileSize() == 0x0000_0001_0000_0002)
}

@Test func clipboardFileContentsResponseRoundTripsRangeDataAndFailure() throws {
    let rangeResponse = RDPClipboardFileContentsResponsePDU.range(
        streamID: 9,
        data: Data([0x01, 0x02, 0x03])
    )
    let failureResponse = RDPClipboardFileContentsResponsePDU.failure(streamID: 10)

    let parsedRange = try #require(try RDPClipboardFileContentsResponsePDU.parseIfPresent(
        from: RDPClipboardPDU.parse(from: rangeResponse.encoded())
    ))
    let parsedFailure = try #require(try RDPClipboardFileContentsResponsePDU.parseIfPresent(
        from: RDPClipboardPDU.parse(from: failureResponse.encoded())
    ))

    #expect(parsedRange == rangeResponse)
    #expect(parsedFailure == failureResponse)
    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try parsedFailure.decodedFileSize()
    }
}

@Test func clipboardFileContentsResponseRejectsInvalidResponseFlags() throws {
    var payload = Data()
    payload.appendLittleEndianUInt32(1)

    for flags in [
        UInt16(0),
        RDPClipboardMessageFlags.responseOK | RDPClipboardMessageFlags.responseFail,
        RDPClipboardMessageFlags.responseFail | RDPClipboardMessageFlags.asciiNames,
    ] {
        let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
            messageType: RDPClipboardMessageType.fileContentsResponse,
            messageFlags: flags,
            payload: payload
        ).encoded())

        #expect(throws: RDPDecodeError.invalidClipboardPDU) {
            try RDPClipboardFileContentsResponsePDU.parseIfPresent(from: pdu)
        }
    }
}

@Test func clipboardRemoteFileTransferFilesSanitizeAndDeduplicateNames() throws {
    let list = RDPClipboardFileGroupDescriptorW(descriptors: [
        fileDescriptor(fileSize: 3, fileName: "../notes.txt"),
        fileDescriptor(fileSize: 4, fileName: "notes.txt"),
        fileDescriptor(
            fileAttributes: RDPClipboardFileAttributes.directory,
            fileName: "Folder"
        ),
        fileDescriptor(flags: RDPClipboardFileDescriptorFlags.unicode, fileName: "  "),
    ])

    let files = try list.remoteFileTransferFiles(maximumTotalByteCount: 7)

    #expect(files == [
        RDPClipboardRemoteFileTransferFile(fileIndex: 0, fileName: "notes.txt", declaredByteCount: 3),
        RDPClipboardRemoteFileTransferFile(fileIndex: 1, fileName: "notes-2.txt", declaredByteCount: 4),
        RDPClipboardRemoteFileTransferFile(fileIndex: 3, fileName: "remote-file"),
    ])
}

@Test func clipboardRemoteFileTransferFilesRejectInvalidPlans() {
    #expect(throws: RDPClipboardRemoteFileTransferPlanningError.emptyFileList) {
        try RDPClipboardFileGroupDescriptorW(descriptors: []).remoteFileTransferFiles()
    }

    #expect(throws: RDPClipboardRemoteFileTransferPlanningError.containsOnlyDirectories) {
        try RDPClipboardFileGroupDescriptorW(descriptors: [
            fileDescriptor(
                fileAttributes: RDPClipboardFileAttributes.directory,
                fileName: "Folder"
            ),
        ]).remoteFileTransferFiles()
    }

    #expect(throws: RDPClipboardRemoteFileTransferPlanningError.totalByteLimitExceeded) {
        try RDPClipboardFileGroupDescriptorW(descriptors: [
            fileDescriptor(fileSize: 8, fileName: "too-large.bin"),
        ]).remoteFileTransferFiles(maximumTotalByteCount: 7)
    }
}

private func hexData(_ value: String) -> Data {
    let bytes = value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    return Data(bytes)
}

private func clipboardGeneralCapabilityPayload(
    version: UInt32 = 2,
    generalFlags: UInt32 = RDPClipboardCapabilityFlags.useLongFormatNames
) -> Data {
    var payload = Data()
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(1)
    payload.appendLittleEndianUInt16(12)
    payload.appendLittleEndianUInt32(version)
    payload.appendLittleEndianUInt32(generalFlags)
    return payload
}

private func fileDescriptor(
    flags: UInt32 = RDPClipboardFileDescriptorFlags.attributes
        | RDPClipboardFileDescriptorFlags.fileSize
        | RDPClipboardFileDescriptorFlags.unicode,
    fileAttributes: UInt32 = RDPClipboardFileAttributes.archive,
    fileSize: UInt64 = 0,
    fileName: String
) -> RDPClipboardFileDescriptorW {
    RDPClipboardFileDescriptorW(
        flags: flags,
        fileAttributes: fileAttributes,
        fileSize: fileSize,
        fileName: fileName
    )
}

private func appendFileDescriptor(
    to data: inout Data,
    flags: UInt32 = RDPClipboardFileDescriptorFlags.unicode,
    fileAttributes: UInt32 = 0,
    creationTime: UInt64 = 0,
    lastAccessTime: UInt64 = 0,
    lastWriteTime: UInt64 = 0,
    fileSizeHigh: UInt32 = 0,
    fileSizeLow: UInt32 = 0,
    fileName: String
) {
    data.appendLittleEndianUInt32(flags)
    data.append(Data(repeating: 0, count: 32))
    data.appendLittleEndianUInt32(fileAttributes)
    data.appendFileTime(creationTime)
    data.appendFileTime(lastAccessTime)
    data.appendFileTime(lastWriteTime)
    data.appendLittleEndianUInt32(fileSizeHigh)
    data.appendLittleEndianUInt32(fileSizeLow)

    var fileNameCodeUnits = Array(fileName.utf16.prefix(259))
    fileNameCodeUnits.append(0)
    for codeUnit in fileNameCodeUnits {
        data.appendLittleEndianUInt16(codeUnit)
    }
    let paddingCodeUnits = 260 - fileNameCodeUnits.count
    for _ in 0 ..< paddingCodeUnits {
        data.appendLittleEndianUInt16(0)
    }
}

private extension Data {
    mutating func appendFileTime(_ value: UInt64) {
        appendLittleEndianUInt32(UInt32(value & 0xFFFF_FFFF))
        appendLittleEndianUInt32(UInt32((value >> 32) & 0xFFFF_FFFF))
    }
}
