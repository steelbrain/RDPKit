import Foundation
@preconcurrency import NIOCore

enum RDPClipboardChannel {
    static let name = "cliprdr"
}

enum RDPClipboardFormatID {
    static let unicodeText: UInt32 = 13
}

enum RDPClipboardRegisteredFormatName {
    static let fileGroupDescriptorW = "FileGroupDescriptorW"
    static let fileContents = "FileContents"
}

enum RDPClipboardLocalFormatID {
    static let fileGroupDescriptorW: UInt32 = 0xC000
    static let fileContents: UInt32 = 0xC001
}

public enum RDPClipboardFileDescriptorFlags {
    public static let classID: UInt32 = 0x0000_0001
    public static let sizePoint: UInt32 = 0x0000_0002
    public static let attributes: UInt32 = 0x0000_0004
    public static let creationTime: UInt32 = 0x0000_0008
    public static let lastAccessTime: UInt32 = 0x0000_0010
    public static let lastWriteTime: UInt32 = 0x0000_0020
    public static let fileSize: UInt32 = 0x0000_0040
    public static let unicode: UInt32 = 0x8000_0000
}

public enum RDPClipboardFileAttributes {
    public static let directory: UInt32 = 0x0000_0010
    public static let archive: UInt32 = 0x0000_0020
}

enum RDPClipboardMessageType {
    static let monitorReady: UInt16 = 0x0001
    static let formatList: UInt16 = 0x0002
    static let formatListResponse: UInt16 = 0x0003
    static let formatDataRequest: UInt16 = 0x0004
    static let formatDataResponse: UInt16 = 0x0005
    static let clipboardCapabilities: UInt16 = 0x0007
    static let fileContentsRequest: UInt16 = 0x0008
    static let fileContentsResponse: UInt16 = 0x0009
}

enum RDPClipboardMessageFlags {
    static let responseOK: UInt16 = 0x0001
    static let responseFail: UInt16 = 0x0002
    static let asciiNames: UInt16 = 0x0004
}

enum RDPClipboardCapabilityFlags {
    static let useLongFormatNames: UInt32 = 0x0000_0002
}

enum RDPClipboardFileContentsFlags {
    static let size: UInt32 = 0x0000_0001
    static let range: UInt32 = 0x0000_0002
}

struct RDPClipboardHeader: Equatable, Sendable {
    var messageType: UInt16
    var messageFlags: UInt16
    var dataLength: UInt32

    init(messageType: UInt16, messageFlags: UInt16 = 0, dataLength: UInt32) {
        self.messageType = messageType
        self.messageFlags = messageFlags
        self.dataLength = dataLength
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPClipboardHeader {
        try RDPClipboardHeader(
            messageType: cursor.readLittleEndianUInt16(),
            messageFlags: cursor.readLittleEndianUInt16(),
            dataLength: cursor.readLittleEndianUInt32()
        )
    }

    func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt16(messageType)
        data.appendLittleEndianUInt16(messageFlags)
        data.appendLittleEndianUInt32(dataLength)
        return data
    }
}

public struct RDPClipboardMessageSummary: Encodable, Equatable, Sendable {
    public var typeName: String
    public var messageFlags: UInt16
    public var dataLength: UInt32

    public init(typeName: String, messageFlags: UInt16, dataLength: UInt32) {
        self.typeName = typeName
        self.messageFlags = messageFlags
        self.dataLength = dataLength
    }

    static func summarize(_ pdu: RDPClipboardPDU) -> RDPClipboardMessageSummary {
        RDPClipboardMessageSummary(
            typeName: pdu.typeName,
            messageFlags: pdu.header.messageFlags,
            dataLength: pdu.header.dataLength
        )
    }
}

struct RDPClipboardPDU: Equatable, Sendable {
    static let headerByteCount = 8

    var header: RDPClipboardHeader
    var payload: Data

    init(messageType: UInt16, messageFlags: UInt16 = 0, payload: Data = Data()) {
        precondition(payload.count <= Int(UInt32.max))

        header = RDPClipboardHeader(
            messageType: messageType,
            messageFlags: messageFlags,
            dataLength: UInt32(payload.count)
        )
        self.payload = payload
    }

    var typeName: String {
        switch header.messageType {
        case RDPClipboardMessageType.monitorReady:
            "clipboard-monitor-ready"
        case RDPClipboardMessageType.formatList:
            "clipboard-format-list"
        case RDPClipboardMessageType.formatListResponse:
            "clipboard-format-list-response"
        case RDPClipboardMessageType.formatDataRequest:
            "clipboard-format-data-request"
        case RDPClipboardMessageType.formatDataResponse:
            "clipboard-format-data-response"
        case RDPClipboardMessageType.clipboardCapabilities:
            "clipboard-capabilities"
        case RDPClipboardMessageType.fileContentsRequest:
            "clipboard-file-contents-request"
        case RDPClipboardMessageType.fileContentsResponse:
            "clipboard-file-contents-response"
        default:
            "clipboard-0x\(String(format: "%04x", header.messageType))"
        }
    }

    static func parse(from data: Data) throws -> RDPClipboardPDU {
        guard data.count >= 8 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(data)
        let header = try RDPClipboardHeader.parse(from: &cursor)
        guard Int(header.dataLength) == cursor.remaining else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        return RDPClipboardPDU(header: header, payload: cursor.readRemainingData())
    }

    func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }

    private init(header: RDPClipboardHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

struct RDPClipboardCapabilitiesPDU: Equatable, Sendable {
    var version: UInt32
    var generalFlags: UInt32

    init(
        version: UInt32 = 2,
        generalFlags: UInt32 = RDPClipboardCapabilityFlags.useLongFormatNames
    ) {
        self.version = version
        self.generalFlags = generalFlags
    }

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardCapabilitiesPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.clipboardCapabilities else {
            return nil
        }
        guard pdu.payload.count >= 4 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let capabilitySetCount = try Int(cursor.readLittleEndianUInt16())
        _ = try cursor.readLittleEndianUInt16()
        var generalCapability: RDPClipboardCapabilitiesPDU?
        for _ in 0 ..< capabilitySetCount {
            guard cursor.remaining >= 4 else {
                throw RDPDecodeError.invalidClipboardPDU
            }
            let type = try cursor.readLittleEndianUInt16()
            let length = try Int(cursor.readLittleEndianUInt16())
            guard length >= 4, length - 4 <= cursor.remaining else {
                throw RDPDecodeError.invalidClipboardPDU
            }
            let body = try cursor.readData(count: length - 4)
            if type == 1 {
                var bodyCursor = ByteCursor(body)
                guard bodyCursor.remaining >= 8 else {
                    throw RDPDecodeError.invalidClipboardPDU
                }
                generalCapability = try RDPClipboardCapabilitiesPDU(
                    version: bodyCursor.readLittleEndianUInt32(),
                    generalFlags: bodyCursor.readLittleEndianUInt32()
                )
            }
        }
        return generalCapability ?? RDPClipboardCapabilitiesPDU(version: 1, generalFlags: 0)
    }

    func encoded() -> Data {
        var body = Data()
        body.appendLittleEndianUInt16(1)
        body.appendLittleEndianUInt16(0)
        body.appendLittleEndianUInt16(1)
        body.appendLittleEndianUInt16(12)
        body.appendLittleEndianUInt32(version)
        body.appendLittleEndianUInt32(generalFlags)
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.clipboardCapabilities,
            payload: body
        ).encoded()
    }
}

struct RDPClipboardFormatListEntry: Equatable, Sendable {
    var formatID: UInt32
    var formatName: String?

    init(formatID: UInt32, formatName: String? = nil) {
        self.formatID = formatID
        self.formatName = formatName?.isEmpty == true ? nil : formatName
    }
}

struct RDPClipboardFormatListPDU: Equatable, Sendable {
    var entries: [RDPClipboardFormatListEntry]

    var formatIDs: [UInt32] {
        entries.map(\.formatID)
    }

    init(entries: [RDPClipboardFormatListEntry]) {
        self.entries = entries
    }

    init(formatIDs: [UInt32]) {
        entries = formatIDs.map { RDPClipboardFormatListEntry(formatID: $0) }
    }

    static func unicodeText() -> RDPClipboardFormatListPDU {
        RDPClipboardFormatListPDU(formatIDs: [RDPClipboardFormatID.unicodeText])
    }

    var fileGroupDescriptorWFormatID: UInt32? {
        formatID(named: RDPClipboardRegisteredFormatName.fileGroupDescriptorW)
    }

    var fileContentsFormatID: UInt32? {
        formatID(named: RDPClipboardRegisteredFormatName.fileContents)
    }

    func formatID(named formatName: String) -> UInt32? {
        entries.first { entry in
            entry.formatName?.caseInsensitiveCompare(formatName) == .orderedSame
        }?.formatID
    }

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFormatListPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.formatList else {
            return nil
        }
        if pdu.payload.isEmpty {
            return RDPClipboardFormatListPDU(entries: [])
        }
        if pdu.header.messageFlags & RDPClipboardMessageFlags.asciiNames != 0 {
            guard pdu.payload.count.isMultiple(of: 36) else {
                throw RDPDecodeError.invalidClipboardPDU
            }
            var cursor = ByteCursor(pdu.payload)
            var entries: [RDPClipboardFormatListEntry] = []
            while cursor.remaining > 0 {
                let formatID = try cursor.readLittleEndianUInt32()
                let nameData = try cursor.readData(count: 32)
                entries.append(RDPClipboardFormatListEntry(
                    formatID: formatID,
                    formatName: decodeClipboardASCIIFormatName(nameData)
                ))
            }
            return RDPClipboardFormatListPDU(entries: entries)
        }

        var cursor = ByteCursor(pdu.payload)
        var entries: [RDPClipboardFormatListEntry] = []
        while cursor.remaining > 0 {
            guard cursor.remaining >= 6 else {
                throw RDPDecodeError.invalidClipboardPDU
            }
            let formatID = try cursor.readLittleEndianUInt32()
            var formatNameCodeUnits: [UInt16] = []
            while true {
                guard cursor.remaining >= 2 else {
                    throw RDPDecodeError.invalidClipboardPDU
                }
                let codeUnit = try cursor.readLittleEndianUInt16()
                if codeUnit == 0 {
                    break
                }
                formatNameCodeUnits.append(codeUnit)
            }
            entries.append(RDPClipboardFormatListEntry(
                formatID: formatID,
                formatName: decodeClipboardUnicodeFormatName(formatNameCodeUnits)
            ))
        }
        return RDPClipboardFormatListPDU(entries: entries)
    }

    func encoded() -> Data {
        var payload = Data()
        for entry in entries {
            payload.appendLittleEndianUInt32(entry.formatID)
            if let formatName = entry.formatName {
                for codeUnit in formatName.utf16 {
                    payload.appendLittleEndianUInt16(codeUnit)
                }
            }
            payload.appendLittleEndianUInt16(0)
        }
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatList,
            payload: payload
        ).encoded()
    }
}

struct RDPClipboardFormatDataRequestPDU: Equatable, Sendable {
    var formatID: UInt32

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFormatDataRequestPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.formatDataRequest else {
            return nil
        }
        guard pdu.payload.count == 4 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPClipboardFormatDataRequestPDU(formatID: cursor.readLittleEndianUInt32())
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(formatID)
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatDataRequest,
            payload: payload
        ).encoded()
    }
}

struct RDPClipboardFormatDataResponsePDU: Equatable, Sendable {
    static let maximumDataByteCount = RDPStaticVirtualChannelPDU.maximumPayloadByteCount
        - RDPClipboardPDU.headerByteCount

    var ok: Bool
    var data: Data

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFormatDataResponsePDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.formatDataResponse else {
            return nil
        }
        let ok = pdu.header.messageFlags & RDPClipboardMessageFlags.responseOK != 0
        return RDPClipboardFormatDataResponsePDU(ok: ok, data: pdu.payload)
    }

    static func unicodeText(_ text: String) -> RDPClipboardFormatDataResponsePDU {
        RDPClipboardFormatDataResponsePDU(ok: true, data: encodedClipboardUnicodeText(text))
    }

    static func unicodeTextIfEncodable(_ text: String) -> RDPClipboardFormatDataResponsePDU? {
        guard let byteCount = encodedClipboardUnicodeTextByteCount(text),
              byteCount <= maximumDataByteCount
        else {
            return nil
        }

        return unicodeText(text)
    }

    static func fileGroupDescriptorW(
        _ descriptorList: RDPClipboardFileGroupDescriptorW
    ) -> RDPClipboardFormatDataResponsePDU {
        RDPClipboardFormatDataResponsePDU(ok: true, data: descriptorList.encoded())
    }

    static func failure() -> RDPClipboardFormatDataResponsePDU {
        RDPClipboardFormatDataResponsePDU(ok: false, data: Data())
    }

    func encoded() -> Data {
        RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatDataResponse,
            messageFlags: ok ? RDPClipboardMessageFlags.responseOK : RDPClipboardMessageFlags.responseFail,
            payload: data
        ).encoded()
    }

    func decodedUnicodeText() throws -> String {
        try decodeClipboardUnicodeText(data)
    }

    func decodedFileGroupDescriptorW() throws -> RDPClipboardFileGroupDescriptorW {
        guard ok else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        return try RDPClipboardFileGroupDescriptorW.parse(from: data)
    }
}

public struct RDPClipboardFileGroupDescriptorW: Equatable, Sendable {
    public var descriptors: [RDPClipboardFileDescriptorW]

    public init(descriptors: [RDPClipboardFileDescriptorW]) {
        self.descriptors = descriptors
    }

    public static func parse(from data: Data) throws -> RDPClipboardFileGroupDescriptorW {
        guard data.count >= 4 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(data)
        let count = try Int(cursor.readLittleEndianUInt32())
        guard count <= cursor.remaining / RDPClipboardFileDescriptorW.byteCount else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var descriptors: [RDPClipboardFileDescriptorW] = []
        descriptors.reserveCapacity(count)
        for _ in 0 ..< count {
            try descriptors.append(RDPClipboardFileDescriptorW.parse(from: &cursor))
        }

        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        return RDPClipboardFileGroupDescriptorW(descriptors: descriptors)
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(UInt32(descriptors.count))
        for descriptor in descriptors {
            data.append(descriptor.encoded())
        }
        return data
    }

    public func remoteFileTransferFiles(
        maximumTotalByteCount: UInt64? = nil
    ) throws -> [RDPClipboardRemoteFileTransferFile] {
        guard descriptors.isEmpty == false else {
            throw RDPClipboardRemoteFileTransferPlanningError.emptyFileList
        }

        var usedFileNames = Set<String>()
        var files: [RDPClipboardRemoteFileTransferFile] = []
        var knownByteCount: UInt64 = 0
        for (offset, descriptor) in descriptors.enumerated() where descriptor.isDirectory == false {
            guard let fileIndex = Int32(exactly: offset) else {
                throw RDPClipboardRemoteFileTransferPlanningError.invalidFileIndex
            }

            let declaredByteCount = descriptor.flags & RDPClipboardFileDescriptorFlags.fileSize == 0
                ? nil
                : descriptor.fileSize
            if let maximumTotalByteCount, let declaredByteCount {
                guard declaredByteCount <= maximumTotalByteCount,
                      knownByteCount <= maximumTotalByteCount - declaredByteCount
                else {
                    throw RDPClipboardRemoteFileTransferPlanningError.totalByteLimitExceeded
                }
                knownByteCount += declaredByteCount
            }

            files.append(RDPClipboardRemoteFileTransferFile(
                fileIndex: fileIndex,
                fileName: RDPClipboardRemoteFileTransferFile.uniqueFileName(
                    descriptor.fileName,
                    usedFileNames: &usedFileNames
                ),
                declaredByteCount: declaredByteCount
            ))
        }

        guard files.isEmpty == false else {
            throw RDPClipboardRemoteFileTransferPlanningError.containsOnlyDirectories
        }
        return files
    }
}

public enum RDPClipboardRemoteFileTransferPlanningError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyFileList
    case containsOnlyDirectories
    case invalidFileIndex
    case totalByteLimitExceeded

    public var description: String {
        switch self {
        case .emptyFileList:
            "Remote file clipboard is empty."
        case .containsOnlyDirectories:
            "Remote clipboard contains directories but no files."
        case .invalidFileIndex:
            "Remote file index is not valid."
        case .totalByteLimitExceeded:
            "Remote files exceed the configured byte limit."
        }
    }
}

public struct RDPClipboardRemoteFileTransferFile: Equatable, Sendable {
    public var fileIndex: Int32
    public var fileName: String
    public var declaredByteCount: UInt64?

    public init(fileIndex: Int32, fileName: String, declaredByteCount: UInt64? = nil) {
        self.fileIndex = fileIndex
        self.fileName = Self.sanitizedFileName(fileName)
        self.declaredByteCount = declaredByteCount
    }

    fileprivate static func uniqueFileName(
        _ fileName: String,
        usedFileNames: inout Set<String>
    ) -> String {
        let sanitized = sanitizedFileName(fileName)
        let sanitizedNSString = sanitized as NSString
        let baseName = sanitizedNSString.deletingPathExtension
        let pathExtension = sanitizedNSString.pathExtension
        var candidate = sanitized
        var suffix = 2
        while usedFileNames.contains(candidate.lowercased()) {
            let suffixText = "-\(suffix)"
            let extensionText = pathExtension.isEmpty ? "" : ".\(pathExtension)"
            let maximumBaseLength = max(1, 255 - suffixText.count - extensionText.count)
            let truncatedBaseName = String(baseName.prefix(maximumBaseLength))
            candidate = String("\(truncatedBaseName)\(suffixText)\(extensionText)".prefix(255))
            suffix += 1
        }
        usedFileNames.insert(candidate.lowercased())
        return candidate
    }

    private static func sanitizedFileName(_ fileName: String) -> String {
        let fallback = "remote-file"
        let lastPathComponent = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let baseName = lastPathComponent.isEmpty ? fallback : lastPathComponent
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
            .union(.newlines)
        var sanitizedScalars = String.UnicodeScalarView()
        for scalar in baseName.unicodeScalars {
            sanitizedScalars.append(invalidCharacters.contains(scalar) ? "_" : scalar)
        }
        let sanitized = String(sanitizedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? fallback : sanitized).prefix(255))
    }
}

public struct RDPClipboardFileDescriptorW: Equatable, Sendable {
    static let byteCount = 592
    private static let maximumFileNameCodeUnitCount = 260

    public var flags: UInt32
    public var fileAttributes: UInt32
    public var creationTime: UInt64
    public var lastAccessTime: UInt64
    public var lastWriteTime: UInt64
    public var fileSize: UInt64
    public var fileName: String

    public init(
        flags: UInt32,
        fileAttributes: UInt32,
        creationTime: UInt64 = 0,
        lastAccessTime: UInt64 = 0,
        lastWriteTime: UInt64 = 0,
        fileSize: UInt64,
        fileName: String
    ) {
        self.flags = flags
        self.fileAttributes = fileAttributes
        self.creationTime = creationTime
        self.lastAccessTime = lastAccessTime
        self.lastWriteTime = lastWriteTime
        self.fileSize = fileSize
        self.fileName = fileName
    }

    public var isDirectory: Bool {
        fileAttributes & RDPClipboardFileAttributes.directory != 0
    }

    static func parse(from cursor: inout ByteCursor) throws -> RDPClipboardFileDescriptorW {
        let flags = try cursor.readLittleEndianUInt32()
        _ = try cursor.readData(count: 16)
        _ = try cursor.readData(count: 8)
        _ = try cursor.readData(count: 8)
        let fileAttributes = try cursor.readLittleEndianUInt32()
        let creationTime = try readFileTime(from: &cursor)
        let lastAccessTime = try readFileTime(from: &cursor)
        let lastWriteTime = try readFileTime(from: &cursor)
        let fileSizeHigh = try cursor.readLittleEndianUInt32()
        let fileSizeLow = try cursor.readLittleEndianUInt32()
        let fileNameData = try cursor.readData(count: maximumFileNameCodeUnitCount * 2)

        return try RDPClipboardFileDescriptorW(
            flags: flags,
            fileAttributes: fileAttributes,
            creationTime: creationTime,
            lastAccessTime: lastAccessTime,
            lastWriteTime: lastWriteTime,
            fileSize: UInt64(fileSizeHigh) << 32 | UInt64(fileSizeLow),
            fileName: decodeClipboardFixedUnicodeString(fileNameData)
        )
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        data.append(Data(repeating: 0, count: 16))
        data.append(Data(repeating: 0, count: 8))
        data.append(Data(repeating: 0, count: 8))
        data.appendLittleEndianUInt32(fileAttributes)
        data.appendClipboardUInt64(creationTime)
        data.appendClipboardUInt64(lastAccessTime)
        data.appendClipboardUInt64(lastWriteTime)
        data.appendLittleEndianUInt32(UInt32((fileSize >> 32) & 0xFFFF_FFFF))
        data.appendLittleEndianUInt32(UInt32(fileSize & 0xFFFF_FFFF))
        appendFixedUnicodeFileName(fileName, to: &data)
        return data
    }

    private static func readFileTime(from cursor: inout ByteCursor) throws -> UInt64 {
        let low = try cursor.readLittleEndianUInt32()
        let high = try cursor.readLittleEndianUInt32()
        return UInt64(high) << 32 | UInt64(low)
    }
}

public struct RDPClipboardLocalFile: Equatable, Sendable {
    public var descriptor: RDPClipboardFileDescriptorW
    public var contents: Data

    public init(
        fileName: String,
        contents: Data,
        fileAttributes: UInt32 = RDPClipboardFileAttributes.archive
    ) {
        descriptor = RDPClipboardFileDescriptorW(
            flags: RDPClipboardFileDescriptorFlags.attributes
                | RDPClipboardFileDescriptorFlags.fileSize
                | RDPClipboardFileDescriptorFlags.unicode,
            fileAttributes: fileAttributes,
            fileSize: UInt64(contents.count),
            fileName: fileName
        )
        self.contents = contents
    }

    public init(descriptor: RDPClipboardFileDescriptorW, contents: Data) {
        self.descriptor = descriptor
        self.contents = contents
    }
}

public enum RDPClipboardLimits {
    public static let maximumUnicodeTextByteCount = RDPClipboardFormatDataResponsePDU.maximumDataByteCount

    public static let maximumUnicodeTextUTF16CodeUnitCount = max(0, maximumUnicodeTextByteCount / 2 - 1)

    public static func canPublishUnicodeText(_ text: String) -> Bool {
        guard let byteCount = encodedClipboardUnicodeTextByteCount(text) else {
            return false
        }
        return byteCount <= maximumUnicodeTextByteCount
    }
}

struct RDPClipboardFileContentsRequestPDU: Equatable, Sendable {
    var streamID: UInt32
    var fileIndex: Int32
    var flags: UInt32
    var position: UInt64
    var requestedByteCount: UInt32
    var clipDataID: UInt32?

    static func size(
        streamID: UInt32,
        fileIndex: Int32,
        clipDataID: UInt32? = nil
    ) -> RDPClipboardFileContentsRequestPDU {
        RDPClipboardFileContentsRequestPDU(
            streamID: streamID,
            fileIndex: fileIndex,
            flags: RDPClipboardFileContentsFlags.size,
            position: 0,
            requestedByteCount: 8,
            clipDataID: clipDataID
        )
    }

    static func range(
        streamID: UInt32,
        fileIndex: Int32,
        position: UInt64,
        requestedByteCount: UInt32,
        clipDataID: UInt32? = nil
    ) -> RDPClipboardFileContentsRequestPDU {
        RDPClipboardFileContentsRequestPDU(
            streamID: streamID,
            fileIndex: fileIndex,
            flags: RDPClipboardFileContentsFlags.range,
            position: position,
            requestedByteCount: requestedByteCount,
            clipDataID: clipDataID
        )
    }

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFileContentsRequestPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.fileContentsRequest else {
            return nil
        }
        guard pdu.payload.count == 24 || pdu.payload.count == 28 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let request = try RDPClipboardFileContentsRequestPDU(
            streamID: cursor.readLittleEndianUInt32(),
            fileIndex: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            flags: cursor.readLittleEndianUInt32(),
            position: readClipboardUInt64(from: &cursor),
            requestedByteCount: cursor.readLittleEndianUInt32(),
            clipDataID: cursor.remaining == 4 ? cursor.readLittleEndianUInt32() : nil
        )
        try request.validate()
        return request
    }

    func encoded() throws -> Data {
        try validate()

        var payload = Data()
        payload.appendLittleEndianUInt32(streamID)
        payload.appendLittleEndianUInt32(UInt32(bitPattern: fileIndex))
        payload.appendLittleEndianUInt32(flags)
        payload.appendClipboardUInt64(position)
        payload.appendLittleEndianUInt32(requestedByteCount)
        if let clipDataID {
            payload.appendLittleEndianUInt32(clipDataID)
        }
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.fileContentsRequest,
            payload: payload
        ).encoded()
    }

    private func validate() throws {
        let requestsSize = flags & RDPClipboardFileContentsFlags.size != 0
        let requestsRange = flags & RDPClipboardFileContentsFlags.range != 0
        guard requestsSize != requestsRange else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        if requestsSize {
            guard position == 0,
                  requestedByteCount == 8
            else {
                throw RDPDecodeError.invalidClipboardPDU
            }
        }
    }
}

public struct RDPClipboardFileContentsResponse: Equatable, Sendable {
    public var streamID: UInt32
    public var ok: Bool
    public var data: Data

    public init(streamID: UInt32, ok: Bool, data: Data) {
        self.streamID = streamID
        self.ok = ok
        self.data = data
    }

    public func decodedFileSize() throws -> UInt64 {
        try decodeClipboardFileSize(ok: ok, data: data)
    }
}

struct RDPClipboardFileContentsResponsePDU: Equatable, Sendable {
    var streamID: UInt32
    var ok: Bool
    var data: Data

    init(streamID: UInt32, ok: Bool, data: Data) {
        self.streamID = streamID
        self.ok = ok
        self.data = data
    }

    var response: RDPClipboardFileContentsResponse {
        RDPClipboardFileContentsResponse(streamID: streamID, ok: ok, data: data)
    }

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFileContentsResponsePDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.fileContentsResponse else {
            return nil
        }
        guard pdu.payload.count >= 4 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPClipboardFileContentsResponsePDU(
            streamID: cursor.readLittleEndianUInt32(),
            ok: pdu.header.messageFlags & RDPClipboardMessageFlags.responseOK != 0,
            data: cursor.readRemainingData()
        )
    }

    static func fileSize(
        streamID: UInt32,
        byteCount: UInt64
    ) -> RDPClipboardFileContentsResponsePDU {
        var data = Data()
        data.appendClipboardUInt64(byteCount)
        return RDPClipboardFileContentsResponsePDU(streamID: streamID, ok: true, data: data)
    }

    static func range(
        streamID: UInt32,
        data: Data
    ) -> RDPClipboardFileContentsResponsePDU {
        RDPClipboardFileContentsResponsePDU(streamID: streamID, ok: true, data: data)
    }

    static func failure(streamID: UInt32) -> RDPClipboardFileContentsResponsePDU {
        RDPClipboardFileContentsResponsePDU(streamID: streamID, ok: false, data: Data())
    }

    func encoded() -> Data {
        var payload = Data()
        payload.appendLittleEndianUInt32(streamID)
        payload.append(data)
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.fileContentsResponse,
            messageFlags: ok ? RDPClipboardMessageFlags.responseOK : RDPClipboardMessageFlags.responseFail,
            payload: payload
        ).encoded()
    }

    func decodedFileSize() throws -> UInt64 {
        try decodeClipboardFileSize(ok: ok, data: data)
    }
}

private func decodeClipboardFileSize(ok: Bool, data: Data) throws -> UInt64 {
    guard ok, data.count == 8 else {
        throw RDPDecodeError.invalidClipboardPDU
    }
    var cursor = ByteCursor(data)
    return try readClipboardUInt64(from: &cursor)
}

public final class RDPClipboardSession: @unchecked Sendable {
    public let staticChannelID: UInt16
    private let userChannelID: UInt16
    private let channel: Channel
    private let lock = NSLock()
    private var localContent = RDPClipboardLocalContent.empty
    private var pendingFormatDataResponse: RDPClipboardRequestedFormatDataResponse?
    private var serverGeneralFlags: UInt32 = 0

    init(userChannelID: UInt16, staticChannelID: UInt16, channel: Channel) {
        self.userChannelID = userChannelID
        self.staticChannelID = staticChannelID
        self.channel = channel
    }

    public func publishLocalUnicodeText(_ text: String?) {
        lock.lock()
        if let text {
            localContent = .unicodeText(text)
        } else {
            localContent = .empty
        }
        lock.unlock()

        if text == nil {
            send(RDPClipboardFormatListPDU(formatIDs: []).encoded())
        } else {
            send(RDPClipboardFormatListPDU.unicodeText().encoded())
        }
    }

    public func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        guard files.isEmpty == false else {
            publishLocalUnicodeText(nil)
            return
        }

        lock.lock()
        localContent = .files(files)
        lock.unlock()

        send(RDPClipboardFormatListPDU(entries: [
            RDPClipboardFormatListEntry(
                formatID: RDPClipboardLocalFormatID.fileGroupDescriptorW,
                formatName: RDPClipboardRegisteredFormatName.fileGroupDescriptorW
            ),
            RDPClipboardFormatListEntry(
                formatID: RDPClipboardLocalFormatID.fileContents,
                formatName: RDPClipboardRegisteredFormatName.fileContents
            ),
        ]).encoded())
    }

    func updateServerCapabilities(_ capabilities: RDPClipboardCapabilitiesPDU) {
        lock.lock()
        serverGeneralFlags = capabilities.generalFlags
        lock.unlock()
    }

    func sendClientCapabilities() {
        send(RDPClipboardCapabilitiesPDU().encoded())
    }

    func sendFormatListResponse(ok: Bool) {
        send(RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatListResponse,
            messageFlags: ok ? RDPClipboardMessageFlags.responseOK : RDPClipboardMessageFlags.responseFail
        ).encoded())
    }

    func requestUnicodeText() {
        updatePendingFormatDataResponse(.unicodeText)
        send(RDPClipboardFormatDataRequestPDU(formatID: RDPClipboardFormatID.unicodeText).encoded())
    }

    func requestFileGroupDescriptorW(formatID: UInt32) {
        updatePendingFormatDataResponse(.fileGroupDescriptorW(formatID: formatID))
        send(RDPClipboardFormatDataRequestPDU(formatID: formatID).encoded())
    }

    public func requestRemoteFileSize(streamID: UInt32, fileIndex: Int32, clipDataID: UInt32? = nil) throws {
        try send(RDPClipboardFileContentsRequestPDU.size(
            streamID: streamID,
            fileIndex: fileIndex,
            clipDataID: clipDataID
        ).encoded())
    }

    public func requestRemoteFileRange(
        streamID: UInt32,
        fileIndex: Int32,
        position: UInt64,
        requestedByteCount: UInt32,
        clipDataID: UInt32? = nil
    ) throws {
        try send(RDPClipboardFileContentsRequestPDU.range(
            streamID: streamID,
            fileIndex: fileIndex,
            position: position,
            requestedByteCount: requestedByteCount,
            clipDataID: clipDataID
        ).encoded())
    }

    func takePendingFormatDataResponse() -> RDPClipboardRequestedFormatDataResponse? {
        lock.lock()
        defer { lock.unlock() }
        let pending = pendingFormatDataResponse
        pendingFormatDataResponse = nil
        return pending
    }

    func respondToFormatDataRequest(_ request: RDPClipboardFormatDataRequestPDU) {
        switch currentContent() {
        case let .unicodeText(text) where request.formatID == RDPClipboardFormatID.unicodeText:
            guard let response = RDPClipboardFormatDataResponsePDU.unicodeTextIfEncodable(text) else {
                send(RDPClipboardFormatDataResponsePDU.failure().encoded())
                return
            }
            send(response.encoded())
        case let .files(files) where request.formatID == RDPClipboardLocalFormatID.fileGroupDescriptorW:
            let descriptors = files.map(\.descriptor)
            let response = RDPClipboardFormatDataResponsePDU.fileGroupDescriptorW(
                RDPClipboardFileGroupDescriptorW(descriptors: descriptors)
            )
            send(response.encoded())
        case .empty, .unicodeText, .files:
            send(RDPClipboardFormatDataResponsePDU.failure().encoded())
        }
    }

    func respondToFileContentsRequest(_ request: RDPClipboardFileContentsRequestPDU) {
        guard case let .files(files) = currentContent(),
              request.fileIndex >= 0,
              Int(request.fileIndex) < files.count
        else {
            send(RDPClipboardFileContentsResponsePDU.failure(streamID: request.streamID).encoded())
            return
        }

        let file = files[Int(request.fileIndex)]
        if request.flags & RDPClipboardFileContentsFlags.size != 0 {
            send(RDPClipboardFileContentsResponsePDU.fileSize(
                streamID: request.streamID,
                byteCount: file.descriptor.fileSize
            ).encoded())
            return
        }

        guard request.flags & RDPClipboardFileContentsFlags.range != 0,
              request.position <= UInt64(file.contents.count),
              UInt64(request.requestedByteCount) <= UInt64(file.contents.count) - request.position,
              let lowerBound = Int(exactly: request.position),
              let requestedByteCount = Int(exactly: request.requestedByteCount)
        else {
            send(RDPClipboardFileContentsResponsePDU.failure(streamID: request.streamID).encoded())
            return
        }

        let upperBound = lowerBound + requestedByteCount
        send(RDPClipboardFileContentsResponsePDU.range(
            streamID: request.streamID,
            data: file.contents.subdata(in: lowerBound ..< upperBound)
        ).encoded())
    }

    private func currentContent() -> RDPClipboardLocalContent {
        lock.lock()
        defer { lock.unlock() }
        return localContent
    }

    private func updatePendingFormatDataResponse(_ pending: RDPClipboardRequestedFormatDataResponse) {
        lock.lock()
        pendingFormatDataResponse = pending
        lock.unlock()
    }

    @discardableResult
    private func send(_ payload: Data) -> Bool {
        guard RDPStaticVirtualChannelPDU.canEncodeSinglePayload(payload) else {
            return false
        }

        let packet = RDPStaticVirtualChannelPDU(payload: payload)
            .encodedTPKT(initiator: userChannelID, channelID: staticChannelID)
        channel.eventLoop.execute {
            guard self.channel.isActive else {
                return
            }
            var buffer = self.channel.allocator.buffer(capacity: packet.count)
            buffer.writeBytes(packet)
            self.channel.writeAndFlush(buffer, promise: nil)
        }
        return true
    }
}

private enum RDPClipboardLocalContent: Equatable, Sendable {
    case empty
    case unicodeText(String)
    case files([RDPClipboardLocalFile])
}

enum RDPClipboardRequestedFormatDataResponse: Equatable, Sendable {
    case unicodeText
    case fileGroupDescriptorW(formatID: UInt32)
}

private func encodedClipboardUnicodeText(_ text: String) -> Data {
    var data = Data()
    for codeUnit in text.utf16 {
        data.appendLittleEndianUInt16(codeUnit)
    }
    data.appendLittleEndianUInt16(0)
    return data
}

private func encodedClipboardUnicodeTextByteCount(_ text: String) -> Int? {
    let (codeUnitCountWithTerminator, didOverflowTerminator) = text.utf16.count.addingReportingOverflow(1)
    guard !didOverflowTerminator else {
        return nil
    }

    let (byteCount, didOverflowBytes) = codeUnitCountWithTerminator.multipliedReportingOverflow(by: 2)
    guard !didOverflowBytes else {
        return nil
    }
    return byteCount
}

private func decodeClipboardUnicodeText(_ data: Data) throws -> String {
    guard data.count.isMultiple(of: 2) else {
        throw RDPDecodeError.invalidClipboardPDU
    }
    var cursor = ByteCursor(data)
    var codeUnits: [UInt16] = []
    while cursor.remaining > 0 {
        let codeUnit = try cursor.readLittleEndianUInt16()
        guard codeUnit != 0 else {
            break
        }
        codeUnits.append(codeUnit)
    }
    return String(decoding: codeUnits, as: UTF16.self)
}

private func decodeClipboardFixedUnicodeString(_ data: Data) throws -> String {
    guard data.count.isMultiple(of: 2) else {
        throw RDPDecodeError.invalidClipboardPDU
    }
    var cursor = ByteCursor(data)
    var codeUnits: [UInt16] = []
    while cursor.remaining > 0 {
        let codeUnit = try cursor.readLittleEndianUInt16()
        guard codeUnit != 0 else {
            break
        }
        codeUnits.append(codeUnit)
    }
    return String(decoding: codeUnits, as: UTF16.self)
}

private func appendFixedUnicodeFileName(_ fileName: String, to data: inout Data) {
    var codeUnits = Array(fileName.utf16.prefix(259))
    codeUnits.append(0)
    for codeUnit in codeUnits {
        data.appendLittleEndianUInt16(codeUnit)
    }
    for _ in codeUnits.count ..< 260 {
        data.appendLittleEndianUInt16(0)
    }
}

private func readClipboardUInt64(from cursor: inout ByteCursor) throws -> UInt64 {
    let low = try cursor.readLittleEndianUInt32()
    let high = try cursor.readLittleEndianUInt32()
    return UInt64(high) << 32 | UInt64(low)
}

private func decodeClipboardASCIIFormatName(_ data: Data) -> String? {
    let bytes = data.prefix { $0 != 0 }
    guard bytes.isEmpty == false else {
        return nil
    }
    return String(data: Data(bytes), encoding: .ascii)
}

private extension Data {
    mutating func appendClipboardUInt64(_ value: UInt64) {
        appendLittleEndianUInt32(UInt32(value & 0xFFFF_FFFF))
        appendLittleEndianUInt32(UInt32((value >> 32) & 0xFFFF_FFFF))
    }
}

private func decodeClipboardUnicodeFormatName(_ codeUnits: [UInt16]) -> String? {
    guard codeUnits.isEmpty == false else {
        return nil
    }
    return String(decoding: codeUnits, as: UTF16.self)
}
