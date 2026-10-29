import CoreGraphics
import Foundation
import NIOCore
import NIOEmbedded
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

@Test func clipboardCapabilitiesSkipUnknownCapabilitySets() throws {
    var payload = Data()
    payload.appendLittleEndianUInt16(2)
    payload.appendLittleEndianUInt16(0)
    payload.appendLittleEndianUInt16(0xBEEF)
    payload.appendLittleEndianUInt16(6)
    payload.appendLittleEndianUInt16(0xAAAA)
    payload.append(clipboardGeneralCapabilityPayload().dropFirst(4))
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: payload
    ).encoded())

    let capabilities = try #require(try RDPClipboardCapabilitiesPDU.parseIfPresent(from: pdu))
    #expect(capabilities.generalFlags == RDPClipboardCapabilityFlags.useLongFormatNames)
}

@Test func clipboardCapabilitiesTreatVersionAsInformationalAndIgnoreUnknownFlags() throws {
    let futureVersion = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: clipboardGeneralCapabilityPayload(version: 3)
    ).encoded())
    let unknownFlag = try RDPClipboardPDU.parse(from: RDPClipboardPDU(
        messageType: RDPClipboardMessageType.clipboardCapabilities,
        payload: clipboardGeneralCapabilityPayload(
            generalFlags: RDPClipboardCapabilityFlags.useLongFormatNames | 0x0000_0040
        )
    ).encoded())

    let capabilities = try #require(try RDPClipboardCapabilitiesPDU.parseIfPresent(from: futureVersion))
    let unknownFlagCapabilities = try #require(try RDPClipboardCapabilitiesPDU.parseIfPresent(from: unknownFlag))
    #expect(capabilities.version == 3)
    #expect(RDPClipboardSession.clientGeneralFlags(
        serverGeneralFlags: unknownFlagCapabilities.generalFlags
    ) == RDPClipboardCapabilityFlags.useLongFormatNames)
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
        serverGeneralFlags: 0x0000_003E
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
    #expect(RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded() == hexData("""
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

    #expect(RDPClipboardLimits.maximumUnicodeTextByteCount == (maximumCodeUnitCount + 1) * 2)
    #expect(RDPClipboardLimits.canPublishUnicodeText(fittingText))

    let oversizedText = fittingText + "a"

    #expect(!RDPClipboardLimits.canPublishUnicodeText(oversizedText))
    #expect(RDPClipboardFormatDataResponsePDU.unicodeTextIfEncodable(oversizedText) == nil)
}

/// CF_UNICODETEXT ends lines with CRLF (Standard Clipboard Formats); Apple text uses LF.
@Test func clipboardUnicodeTextSendsCRLFLineEndsAndDeliversLF() throws {
    let response = RDPClipboardFormatDataResponsePDU.unicodeText("one\ntwo\r\nthree\n")
    var expected = Data()
    for codeUnit in "one\r\ntwo\r\nthree\r\n\0".utf16 {
        expected.appendLittleEndianUInt16(codeUnit)
    }
    let parsed = try #require(try RDPClipboardFormatDataResponsePDU.parseIfPresent(
        from: RDPClipboardPDU.parse(from: response.encoded())
    ))

    #expect(response.data == expected)
    #expect(try parsed.decodedUnicodeText() == "one\ntwo\nthree\n")
}

@Test func clipboardUnicodeTextLimitCountsTheCarriageReturnsAdded() {
    let maximumCodeUnitCount = RDPClipboardLimits.maximumUnicodeTextUTF16CodeUnitCount
    let lineFeeds = String(repeating: "\n", count: maximumCodeUnitCount / 2)

    #expect(RDPClipboardLimits.canPublishUnicodeText(lineFeeds))
    #expect(!RDPClipboardLimits.canPublishUnicodeText(lineFeeds + "\n"))
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
            | RDPClipboardFileDescriptorFlags.lastWriteTime
            | RDPClipboardFileDescriptorFlags.unicode,
        fileAttributes: RDPClipboardFileAttributes.archive,
        lastWriteTime: 0x2122_2324_2526_2728,
        fileSize: 0x0000_0001_0000_0005,
        fileName: "notes.txt"
    )
    let encoded = descriptor.encoded()
    var cursor = ByteCursor(encoded)
    let parsed = try RDPClipboardFileDescriptorW.parse(from: &cursor)

    #expect(encoded.count == RDPClipboardFileDescriptorW.byteCount)
    #expect(encoded[4 ..< 36].allSatisfy { $0 == 0 })
    #expect(encoded[40 ..< 56].allSatisfy { $0 == 0 })
    #expect(encoded[56 ..< 64] == Data([0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21]))
    #expect(encoded[64 ..< 72] == Data([0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00]))
    #expect(parsed == descriptor)
}

/// A name cut to cFileName's 259 code units keeps no half of a surrogate pair.
@Test func clipboardFileDescriptorDoesNotSplitSurrogatePairWhenTruncatingFileName() throws {
    let descriptor = RDPClipboardLocalFile(
        fileName: String(repeating: "a", count: 258) + "\u{1F600}",
        contents: Data()
    ).descriptor
    var cursor = ByteCursor(descriptor.encoded())
    let parsed = try RDPClipboardFileDescriptorW.parse(from: &cursor)

    #expect(parsed.fileName == String(repeating: "a", count: 258))
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

@Test func clipboardFileContentsRangeRequestEncodesAndIgnoresServerClipDataID() throws {
    let request = RDPClipboardFileContentsRequestPDU.range(
        streamID: 7,
        fileIndex: 3,
        position: 0x0000_0001_0000_0004,
        requestedByteCount: 0x1000
    )
    let serverRequestWithClipDataID = try RDPClipboardPDU.parse(from: hexData("""
    08 00 00 00 1c 00 00 00
    07 00 00 00
    03 00 00 00
    02 00 00 00
    04 00 00 00 01 00 00 00
    00 10 00 00
    dd cc bb aa
    """))

    #expect(try request.encoded() == hexData("""
    08 00 00 00 18 00 00 00
    07 00 00 00
    03 00 00 00
    02 00 00 00
    04 00 00 00 01 00 00 00
    00 10 00 00
    """))
    #expect(try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: serverRequestWithClipDataID) == request)
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
    let response = RDPClipboardFileContentsResponse.fileSize(
        streamID: 0x0102_0304,
        byteCount: 0x0000_0001_0000_0002
    )
    let pdu = try RDPClipboardPDU.parse(from: response.encoded())
    let parsed = try #require(try RDPClipboardFileContentsResponse.parseIfPresent(from: pdu))

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
    let rangeResponse = RDPClipboardFileContentsResponse.range(
        streamID: 9,
        data: Data([0x01, 0x02, 0x03])
    )
    let failureResponse = RDPClipboardFileContentsResponse.failure(streamID: 10)

    let parsedRange = try #require(try RDPClipboardFileContentsResponse.parseIfPresent(
        from: RDPClipboardPDU.parse(from: rangeResponse.encoded())
    ))
    let parsedFailure = try #require(try RDPClipboardFileContentsResponse.parseIfPresent(
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
            try RDPClipboardFileContentsResponse.parseIfPresent(from: pdu)
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

@Test func clipboardRemoteFileTransferFilesNeverEscapeTheDownloadDirectory() throws {
    let longName = String(repeating: "\u{3042}", count: 200) + ".txt"
    let list = RDPClipboardFileGroupDescriptorW(descriptors: [
        fileDescriptor(fileName: ".."),
        fileDescriptor(fileName: "."),
        fileDescriptor(fileName: "Folder\\.."),
        fileDescriptor(fileName: "../../"),
        fileDescriptor(fileName: "C:secret.txt"),
        fileDescriptor(fileName: longName),
        fileDescriptor(fileName: longName),
    ])

    let names = try list.remoteFileTransferFiles().map(\.fileName)

    #expect(Array(names.prefix(5)) == ["remote-file", "remote-file-2", "remote-file-3", "remote-file-4", "C_secret.txt"])
    #expect(names[5].utf8.count <= 255)
    #expect(names[5].hasSuffix(".txt"))
    #expect(names[6].utf8.count <= 255)
    #expect(names[6].hasSuffix("-2.txt"))
    #expect(names.allSatisfy { $0 != "." && $0 != ".." && !$0.contains("/") })
}

@Test func clipboardRemoteFileNamesStayUniqueWhenOversizedGraphemesAreCut() throws {
    // One grapheme of 401 UTF-8 bytes fits the 260-unit cFileName but not a 255-byte file name.
    let marks = String(repeating: "\u{301}", count: 200)
    let rawNames = ["..e" + marks, "e" + marks, ".e" + marks, "remote-file", "remote-file"]
    let names = try RDPClipboardFileGroupDescriptorW(descriptors: rawNames.map { fileDescriptor(fileName: $0) })
        .remoteFileTransferFiles()
        .map(\.fileName)

    #expect(Set(names.map { $0.lowercased() }).count == names.count)
    #expect(names.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
    #expect(names[1] == "e" + String(repeating: "\u{301}", count: 127))
    for rawName in rawNames {
        let name = RDPClipboardRemoteFileTransferFile(fileIndex: 0, fileName: rawName).fileName
        #expect(!name.isEmpty && name != "." && name != "..")
    }
}

/// Format characters (Unicode Cf) spell names: ZWNJ in Persian, ZWJ in emoji sequences and
/// Indic scripts, the soft hyphen, bidi marks. Neither side replaces them; this side still
/// replaces control characters, line separators and the bidi controls that reorder a name.
@Test func clipboardFileNamesKeepFormatCharacters() throws {
    let names = [
        "\u{06AF}\u{0632}\u{0627}\u{0631}\u{0634}\u{200C}\u{0647}\u{0627}.pdf",
        "\u{1F469}\u{200D}\u{1F4BB} notes.txt",
        "\u{0915}\u{094D}\u{200D}\u{0937}.txt",
        "co\u{00AD}operate.txt",
        "\u{200F}\u{05E9}\u{05DC}\u{05D5}\u{05DD} (1).txt",
    ]
    let unsafeNames = [
        "tab\tline\nfeed\u{7F}\u{85}\u{9F}\u{2028}.txt",
        "x\u{202E}fdp.command",
        "\u{2067}isolated\u{2069}.txt",
    ]

    let remoteNames = try RDPClipboardFileGroupDescriptorW(descriptors: (names + unsafeNames).map { fileDescriptor(fileName: $0) })
        .remoteFileTransferFiles()
        .map(\.fileName)

    #expect(remoteNames == names + ["tab_line_feed____.txt", "x_fdp.command", "_isolated_.txt"])
    #expect(try fileNamesTheServerSees(publishing: names + unsafeNames.dropFirst()) == names + unsafeNames.dropFirst())
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

@Test func clipboardSessionAnswersMonitorReadyWithCapabilitiesTemporaryDirectoryAndFormatList() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )

    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded())) == nil)
    #expect(try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady)) == .ready)

    #expect(sent.summaries.map(\.typeName) == [
        "clipboard-capabilities",
        "clipboard-temporary-directory",
        "clipboard-format-list",
    ])
    #expect(try clipboardPayload(fromPackets: sent.packets[2]) == RDPClipboardFormatListPDU(entries: []).encoded())
    _ = try channel.finish()
}

/// The app can publish while the session is answering Monitor Ready; the server's last
/// Format List must still describe the latest content (MS-RDPECLIP 3.1.5.2.1).
@Test func clipboardFormatListsReachTheServerInTheOrderTheContentChanged() async throws {
    let channel = NIOAsyncTestingChannel()
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389))
    let race = ClipboardPublishRace()
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel) { summary, _ in
        // Publish from another thread while the Monitor Ready Format List is being sent.
        guard summary.typeName == "clipboard-format-list", race.start() else {
            return
        }
        race.publishing.enter()
        Thread.detachNewThread {
            race.session?.publishLocalUnicodeText("new")
            race.publishing.leave()
        }
        _ = race.publishing.wait(timeout: .now() + 0.2)
    }
    race.session = session

    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    race.waitUntilPublished()
    await channel.testingEventLoop.run()

    var formatLists: [Data] = []
    while let packet = try await channel.readOutbound(as: ByteBuffer.self) {
        let payload = try clipboardPayload(fromPackets: Data(packet.readableBytesView))
        if try RDPClipboardPDU.parse(from: payload).header.messageType == RDPClipboardMessageType.formatList {
            formatLists.append(payload)
        }
    }
    #expect(formatLists == [
        RDPClipboardFormatListPDU(entries: []).encoded(useLongFormatNames: false),
        RDPClipboardFormatListPDU(entries: [
            RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        ]).encoded(useLongFormatNames: false),
    ])
}

private final class ClipboardPublishRace: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    weak var session: RDPClipboardSession?
    let publishing = DispatchGroup()

    func start() -> Bool {
        lock.withLock {
            defer { started = true }
            return !started
        }
    }

    func waitUntilPublished() {
        publishing.wait()
    }
}

@Test func clipboardSessionSkipsCapabilitiesWhenServerSentNoneAndUsesShortNames() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )

    session.publishLocalUnicodeText("hello")
    #expect(try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady)) == .ready)

    #expect(sent.summaries.map(\.typeName) == [
        "clipboard-temporary-directory",
        "clipboard-format-list",
    ])
    #expect(try clipboardPayload(fromPackets: sent.packets[1]) == RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded(useLongFormatNames: false))
    _ = try channel.finish()
}

@Test func clipboardSessionRequestsAnnouncedTextAndDropsUnsolicitedResponses() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )
    // Without onClipboardContent only the text of a copy is requested.
    let formatList = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC0A1, formatName: "HTML Format"),
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.dib),
    ]).encoded()
    let textResponse = RDPClipboardFormatDataResponsePDU.unicodeText("hello").encoded()

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    #expect(try session.receive(RDPClipboardPDU.parse(from: formatList)) == nil)
    #expect(try session.receive(RDPClipboardPDU.parse(from: textResponse)) == .text("hello"))
    #expect(try session.receive(RDPClipboardPDU.parse(from: textResponse)) == nil)
    #expect(sent.summaries.suffix(2).map(\.typeName) == [
        "clipboard-format-list-response",
        "clipboard-format-data-request",
    ])
    #expect(try sentFormatDataRequestIDs(sent) == [RDPClipboardFormatID.unicodeText])
    _ = try channel.finish()
}

/// The server waits for these answers, so a request that cannot be processed still gets a
/// failure response (MS-RDPECLIP 3.1.5.2.2, 3.1.5.4.3, 3.1.5.4.6).
@Test func clipboardSessionAnswersUnprocessableRequestsWithFailureResponses() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )
    var bothFileContentsFlags = Data()
    bothFileContentsFlags.appendLittleEndianUInt32(42)
    bothFileContentsFlags.appendLittleEndianUInt32(0)
    bothFileContentsFlags.appendLittleEndianUInt32(RDPClipboardFileContentsFlags.size | RDPClipboardFileContentsFlags.range)
    bothFileContentsFlags.appendLittleEndianUInt64(0)
    bothFileContentsFlags.appendLittleEndianUInt32(8)
    let malformedRequests = [
        RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatList,
            messageFlags: RDPClipboardMessageFlags.responseOK,
            payload: Data([0x0D, 0x00, 0x00, 0x00, 0x00, 0x00])
        ),
        RDPClipboardPDU(messageType: RDPClipboardMessageType.formatDataRequest, payload: Data([0x0D, 0x00])),
        RDPClipboardPDU(messageType: RDPClipboardMessageType.fileContentsRequest, payload: bothFileContentsFlags),
    ]

    for request in malformedRequests {
        #expect(throws: RDPDecodeError.invalidClipboardPDU) {
            try session.receive(request)
        }
    }

    let responses = try sent.packets.map { try RDPClipboardPDU.parse(from: clipboardPayload(fromPackets: $0)) }
    try #require(responses.map(\.typeName) == [
        "clipboard-format-list-response",
        "clipboard-format-data-response",
        "clipboard-file-contents-response",
    ])
    #expect(responses.allSatisfy { $0.header.messageFlags == RDPClipboardMessageFlags.responseFail })
    #expect(try RDPClipboardFileContentsResponse.parseIfPresent(from: responses[2]) == .failure(streamID: 42))
    _ = try channel.finish()
}

@Test func clipboardSessionSendsOneFormatDataRequestAtATime() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        requestsRichFormats: true,
        sentMessageHandler: sent.record
    )
    let formatList = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC0A1, formatName: "HTML Format"),
        RDPClipboardFormatListEntry(formatID: 0xC0A2, formatName: "rich text format"),
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.dib),
    ]).encoded()
    let bitmap = Data([40, 0, 0, 0])

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    #expect(try session.receive(RDPClipboardPDU.parse(from: formatList)) == nil)
    #expect(session.outstandingFormatDataRequests == [.unicodeText, .html(formatID: 0xC0A1), .richText(formatID: 0xC0A2), .bitmap(formatID: 8)])
    #expect(try sentFormatDataRequestIDs(sent) == [13])

    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("hi").encoded())) == nil)
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU(
        ok: true,
        data: RDPClipboardHTML.encoded("<b>hi</b>")
    ).encoded())) == nil)
    // A format the server cannot render is left out; the copy still arrives.
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.failure().encoded())) == nil)
    let last = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU(ok: true, data: bitmap).encoded()))

    #expect(try sentFormatDataRequestIDs(sent) == [13, 0xC0A1, 0xC0A2, 8])
    #expect(last == .content(RDPClipboardContent(text: "hi", html: "<html><body><!--StartFragment--><b>hi</b><!--EndFragment--></body></html>", bitmap: bitmap)))
    #expect(session.outstandingFormatDataRequests.isEmpty)
    _ = try channel.finish()
}

/// A new remote copy replaces the requests of the last one that have not gone out,
/// and the answer to the one that has is dropped.
@Test func clipboardSessionDropsTheRestOfAnOlderRemoteCopy() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        requestsRichFormats: true,
        sentMessageHandler: sent.record
    )
    let richCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC0A1, formatName: "HTML Format"),
    ]).encoded()
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    _ = try session.receive(RDPClipboardPDU.parse(from: richCopy))
    _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
    #expect(session.outstandingFormatDataRequests == [.unicodeText, .unicodeText])
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("old").encoded())) == nil)
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("new").encoded()))
        == .content(RDPClipboardContent(text: "new")))
    #expect(try sentFormatDataRequestIDs(sent) == [13, 13])
    _ = try channel.finish()
}

/// A local copy sent while a remote copy is being fetched replaces that copy on the server, so
/// the answer already asked for is dropped and the rest of the copy is not asked for.
@Test func clipboardSessionDropsARemoteCopyALocalCopyReplaced() throws {
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    let fileCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: 0xC0A3, formatName: "FileGroupDescriptorW"),
    ]).encoded()
    let richCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC0A1, formatName: "HTML Format"),
    ]).encoded()
    let fileList = RDPClipboardFormatDataResponsePDU.fileGroupDescriptorW(RDPClipboardFileGroupDescriptorW(descriptors: [
        fileDescriptor(fileSize: 1, fileName: "remote.txt"),
    ])).encoded()

    for requestsRichFormats in [false, true] {
        let channel = EmbeddedChannel()
        let sent = ClipboardSentMessages()
        let session = RDPClipboardSession(
            userChannelID: 1006,
            staticChannelID: 1007,
            channel: channel,
            requestsRichFormats: requestsRichFormats,
            sentMessageHandler: sent.record
        )
        _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
        _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))

        _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
        session.publishLocalUnicodeText("local")
        #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("old").encoded())) == nil)

        _ = try session.receive(RDPClipboardPDU.parse(from: fileCopy))
        session.publishLocalUnicodeText(nil)
        #expect(try session.receive(RDPClipboardPDU.parse(from: fileList)) == nil)

        _ = try session.receive(RDPClipboardPDU.parse(from: richCopy))
        session.publishLocalContent(RDPClipboardContent(text: "local"))
        #expect(session.outstandingFormatDataRequests == [.unicodeText])
        #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("old").encoded())) == nil)
        #expect(session.outstandingFormatDataRequests.isEmpty)

        // The server's next copy is fetched as usual.
        _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
        #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("new").encoded()))
            == (requestsRichFormats ? .content(RDPClipboardContent(text: "new")) : .text("new")))
        #expect(try sentFormatDataRequestIDs(sent) == [13, 0xC0A3, 13, 13])
        _ = try channel.finish()
    }
}

/// A Format List replaces the server's clipboard (MS-RDPECLIP 3.1.5.2.2), so one the session
/// fetches nothing of still retires the copy the application has: an empty list, which a
/// server sends when its clipboard is emptied, or only formats the session does not fetch.
@Test func clipboardSessionReportsARemoteCopyItFetchesNothingOf() throws {
    let emptyCopy = RDPClipboardFormatListPDU(entries: []).encoded()
    let bitmapCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: 2),
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.dib),
    ]).encoded()
    let customCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: 0xC0B0, formatName: "Custom Format"),
    ]).encoded()
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    let bitmap = Data([40, 0, 0, 0])

    for requestsRichFormats in [false, true] {
        let channel = EmbeddedChannel()
        let sent = ClipboardSentMessages()
        let session = RDPClipboardSession(
            userChannelID: 1006,
            staticChannelID: 1007,
            channel: channel,
            requestsRichFormats: requestsRichFormats,
            sentMessageHandler: sent.record
        )
        _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
        _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))

        #expect(try session.receive(RDPClipboardPDU.parse(from: emptyCopy)) == .remoteCopyUnavailable(isEmpty: true))
        #expect(try session.receive(RDPClipboardPDU.parse(from: customCopy)) == .remoteCopyUnavailable(isEmpty: false))
        if requestsRichFormats {
            #expect(try session.receive(RDPClipboardPDU.parse(from: bitmapCopy)) == nil)
            #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU(ok: true, data: bitmap).encoded()))
                == .content(RDPClipboardContent(bitmap: bitmap)))
        } else {
            #expect(try session.receive(RDPClipboardPDU.parse(from: bitmapCopy)) == .remoteCopyUnavailable(isEmpty: false))
        }

        // The answer for a copy the server emptied since is dropped.
        #expect(try session.receive(RDPClipboardPDU.parse(from: textCopy)) == nil)
        #expect(try session.receive(RDPClipboardPDU.parse(from: emptyCopy)) == .remoteCopyUnavailable(isEmpty: true))
        #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("old").encoded())) == nil)

        // While fetching is off, nothing of the server's clipboard reaches the application.
        session.fetchesRemoteCopies = false
        #expect(try session.receive(RDPClipboardPDU.parse(from: emptyCopy)) == nil)
        #expect(try session.receive(RDPClipboardPDU.parse(from: customCopy)) == nil)

        #expect(try sentFormatDataRequestIDs(sent) == (requestsRichFormats ? [8, 13] : [13]))
        #expect(sent.summaries.filter { $0.typeName == "clipboard-format-list-response" }.allSatisfy {
            $0.messageFlags == RDPClipboardMessageFlags.responseOK
        })
        _ = try channel.finish()
    }
}

/// A copy every format asked for of which fails brings nothing, so it is reported like one of
/// no format the session fetches, unless a newer copy, local or remote, came first. A rich
/// copy some formats of which arrive still arrives without the rest.
@Test func clipboardSessionReportsARemoteCopyWhoseFetchFailed() throws {
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    let fileCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: 0xC0A3, formatName: "FileGroupDescriptorW"),
    ]).encoded()
    let richCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC0A1, formatName: "HTML Format"),
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.dib),
    ]).encoded()
    let failure = RDPClipboardFormatDataResponsePDU.failure().encoded()
    let unavailable = RDPClipboardEvent.remoteCopyUnavailable(isEmpty: false)

    for requestsRichFormats in [false, true] {
        let channel = EmbeddedChannel()
        let session = RDPClipboardSession(
            userChannelID: 1006,
            staticChannelID: 1007,
            channel: channel,
            requestsRichFormats: requestsRichFormats
        )
        func receive(_ data: Data) throws -> RDPClipboardEvent? {
            try session.receive(RDPClipboardPDU.parse(from: data))
        }
        _ = try receive(RDPClipboardCapabilitiesPDU().encoded())
        _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))

        for copy in [textCopy, fileCopy] {
            #expect(try receive(copy) == nil)
            #expect(try receive(failure) == unavailable)
        }

        // A newer remote copy, or a local one, replaced the copy whose fetch failed.
        _ = try receive(textCopy)
        _ = try receive(textCopy)
        #expect(try receive(failure) == nil)
        #expect(try receive(failure) == unavailable)
        _ = try receive(textCopy)
        session.publishLocalUnicodeText("local")
        #expect(try receive(failure) == nil)

        guard requestsRichFormats else {
            _ = try channel.finish()
            continue
        }
        _ = try receive(richCopy)
        #expect(try receive(failure) == nil)
        #expect(try receive(failure) == nil)
        #expect(try receive(failure) == unavailable)
        _ = try receive(richCopy)
        #expect(try receive(failure) == nil)
        #expect(try receive(RDPClipboardFormatDataResponsePDU(ok: true, data: RDPClipboardHTML.encoded("<b>hi</b>")).encoded()) == nil)
        #expect(try receive(failure) == .content(RDPClipboardContent(
            html: "<html><body><!--StartFragment--><b>hi</b><!--EndFragment--></body></html>"
        )))
        _ = try channel.finish()
    }
}

/// A client that does not share its clipboard still joins cliprdr, so it can start sharing
/// later; until then it asks the server for nothing.
@Test func clipboardSessionFetchesNoRemoteCopyWhileFetchingIsOff() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        requestsRichFormats: true,
        sentMessageHandler: sent.record
    )
    let richCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC0A1, formatName: "HTML Format"),
    ]).encoded()
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    let fileCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: 0xC0A3, formatName: "FileGroupDescriptorW"),
    ]).encoded()

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    // Turning fetching off drops the rest of the copy being fetched, and its answer.
    _ = try session.receive(RDPClipboardPDU.parse(from: richCopy))
    session.fetchesRemoteCopies = false
    #expect(session.outstandingFormatDataRequests == [.unicodeText])
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("old").encoded())) == nil)

    #expect(try session.receive(RDPClipboardPDU.parse(from: textCopy)) == nil)
    #expect(try session.receive(RDPClipboardPDU.parse(from: fileCopy)) == nil)
    #expect(session.outstandingFormatDataRequests.isEmpty)
    #expect(sent.summaries.suffix(2).map(\.typeName) == [
        "clipboard-format-list-response",
        "clipboard-format-list-response",
    ])
    #expect(try sentFormatDataRequestIDs(sent) == [13])

    // Turned back on, it fetches the last copy announced meanwhile, until a newer one comes.
    session.fetchesRemoteCopies = true
    #expect(session.outstandingFormatDataRequests == [.fileGroupDescriptorW(formatID: 0xC0A3)])
    _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.failure().encoded())) == nil)
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("new").encoded()))
        == .content(RDPClipboardContent(text: "new")))
    #expect(try sentFormatDataRequestIDs(sent) == [13, 0xC0A3, 13])
    _ = try channel.finish()
}

/// A client that turns fetching off in `onClipboardReady` until it can decide, as RDPClient
/// does until its clipboard bridge attaches on the main thread, still gets the server's first
/// copy when that copy comes in between.
@Test func clipboardSessionFetchesTheCopyAnnouncedBeforeFetchingIsTurnedOn() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    #expect(try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady)) == .ready)
    session.fetchesRemoteCopies = false
    #expect(try session.receive(RDPClipboardPDU.parse(from: textCopy)) == nil)
    #expect(try sentFormatDataRequestIDs(sent).isEmpty)

    session.fetchesRemoteCopies = true
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.unicodeText("first").encoded()))
        == .text("first"))
    #expect(try sentFormatDataRequestIDs(sent) == [RDPClipboardFormatID.unicodeText])
    _ = try channel.finish()
}

/// Turned back on, fetching takes only the copy the server's clipboard still holds: the last
/// one announced, and none once this client has published, which replaced it there.
@Test func clipboardSessionFetchesOnlyTheCopyTheServerStillHolds() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    let fileCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: 0xC0A3, formatName: "FileGroupDescriptorW"),
    ]).encoded()
    let files = RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardLocalFile(fileName: "notes.txt", contents: Data([1])).descriptor,
    ])

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    session.fetchesRemoteCopies = false
    _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
    _ = try session.receive(RDPClipboardPDU.parse(from: fileCopy))
    #expect(!session.isAwaitingRemoteCopy)
    session.fetchesRemoteCopies = true
    #expect(session.isAwaitingRemoteCopy)
    #expect(session.outstandingFormatDataRequests == [.fileGroupDescriptorW(formatID: 0xC0A3)])
    #expect(try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.fileGroupDescriptorW(files).encoded()))
        == .fileGroupDescriptor(files))
    #expect(!session.isAwaitingRemoteCopy)

    session.fetchesRemoteCopies = false
    _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
    session.publishLocalUnicodeText("local")
    session.fetchesRemoteCopies = true
    #expect(!session.isAwaitingRemoteCopy)
    #expect(try sentFormatDataRequestIDs(sent) == [0xC0A3])
    _ = try channel.finish()
}

/// A copy with nothing to fetch, announced while fetching was off, is reported once fetching
/// is turned back on, as on arrival, unless a newer copy, local or remote, replaced it first.
@Test func clipboardSessionReportsAnUnavailableCopyAnnouncedWhileFetchingWasOff() throws {
    let channel = EmbeddedChannel()
    let wakes = Locked(0)
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        pendingEventHandler: { wakes.withLock { $0 += 1 } }
    )
    let emptyCopy = RDPClipboardFormatListPDU(entries: []).encoded()
    // Without onClipboardContent a bitmap is not fetched.
    let bitmapCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.dib),
    ]).encoded()
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    func announceWhileOff(_ formatList: Data) throws {
        session.fetchesRemoteCopies = false
        #expect(try session.receive(RDPClipboardPDU.parse(from: formatList)) == nil)
        session.fetchesRemoteCopies = true
    }

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    try announceWhileOff(emptyCopy)
    #expect(wakes.value == 1)
    #expect(session.takePendingEvent() == .remoteCopyUnavailable(isEmpty: true))
    #expect(session.takePendingEvent() == nil)
    try announceWhileOff(bitmapCopy)
    #expect(session.takePendingEvent() == .remoteCopyUnavailable(isEmpty: false))

    try announceWhileOff(emptyCopy)
    session.publishLocalUnicodeText("local")
    #expect(session.takePendingEvent() == nil)
    try announceWhileOff(emptyCopy)
    _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
    #expect(session.takePendingEvent() == nil)

    // A copy with formats is fetched, and has nothing to report.
    try announceWhileOff(textCopy)
    #expect(session.isAwaitingRemoteCopy)
    #expect(session.takePendingEvent() == nil)
    #expect(wakes.value == 4)
    _ = try channel.finish()
}

@Test func clipboardSessionOffersAndAnswersEveryLocalFormat() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel, sentMessageHandler: sent.record)
    let bitmap = Data([40, 0, 0, 0, 1, 0, 0, 0])
    let content = RDPClipboardContent(text: "a\nb", html: "<i>a</i>", richText: Data("{\\rtf1 a}".utf8), bitmap: bitmap)

    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    session.publishLocalContent(content)

    #expect(try clipboardPayload(fromPackets: try #require(sent.packets.last)) == RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
        RDPClipboardFormatListEntry(formatID: 0xC002, formatName: "HTML Format"),
        RDPClipboardFormatListEntry(formatID: 0xC003, formatName: "Rich Text Format"),
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.dib),
    ]).encoded())
    var responses: [RDPClipboardFormatDataResponsePDU?] = []
    for formatID: UInt32 in [13, 0xC002, 0xC003, 8, 0xC001] {
        _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataRequestPDU(formatID: formatID).encoded()))
        responses.append(try RDPClipboardFormatDataResponsePDU.parseIfPresent(
            from: RDPClipboardPDU.parse(from: clipboardPayload(fromPackets: try #require(sent.packets.last)))
        ))
    }

    #expect(try responses[0]?.decodedUnicodeText() == "a\nb")
    #expect(responses[1]?.data == RDPClipboardHTML.encoded("<i>a</i>"))
    #expect(responses[2]?.data == Data("{\\rtf1 a}\u{0}".utf8))
    #expect(responses[3]?.data == bitmap)
    #expect(responses[4] == .failure())

    session.publishLocalContent(RDPClipboardContent())
    #expect(try clipboardPayload(fromPackets: try #require(sent.packets.last)) == RDPClipboardFormatListPDU(entries: []).encoded())
    _ = try channel.finish()
}

@Test func clipboardHTMLEnvelopeOffsetsPointAtTheDocumentAndFragment() throws {
    let encoded = RDPClipboardHTML.encoded("<html><head><style>b{}</style></head><body class=\"x\"><b>é</b></body></html>")
    let text = try #require(String(data: encoded.dropLast(), encoding: .utf8))
    func offset(_ key: String) throws -> Int {
        let line = try #require(text.split(separator: "\r\n").first { $0.hasPrefix(key + ":") })
        return try #require(Int(line.dropFirst(key.count + 1)))
    }
    let bytes = Data(text.utf8)

    #expect(encoded.last == 0)
    #expect(String(data: bytes[try offset("StartFragment") ..< offset("EndFragment")], encoding: .utf8) == "<b>é</b>")
    #expect(String(data: bytes[try offset("StartHTML") ..< offset("EndHTML")], encoding: .utf8)
        == "<html><head><style>b{}</style></head><body class=\"x\"><!--StartFragment--><b>é</b><!--EndFragment--></body></html>")
    #expect(RDPClipboardHTML.decoded(encoded)?.contains("<style>b{}</style>") == true)
}

/// The envelope Windows writes: Version 0.9 or 1.0, a SourceURL line, CRLF lines.
@Test func clipboardHTMLDecodesAWindowsEnvelope() {
    let document = "<html><body>\r\n<!--StartFragment--><p>x</p><!--EndFragment-->\r\n</body></html>"
    let header = "Version:1.0\r\nStartHTML:000000000\r\nEndHTML:000000000\r\nStartFragment:000000000\r\nEndFragment:000000000\r\nSourceURL:https://example.com/a\r\n"
    let startHTML = header.utf8.count
    let startFragment = startHTML + "<html><body>\r\n<!--StartFragment-->".utf8.count
    let filled = header
        .replacingOccurrences(of: "StartHTML:000000000", with: "StartHTML:" + String(format: "%09d", startHTML))
        .replacingOccurrences(of: "EndHTML:000000000", with: "EndHTML:" + String(format: "%09d", startHTML + document.utf8.count))
        .replacingOccurrences(of: "StartFragment:000000000", with: "StartFragment:" + String(format: "%09d", startFragment))
        .replacingOccurrences(of: "EndFragment:000000000", with: "EndFragment:" + String(format: "%09d", startFragment + 8))

    #expect(RDPClipboardHTML.decoded(Data((filled + document).utf8) + Data([0])) == document)
    #expect(RDPClipboardHTML.decoded(Data("<b>no header</b>".utf8)) == "<b>no header</b>")
}

@Test func clipboardRichTextTravelsNULTerminated() {
    #expect(RDPClipboardRichText.encoded(Data("{\\rtf1}".utf8)) == Data("{\\rtf1}\u{0}".utf8))
    #expect(RDPClipboardRichText.encoded(Data("{\\rtf1}\u{0}".utf8)) == Data("{\\rtf1}\u{0}".utf8))
    #expect(RDPClipboardRichText.decoded(Data("{\\rtf1}\u{0}\u{0}".utf8)) == Data("{\\rtf1}".utf8))
}

@Test func clipboardBitmapRoundTripsThroughADeviceIndependentBitmap() throws {
    let width = 3
    let height = 2
    // Top row red, bottom row blue, as RGBA.
    var pixels = [UInt8]()
    for row in 0 ..< height {
        for _ in 0 ..< width {
            pixels += row == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try #require(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))

    let dib = try #require(RDPClipboardBitmap.deviceIndependentBitmap(from: image))
    #expect(dib.count == 40 + width * height * 4)
    #expect(dib.littleEndianUInt32(at: 8) == UInt32(height))
    // Bottom-up: the first row of pixels is the blue one, as BGRA.
    #expect(dib[dib.startIndex + 40 ..< dib.startIndex + 44] == Data([255, 0, 0, 255]))

    let decoded = try #require(RDPClipboardBitmap.image(fromDeviceIndependentBitmap: dib))
    #expect(decoded.width == width)
    #expect(decoded.height == height)
    #expect(RDPClipboardBitmap.image(fromDeviceIndependentBitmap: Data([1, 2, 3])) == nil)
}

@Test func clipboardSessionSendsChunksOfTheNegotiatedSize() throws {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let chunkSize = RDPStaticVirtualChannelChunkSize()
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel, chunkSize: chunkSize)
    session.publishLocalUnicodeText(String(repeating: "x", count: 10_000))
    // The server's VCChunkSize arrives in the Demand Active, after the session exists.
    chunkSize.byteCount = 16_256

    _ = try session.receive(RDPClipboardPDU.parse(
        from: RDPClipboardFormatDataRequestPDU(formatID: RDPClipboardFormatID.unicodeText).encoded()
    ))
    channel.embeddedEventLoop.run()

    var chunkPayloadSizes: [Int] = []
    while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        let packet = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        let chunk = try RDPStaticVirtualChannelPDU.parse(
            fromUserData: mcsSendDataRequest(fromTPKT: packet).userData,
            maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumNegotiatedChunkByteCount
        )
        chunkPayloadSizes.append(chunk.payload.count)
    }
    // 8-byte CLIPRDR header plus 10,000 UTF-16 code units and a terminator.
    #expect(chunkPayloadSizes == [16_256, 3_754])
    _ = try channel.finish()
}

@Test func clipboardSessionReturnsRemainingBytesWhenRangeRunsPastEndOfFile() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentMessageHandler: sent.record
    )

    session.publishLocalFiles([RDPClipboardLocalFile(fileName: "notes.txt", contents: Data([1, 2, 3, 4, 5]))])
    session.respondToFileContentsRequest(.range(streamID: 9, fileIndex: 0, position: 3, requestedByteCount: 0x1000))
    session.respondToFileContentsRequest(.range(streamID: 10, fileIndex: 0, position: 6, requestedByteCount: 1))

    let responses = try sent.packets.suffix(2).map { packets in
        try RDPClipboardFileContentsResponse.parseIfPresent(
            from: RDPClipboardPDU.parse(from: clipboardPayload(fromPackets: packets))
        )
    }
    #expect(responses == [
        .range(streamID: 9, data: Data([4, 5])),
        .failure(streamID: 10),
    ])
    _ = try channel.finish()
}

@Test func clipboardLocalFileNamesReachTheServerAsNamesWindowsAccepts() throws {
    let names = try fileNamesTheServerSees(publishing: [
        "a:b*c?d\"e<f>g|h\\i/j.txt",
        "tab\tline\nfeed.txt",
        "CON", "nul.txt", "Com1.tar.gz", "LPT\u{B9}.txt", "aux .log", "CONSOLE.txt", "COM10.txt",
        "conin$", "CONOUT$.log", "Conin$ .txt", "CONIN.txt", "CONOUT$X.txt",
        "report. . ", "...", " ",
        "Notes.txt", "notes.txt", "NOTES.TXT", "notes.txt.",
    ])

    #expect(names == [
        // "\" and "/" separate folders; see clipboardLocalFilesKeepTheirFolders.
        "a_b_c_d_e_f_g_h\\i\\j.txt",
        "tab_line_feed.txt",
        "_CON", "_nul.txt", "_Com1.tar.gz", "_LPT\u{B9}.txt", "_aux .log", "CONSOLE.txt", "COM10.txt",
        "_conin$", "_CONOUT$.log", "_Conin$ .txt", "CONIN.txt", "CONOUT$X.txt",
        "report", "file", "file-2",
        "Notes.txt", "notes-2.txt", "NOTES-3.TXT", "notes-4.txt",
    ])
}

/// Windows drops only a name's trailing dots and spaces (U+0020), so leading spaces, and other
/// whitespace at either end, reach the server as they are.
@Test func clipboardLocalFileNamesKeepTheWhitespaceWindowsKeeps() throws {
    let kept = [
        " leading.txt",
        "\u{A0}no-break space\u{A0}",
        "\u{3000}ideographic space.txt\u{3000}",
        "\u{200B}zero width space\u{200B}",
        "\u{2003}em space.txt",
    ]
    let names = try fileNamesTheServerSees(publishing: kept + [
        " trailing. . ",
        " \u{A0} ",
        "   ",
        " Folder \\ inner.txt ",
    ])

    #expect(names == kept + [" trailing", " \u{A0}", "file", " Folder\\ inner.txt"])
}

/// A file in a folder goes out as a path relative to where the server pastes, as the shell's
/// FILEGROUPDESCRIPTORW carries it, so Windows recreates the folder around it. Each component
/// is made valid on its own, and a clash is numbered in the last one.
@Test func clipboardLocalFilesKeepTheirFolders() throws {
    let names = try fileNamesTheServerSees(publishing: [
        RDPClipboardLocalFile(fileName: "Folder", contents: Data(), fileAttributes: RDPClipboardFileAttributes.directory),
        RDPClipboardLocalFile(fileName: "Folder\\inner.txt", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "Folder/Sub:dir. /CON.txt", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "\\Folder\\.\\..\\\\notes.txt\\", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "Folder\\INNER.TXT", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "Other\\inner.txt", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "inner.txt", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "folder", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "Folder\\..", contents: Data([1])),
        RDPClipboardLocalFile(fileName: "/./ \\", contents: Data([1])),
    ])

    #expect(names == [
        "Folder",
        "Folder\\inner.txt",
        "Folder\\Sub_dir\\_CON.txt",
        "Folder\\notes.txt",
        "Folder\\INNER-2.TXT",
        "Other\\inner.txt",
        "inner.txt",
        "folder-2",
        "Folder-3",
        "file",
    ])
}

/// A folder numbered to differ from another folder or a file keeps that number for everything
/// inside it, so its entries are pasted into it and not into the one it clashed with.
@Test func clipboardNumberedLocalFoldersKeepTheirEntries() throws {
    func directory(_ fileName: String) -> RDPClipboardLocalFile {
        RDPClipboardLocalFile(fileName: fileName, contents: Data(), fileAttributes: RDPClipboardFileAttributes.directory)
    }
    func file(_ fileName: String) -> RDPClipboardLocalFile {
        RDPClipboardLocalFile(fileName: fileName, contents: Data([1]))
    }

    // Two folders that become the same name.
    #expect(try fileNamesTheServerSees(publishing: [
        directory("What?"), file("What?\\a.txt"), directory("What*"), file("What*\\a.txt"),
    ]) == ["What_", "What_\\a.txt", "What_-2", "What_-2\\a.txt"])
    // A folder after a file of its name, with or without an entry of its own, and a file
    // after a folder of its name.
    #expect(try fileNamesTheServerSees(publishing: [
        file("Notes."), directory("Notes"), file("Notes\\a.txt"),
    ]) == ["Notes", "Notes-2", "Notes-2\\a.txt"])
    #expect(try fileNamesTheServerSees(publishing: [
        file("Report"), file("Report\\a.txt"), file("Report/b.txt"), file("Data\\a.txt"), file("data"),
    ]) == ["Report", "Report-2\\a.txt", "Report-2\\b.txt", "Data\\a.txt", "data-2"])
    // The folders under a numbered one follow it; a folder's own entry can come after its
    // contents; folders are told apart as spelled, as files are.
    #expect(try fileNamesTheServerSees(publishing: [
        directory("A?"), directory("A*"), directory("A*\\B"), file("A*\\B\\c.txt"),
        file("Late\\a.txt"), directory("Late"), file("Late\\b.txt"),
        directory("Case"), file("CASE\\a.txt"),
    ]) == [
        "A_", "A_-2", "A_-2\\B", "A_-2\\B\\c.txt",
        "Late\\a.txt", "Late", "Late\\b.txt",
        "Case", "CASE-2\\a.txt",
    ])
}

/// A component holds 255 UTF-16 code units on NTFS; a longer one is shortened before its
/// extension.
@Test func clipboardLongLocalFileNamesKeepTheirExtension() throws {
    let longName = String(repeating: "a", count: 300) + ".txt"
    let emojiName = String(repeating: "\u{1F600}", count: 200) + ".pdf"
    let names = try fileNamesTheServerSees(publishing: [
        longName,
        longName,
        emojiName,
        String(repeating: "b", count: 254) + " " + String(repeating: "b", count: 5),
        "CONSOLE." + String(repeating: "x", count: 251),
        String(repeating: "c", count: 300) + "\\" + longName,
    ])

    #expect(names[0] == String(repeating: "a", count: 251) + ".txt")
    #expect(names[1] == String(repeating: "a", count: 249) + "-2.txt")
    #expect(names[2] == String(repeating: "\u{1F600}", count: 125) + ".pdf")
    // A cut that ends in a space drops it, as Windows would.
    #expect(names[3] == String(repeating: "b", count: 254))
    // Cut to "CON" before its extension, the name gets a leading "_" and is cut again.
    #expect(names[4] == "_CO." + String(repeating: "x", count: 251))
    // A folder cut to 255 leaves its file 3 code units of cFileName, too few for ".txt", so
    // the file goes to the top level.
    #expect(names[5] == String(repeating: "a", count: 249) + "-3.txt")
    #expect(names.allSatisfy { $0.utf16.count <= 255 })
}

/// cFileName holds 259 UTF-16 code units: a longer path has its last component shortened
/// before the extension. Folders that leave no room for the extension, a number and one
/// character before them send the file to the top level under its own name.
@Test func clipboardLongLocalFilePathsFitTheFileDescriptor() throws {
    let folder = String(repeating: "f", count: 200)
    let fullFolder = String(repeating: "g", count: 250)
    let deepFolder = Array(repeating: String(repeating: "d", count: 100), count: 3).joined(separator: "/")
    let crowdedFolder = String(repeating: "h", count: 251)
    let names = try fileNamesTheServerSees(publishing: [
        folder + "\\" + String(repeating: "r", count: 100) + ".txt",
        folder + "\\" + String(repeating: "r", count: 100) + ".txt",
        fullFolder + "\\report.txt",
        fullFolder + "\\report.txt",
        fullFolder + "\\report.docx",
        deepFolder + "/report.txt",
        String(repeating: "e", count: 250) + "\\" + String(repeating: "\u{1F600}", count: 4),
    ] + Array(repeating: crowdedFolder + "\\report.txt", count: 10))

    #expect(names == [
        folder + "\\" + String(repeating: "r", count: 54) + ".txt",
        folder + "\\" + String(repeating: "r", count: 52) + "-2.txt",
        fullFolder + "\\repo.txt",
        fullFolder + "\\re-2.txt",
        fullFolder + "\\rep.docx",
        "report.txt",
        String(repeating: "e", count: 250) + "\\" + String(repeating: "\u{1F600}", count: 4),
        crowdedFolder + "\\rep.txt",
    ] + (2 ... 9).map { crowdedFolder + "\\r-\($0).txt" } + [
        // "-10.txt" leaves no room in the folder.
        "report-2.txt",
    ])
    #expect(names.allSatisfy { $0.utf16.count <= 259 })
}

/// Publishes local files named `fileNames` and returns the names the session's
/// FileGroupDescriptorW gives the server.
private func fileNamesTheServerSees(publishing fileNames: [String]) throws -> [String] {
    try fileNamesTheServerSees(publishing: fileNames.map { RDPClipboardLocalFile(fileName: $0, contents: Data([1])) })
}

private func fileNamesTheServerSees(publishing files: [RDPClipboardLocalFile]) throws -> [String] {
    let channel = EmbeddedChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389)).wait()
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel)
    session.publishLocalFiles(files)
    _ = try session.receive(RDPClipboardPDU.parse(
        from: RDPClipboardFormatDataRequestPDU(formatID: RDPClipboardLocalFormatID.fileGroupDescriptorW).encoded()
    ))
    channel.embeddedEventLoop.run()

    // The response spans several chunks.
    var packets = Data()
    while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        packets.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
    let response = try #require(try RDPClipboardFormatDataResponsePDU.parseIfPresent(
        from: RDPClipboardPDU.parse(from: clipboardPayload(fromPackets: packets))
    ))
    _ = try channel.finish()
    return try response.decodedFileGroupDescriptorW().descriptors.map(\.fileName)
}

private final class ClipboardSentMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(summary: RDPClipboardMessageSummary, packets: Data)] = []

    var summaries: [RDPClipboardMessageSummary] {
        lock.withLock { sent.map(\.summary) }
    }

    var packets: [Data] {
        lock.withLock { sent.map(\.packets) }
    }

    @Sendable func record(_ summary: RDPClipboardMessageSummary, _ packets: Data) {
        lock.withLock { sent.append((summary, packets)) }
    }
}

private func sentFormatDataRequestIDs(_ sent: ClipboardSentMessages) throws -> [UInt32] {
    try sent.packets.compactMap {
        try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: RDPClipboardPDU.parse(from: clipboardPayload(fromPackets: $0)))?
            .formatID
    }
}

private func clipboardPayload(fromPackets data: Data) throws -> Data {
    var reassembler = RDPStaticVirtualChannelReassembler()
    var offset = data.startIndex
    while offset < data.endIndex {
        let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        let chunk = try RDPStaticVirtualChannelPDU.parse(
            fromUserData: mcsSendDataRequest(fromTPKT: data.subdata(in: offset ..< offset + length)).userData,
            maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount
        )
        if let pdu = try reassembler.append(chunk, maximumChunkByteCount: RDPStaticVirtualChannelPDU.maximumPayloadByteCount) {
            return pdu.payload
        }
        offset += length
    }
    throw RDPDecodeError.invalidStaticVirtualChannelPDU
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
