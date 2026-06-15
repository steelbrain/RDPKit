import Foundation
@testable import RDPKit
import Testing

@Test func clipboardCapabilitiesEncodeLongFormatNames() {
    #expect(RDPClipboardCapabilitiesPDU().encoded() == hexData("""
    07 00 00 00 10 00 00 00
    01 00 00 00
    01 00 0c 00 02 00 00 00 02 00 00 00
    """))
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

@Test func clipboardUnicodeFormatListEncodesLongFormatNameEntry() {
    #expect(RDPClipboardFormatListPDU.unicodeText().encoded() == hexData("""
    02 00 00 00 06 00 00 00 0d 00 00 00 00 00
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

@Test func clipboardFormatDataRequestParsesRequestedFormat() throws {
    let pdu = try RDPClipboardPDU.parse(from: RDPClipboardFormatDataRequestPDU(
        formatID: RDPClipboardFormatID.unicodeText
    ).encoded())
    let request = try #require(try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: pdu))

    #expect(request.formatID == RDPClipboardFormatID.unicodeText)
}

@Test func clipboardFormatDataResponseRoundTripsUnicodeText() throws {
    let response = RDPClipboardFormatDataResponsePDU.unicodeText("hello")
    let pdu = try RDPClipboardPDU.parse(from: response.encoded())
    let parsed = try #require(try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu))

    #expect(parsed.ok)
    #expect(try parsed.decodedUnicodeText() == "hello")
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
    #expect(parsed.descriptors[0].creationTime == 0x0102_0304_0506_0708)
    #expect(parsed.descriptors[0].lastAccessTime == 0x1112_1314_1516_1718)
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
    let request = RDPClipboardFileContentsRequestPDU(
        streamID: 1,
        fileIndex: 0,
        flags: RDPClipboardFileContentsFlags.size | RDPClipboardFileContentsFlags.range,
        position: 0,
        requestedByteCount: 8
    )

    #expect(throws: RDPDecodeError.invalidClipboardPDU) {
        try request.encoded()
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
    data.append(Data(repeating: 0, count: 16))
    data.append(Data(repeating: 0, count: 8))
    data.append(Data(repeating: 0, count: 8))
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
