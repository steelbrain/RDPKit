import Foundation
@preconcurrency import NIOCore

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
    public static let attributes: UInt32 = 0x0000_0004
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
    static let temporaryDirectory: UInt16 = 0x0006
    static let clipboardCapabilities: UInt16 = 0x0007
    static let fileContentsRequest: UInt16 = 0x0008
    static let fileContentsResponse: UInt16 = 0x0009
    static let lockClipdata: UInt16 = 0x000A
    static let unlockClipdata: UInt16 = 0x000B
}

enum RDPClipboardMessageFlags {
    static let responseOK: UInt16 = 0x0001
    static let responseFail: UInt16 = 0x0002
    static let asciiNames: UInt16 = 0x0004
}

enum RDPClipboardCapabilityFlags {
    static let useLongFormatNames: UInt32 = 0x0000_0002
    static let streamFileClipEnabled: UInt32 = 0x0000_0004
}

private enum RDPClipboardCapabilitySetType {
    static let general: UInt16 = 0x0001
}

enum RDPClipboardFileContentsFlags {
    static let size: UInt32 = 0x0000_0001
    static let range: UInt32 = 0x0000_0002
    static let supportedMask: UInt32 = size | range
}

private func hasValidClipboardResponseFlags(_ flags: UInt16) -> Bool {
    flags == RDPClipboardMessageFlags.responseOK
        || flags == RDPClipboardMessageFlags.responseFail
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

/// Called with each PDU the session sends and its first channel packet, on the sending thread.
typealias RDPClipboardSentMessageHandler = @Sendable (RDPClipboardMessageSummary, Data) -> Void

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
        case RDPClipboardMessageType.temporaryDirectory:
            "clipboard-temporary-directory"
        case RDPClipboardMessageType.clipboardCapabilities:
            "clipboard-capabilities"
        case RDPClipboardMessageType.fileContentsRequest:
            "clipboard-file-contents-request"
        case RDPClipboardMessageType.fileContentsResponse:
            "clipboard-file-contents-response"
        case RDPClipboardMessageType.lockClipdata:
            "clipboard-lock-clipdata"
        case RDPClipboardMessageType.unlockClipdata:
            "clipboard-unlock-clipdata"
        default:
            "clipboard-0x\(String(format: "%04x", header.messageType))"
        }
    }

    static func parse(from data: Data) throws -> RDPClipboardPDU {
        guard data.count >= headerByteCount else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(data)
        let header = try RDPClipboardHeader.parse(from: &cursor)
        guard let dataLength = Int(exactly: header.dataLength),
              dataLength <= cursor.remaining
        else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        // Windows Server 2003 through 2012 R2 append four bytes that dataLen
        // does not count (MS-RDPECLIP 2.2.1, Appendix A <1>).
        let trailingByteCount = cursor.remaining - dataLength
        guard trailingByteCount == 0 || trailingByteCount == 4 else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        return try RDPClipboardPDU(header: header, payload: cursor.readData(count: dataLength))
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

struct RDPClipboardTemporaryDirectoryPDU: Equatable, Sendable {
    private static let pathBufferUTF16CodeUnitCount = 260

    var path: String

    init(path: String = "/tmp") {
        self.path = path
    }

    func encoded() -> Data {
        var payload = Data()
        appendFixedUnicodeString(path, codeUnitCount: Self.pathBufferUTF16CodeUnitCount, to: &payload)
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.temporaryDirectory,
            payload: payload
        ).encoded()
    }
}

struct RDPClipboardCapabilitiesPDU: Equatable, Sendable {
    static let defaultGeneralFlags: UInt32 = RDPClipboardCapabilityFlags.useLongFormatNames
        | RDPClipboardCapabilityFlags.streamFileClipEnabled

    var version: UInt32
    var generalFlags: UInt32

    init(
        version: UInt32 = 2,
        generalFlags: UInt32 = RDPClipboardCapabilitiesPDU.defaultGeneralFlags
    ) {
        self.version = version
        self.generalFlags = generalFlags
    }

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardCapabilitiesPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.clipboardCapabilities else {
            return nil
        }
        guard pdu.header.messageFlags == 0,
              pdu.payload.count >= 4
        else {
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
            // CLIPRDR_CAPS_SET is a type-length wrapper (MS-RDPECLIP 2.2.2.1.1), so
            // unknown sets are skipped; unknown generalFlags bits are simply not used.
            guard type == RDPClipboardCapabilitySetType.general else {
                continue
            }
            guard body.count == 8, generalCapability == nil else {
                throw RDPDecodeError.invalidClipboardPDU
            }
            var bodyCursor = ByteCursor(body)
            generalCapability = try RDPClipboardCapabilitiesPDU(
                version: bodyCursor.readLittleEndianUInt32(),
                generalFlags: bodyCursor.readLittleEndianUInt32()
            )
        }
        guard cursor.remaining == 0 else {
            throw RDPDecodeError.invalidClipboardPDU
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

    var fileGroupDescriptorWFormatID: UInt32? {
        entries.first { entry in
            entry.formatName?.caseInsensitiveCompare(RDPClipboardRegisteredFormatName.fileGroupDescriptorW)
                == .orderedSame
        }?.formatID
    }

    static func parseIfPresent(
        from pdu: RDPClipboardPDU,
        useLongFormatNames: Bool = true
    ) throws -> RDPClipboardFormatListPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.formatList else {
            return nil
        }
        guard pdu.header.messageFlags == 0
            || pdu.header.messageFlags == RDPClipboardMessageFlags.asciiNames
        else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        if pdu.payload.isEmpty {
            return RDPClipboardFormatListPDU(entries: [])
        }
        let hasASCIINames = pdu.header.messageFlags == RDPClipboardMessageFlags.asciiNames
        if hasASCIINames || !useLongFormatNames {
            return try parseShortFormatNames(from: pdu.payload, ascii: hasASCIINames)
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
                formatName: String(decoding: formatNameCodeUnits, as: UTF16.self)
            ))
        }
        return RDPClipboardFormatListPDU(entries: entries)
    }

    func encoded(useLongFormatNames: Bool = true) -> Data {
        if !useLongFormatNames {
            return encodedShortASCIIFormatNames()
        }

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

    /// Short Format Name variant: 32-byte names, ASCII when CB_ASCII_NAMES is set and UTF-16LE otherwise.
    private static func parseShortFormatNames(from payload: Data, ascii: Bool) throws -> RDPClipboardFormatListPDU {
        guard payload.count.isMultiple(of: 36) else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(payload)
        var entries: [RDPClipboardFormatListEntry] = []
        while cursor.remaining > 0 {
            let formatID = try cursor.readLittleEndianUInt32()
            let nameData = try cursor.readData(count: 32)
            entries.append(try RDPClipboardFormatListEntry(
                formatID: formatID,
                formatName: ascii
                    ? String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
                    : decodeNullTerminatedUTF16(nameData)
            ))
        }
        return RDPClipboardFormatListPDU(entries: entries)
    }

    private func encodedShortASCIIFormatNames() -> Data {
        var payload = Data()
        for entry in entries {
            payload.appendLittleEndianUInt32(entry.formatID)
            let nameBytes = entry.formatName.flatMap { Data($0.utf8.prefix(31)) } ?? Data()
            payload.append(nameBytes)
            payload.append(Data(repeating: 0, count: 32 - nameBytes.count))
        }
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatList,
            messageFlags: RDPClipboardMessageFlags.asciiNames,
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
        guard pdu.header.messageFlags == 0,
              pdu.payload.count == 4
        else {
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
    var ok: Bool
    var data: Data

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFormatDataResponsePDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.formatDataResponse else {
            return nil
        }
        guard hasValidClipboardResponseFlags(pdu.header.messageFlags) else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        let ok = pdu.header.messageFlags == RDPClipboardMessageFlags.responseOK
        return RDPClipboardFormatDataResponsePDU(ok: ok, data: pdu.payload)
    }

    static func unicodeText(_ text: String) -> RDPClipboardFormatDataResponsePDU {
        RDPClipboardFormatDataResponsePDU(ok: true, data: encodedClipboardUnicodeText(text))
    }

    static func unicodeTextIfEncodable(_ text: String) -> RDPClipboardFormatDataResponsePDU? {
        RDPClipboardLimits.canPublishUnicodeText(text) ? unicodeText(text) : nil
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

    /// CRLF line ends of CF_UNICODETEXT become the LF line ends of Apple text.
    func decodedUnicodeText() throws -> String {
        try decodeNullTerminatedUTF16(data).replacingOccurrences(of: "\r\n", with: "\n")
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

    /// Longest file name, in UTF-8 bytes, that APFS and HFS+ accept.
    private static let maximumFileNameByteCount = 255

    fileprivate static func uniqueFileName(
        _ fileName: String,
        usedFileNames: inout Set<String>
    ) -> String {
        let sanitized = sanitizedFileName(fileName) as NSString
        let extensionText = sanitized.pathExtension.isEmpty ? "" : ".\(sanitized.pathExtension)"
        var candidate = sanitized as String
        var suffix = 2
        while usedFileNames.contains(candidate.lowercased()) {
            // Check the name the initializer stores, which sanitizes again.
            candidate = sanitizedFileName(
                Self.fileName(sanitized.deletingPathExtension, suffix: "-\(suffix)\(extensionText)")
            )
            suffix += 1
        }
        usedFileNames.insert(candidate.lowercased())
        return candidate
    }

    /// Reduces a remote, untrusted name to a single file name component that cannot be "." or "..".
    private static func sanitizedFileName(_ fileName: String) -> String {
        let lastPathComponent = fileName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let invalidCharacters = CharacterSet(charactersIn: ":")
            .union(.controlCharacters)
            .union(.newlines)
        var sanitizedScalars = String.UnicodeScalarView()
        for scalar in lastPathComponent.unicodeScalars {
            sanitizedScalars.append(invalidCharacters.contains(scalar) ? "_" : scalar)
        }
        var sanitized = String(sanitizedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.utf8.count > maximumFileNameByteCount {
            let name = sanitized as NSString
            sanitized = Self.fileName(
                name.deletingPathExtension,
                suffix: name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard sanitized.isEmpty == false, sanitized != ".", sanitized != ".." else {
            return "remote-file"
        }
        return sanitized
    }

    /// Joins `baseName` and `suffix`, shortening the base name to fit the file name byte limit.
    private static func fileName(_ baseName: String, suffix: String) -> String {
        let baseName = utf8Prefix(baseName, maximumByteCount: max(1, maximumFileNameByteCount - suffix.utf8.count))
        return utf8Prefix(baseName + suffix, maximumByteCount: maximumFileNameByteCount)
    }

    /// Cuts by Unicode scalar, so one oversized grapheme cluster is shortened rather than dropped.
    private static func utf8Prefix(_ text: String, maximumByteCount: Int) -> String {
        var byteCount = 0
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix { scalar in
            byteCount += UTF8.width(scalar)
            return byteCount <= maximumByteCount
        }))
    }
}

public struct RDPClipboardFileDescriptorW: Equatable, Sendable {
    static let byteCount = 592
    private static let maximumFileNameCodeUnitCount = 260

    public var flags: UInt32
    public var fileAttributes: UInt32
    public var lastWriteTime: UInt64
    public var fileSize: UInt64
    public var fileName: String

    public init(
        flags: UInt32,
        fileAttributes: UInt32,
        lastWriteTime: UInt64 = 0,
        fileSize: UInt64,
        fileName: String
    ) {
        self.flags = flags
        self.fileAttributes = fileAttributes
        self.lastWriteTime = lastWriteTime
        self.fileSize = fileSize
        self.fileName = fileName
    }

    public var isDirectory: Bool {
        fileAttributes & RDPClipboardFileAttributes.directory != 0
    }

    /// CLIPRDR_FILEDESCRIPTOR (MS-RDPECLIP 2.2.5.2.3.1); reserved1 and reserved2 are ignored.
    static func parse(from cursor: inout ByteCursor) throws -> RDPClipboardFileDescriptorW {
        let flags = try cursor.readLittleEndianUInt32()
        _ = try cursor.readData(count: 32)
        let fileAttributes = try cursor.readLittleEndianUInt32()
        _ = try cursor.readData(count: 16)
        let lastWriteTime = try cursor.readLittleEndianUInt64()
        let fileSizeHigh = try cursor.readLittleEndianUInt32()
        let fileSizeLow = try cursor.readLittleEndianUInt32()
        let fileNameData = try cursor.readData(count: maximumFileNameCodeUnitCount * 2)

        return try RDPClipboardFileDescriptorW(
            flags: flags,
            fileAttributes: fileAttributes,
            lastWriteTime: lastWriteTime,
            fileSize: UInt64(fileSizeHigh) << 32 | UInt64(fileSizeLow),
            fileName: decodeNullTerminatedUTF16(fileNameData)
        )
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(flags)
        data.append(Data(repeating: 0, count: 32))
        data.appendLittleEndianUInt32(fileAttributes)
        data.append(Data(repeating: 0, count: 16))
        data.appendLittleEndianUInt64(lastWriteTime)
        data.appendLittleEndianUInt32(UInt32(fileSize >> 32))
        data.appendLittleEndianUInt32(UInt32(truncatingIfNeeded: fileSize))
        appendFixedUnicodeString(fileName, codeUnitCount: Self.maximumFileNameCodeUnitCount, to: &data)
        return data
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
    /// Largest CF_UNICODETEXT payload, terminator included, that the session sends.
    public static let maximumUnicodeTextByteCount = 16 * 1024 * 1024

    /// Counted after LF line ends become CRLF, as they are sent.
    public static let maximumUnicodeTextUTF16CodeUnitCount = maximumUnicodeTextByteCount / 2 - 1

    public static func canPublishUnicodeText(_ text: String) -> Bool {
        var codeUnitCount = 0
        forEachClipboardUnicodeTextCodeUnit(of: text) { _ in codeUnitCount += 1 }
        return codeUnitCount <= maximumUnicodeTextUTF16CodeUnitCount
    }
}

struct RDPClipboardFileContentsRequestPDU: Equatable, Sendable {
    var streamID: UInt32
    var fileIndex: Int32
    var flags: UInt32
    var position: UInt64
    var requestedByteCount: UInt32

    static func size(streamID: UInt32, fileIndex: Int32) -> RDPClipboardFileContentsRequestPDU {
        RDPClipboardFileContentsRequestPDU(
            streamID: streamID,
            fileIndex: fileIndex,
            flags: RDPClipboardFileContentsFlags.size,
            position: 0,
            requestedByteCount: 8
        )
    }

    static func range(
        streamID: UInt32,
        fileIndex: Int32,
        position: UInt64,
        requestedByteCount: UInt32
    ) -> RDPClipboardFileContentsRequestPDU {
        RDPClipboardFileContentsRequestPDU(
            streamID: streamID,
            fileIndex: fileIndex,
            flags: RDPClipboardFileContentsFlags.range,
            position: position,
            requestedByteCount: requestedByteCount
        )
    }

    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFileContentsRequestPDU? {
        guard pdu.header.messageType == RDPClipboardMessageType.fileContentsRequest else {
            return nil
        }
        // The trailing clipDataId is only meaningful with CB_CAN_LOCK_CLIPDATA, which this client
        // never advertises, so it is accepted and ignored (MS-RDPECLIP 2.2.5.3).
        guard pdu.header.messageFlags == 0,
              pdu.payload.count == 24 || pdu.payload.count == 28
        else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(pdu.payload)
        let request = try RDPClipboardFileContentsRequestPDU(
            streamID: cursor.readLittleEndianUInt32(),
            fileIndex: Int32(bitPattern: cursor.readLittleEndianUInt32()),
            flags: cursor.readLittleEndianUInt32(),
            position: cursor.readLittleEndianUInt64(),
            requestedByteCount: cursor.readLittleEndianUInt32()
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
        payload.appendLittleEndianUInt64(position)
        payload.appendLittleEndianUInt32(requestedByteCount)
        return RDPClipboardPDU(
            messageType: RDPClipboardMessageType.fileContentsRequest,
            payload: payload
        ).encoded()
    }

    private func validate() throws {
        guard flags & ~RDPClipboardFileContentsFlags.supportedMask == 0 else {
            throw RDPDecodeError.invalidClipboardPDU
        }
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
        guard ok, data.count == 8 else {
            throw RDPDecodeError.invalidClipboardPDU
        }
        var cursor = ByteCursor(data)
        return try cursor.readLittleEndianUInt64()
    }
}

extension RDPClipboardFileContentsResponse {
    static func parseIfPresent(from pdu: RDPClipboardPDU) throws -> RDPClipboardFileContentsResponse? {
        guard pdu.header.messageType == RDPClipboardMessageType.fileContentsResponse else {
            return nil
        }
        guard hasValidClipboardResponseFlags(pdu.header.messageFlags),
              pdu.payload.count >= 4
        else {
            throw RDPDecodeError.invalidClipboardPDU
        }

        var cursor = ByteCursor(pdu.payload)
        return try RDPClipboardFileContentsResponse(
            streamID: cursor.readLittleEndianUInt32(),
            ok: pdu.header.messageFlags == RDPClipboardMessageFlags.responseOK,
            data: cursor.readRemainingData()
        )
    }

    static func fileSize(
        streamID: UInt32,
        byteCount: UInt64
    ) -> RDPClipboardFileContentsResponse {
        var data = Data()
        data.appendLittleEndianUInt64(byteCount)
        return RDPClipboardFileContentsResponse(streamID: streamID, ok: true, data: data)
    }

    static func range(
        streamID: UInt32,
        data: Data
    ) -> RDPClipboardFileContentsResponse {
        RDPClipboardFileContentsResponse(streamID: streamID, ok: true, data: data)
    }

    static func failure(streamID: UInt32) -> RDPClipboardFileContentsResponse {
        RDPClipboardFileContentsResponse(streamID: streamID, ok: false, data: Data())
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
}

public final class RDPClipboardSession: @unchecked Sendable {
    public let staticChannelID: UInt16
    private let userChannelID: UInt16
    private let channel: Channel
    private let sentMessageHandler: RDPClipboardSentMessageHandler?
    private let lock = NSLock()
    private var localContent = RDPClipboardLocalContent.empty
    private var pendingFormatDataResponses: [RDPClipboardRequestedFormatDataResponse] = []
    /// nil until the server sends its Clipboard Capabilities PDU.
    private var serverGeneralFlags: UInt32?
    /// Flags this client advertised; 0, the protocol default, when it sent no Capabilities PDU.
    private var negotiatedGeneralFlags: UInt32 = 0
    /// Format Lists wait for the initialization sequence (MS-RDPECLIP 1.3.2.1).
    private var hasAnsweredMonitorReady = false

    init(
        userChannelID: UInt16,
        staticChannelID: UInt16,
        channel: Channel,
        sentMessageHandler: RDPClipboardSentMessageHandler? = nil
    ) {
        self.userChannelID = userChannelID
        self.staticChannelID = staticChannelID
        self.channel = channel
        self.sentMessageHandler = sentMessageHandler
    }

    public func publishLocalUnicodeText(_ text: String?) {
        publish(text.map { .unicodeText($0) } ?? .empty)
    }

    public func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        publish(files.isEmpty ? .empty : .files(files))
    }

    /// Handles one complete cliprdr PDU from the server, sends the replies the protocol
    /// requires, and returns what the application should be told about.
    func receive(_ pdu: RDPClipboardPDU) throws -> RDPClipboardEvent? {
        do {
            return try handle(pdu)
        } catch {
            sendFailureResponse(to: pdu)
            throw error
        }
    }

    private func handle(_ pdu: RDPClipboardPDU) throws -> RDPClipboardEvent? {
        if let capabilities = try RDPClipboardCapabilitiesPDU.parseIfPresent(from: pdu) {
            updateServerCapabilities(capabilities)
            return nil
        }
        if pdu.header.messageType == RDPClipboardMessageType.monitorReady {
            respondToMonitorReady()
            return .ready
        }
        if let formatList = try RDPClipboardFormatListPDU.parseIfPresent(
            from: pdu,
            useLongFormatNames: usesLongFormatNames
        ) {
            sendFormatListResponse(ok: true)
            if let formatID = formatList.fileGroupDescriptorWFormatID {
                requestFileGroupDescriptorW(formatID: formatID)
            } else if formatList.formatIDs.contains(RDPClipboardFormatID.unicodeText) {
                requestUnicodeText()
            }
            return nil
        }
        if let request = try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: pdu) {
            respondToFormatDataRequest(request)
            return nil
        }
        if let request = try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: pdu) {
            respondToFileContentsRequest(request)
            return nil
        }
        if let response = try RDPClipboardFileContentsResponse.parseIfPresent(from: pdu) {
            return .fileContents(response)
        }
        if let response = try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu) {
            // A response with no outstanding request has nothing to decode against and is dropped.
            guard let pending = takePendingFormatDataResponse(), response.ok else {
                return nil
            }
            switch pending {
            case .unicodeText:
                return try .text(response.decodedUnicodeText())
            case .fileGroupDescriptorW:
                return try .fileGroupDescriptor(response.decodedFileGroupDescriptorW())
            }
        }
        return nil
    }

    /// The server waits for an answer to these even when they cannot be processed, and
    /// MS-RDPECLIP requires a failure response (3.1.5.2.2, 3.1.5.4.3, 3.1.5.4.6).
    private func sendFailureResponse(to pdu: RDPClipboardPDU) {
        switch pdu.header.messageType {
        case RDPClipboardMessageType.formatList:
            sendFormatListResponse(ok: false)
        case RDPClipboardMessageType.formatDataRequest:
            send(RDPClipboardFormatDataResponsePDU.failure().encoded())
        case RDPClipboardMessageType.fileContentsRequest:
            var cursor = ByteCursor(pdu.payload)
            if let streamID = try? cursor.readLittleEndianUInt32() {
                send(RDPClipboardFileContentsResponse.failure(streamID: streamID).encoded())
            }
        default:
            break
        }
    }

    private func updateServerCapabilities(_ capabilities: RDPClipboardCapabilitiesPDU) {
        lock.lock()
        serverGeneralFlags = capabilities.generalFlags
        lock.unlock()
    }

    /// Long names are used only when both endpoints advertised them (MS-RDPECLIP 2.2.2.1.1.1).
    private var usesLongFormatNames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return negotiatedGeneralFlags & RDPClipboardCapabilityFlags.useLongFormatNames != 0
    }

    /// Answers the Monitor Ready PDU (MS-RDPECLIP 3.2.5.1.2): Capabilities when the server sent
    /// its own, the Temporary Directory, then the mandatory Format List of the local content.
    private func respondToMonitorReady() {
        lock.lock()
        let serverGeneralFlags = serverGeneralFlags
        if let serverGeneralFlags {
            negotiatedGeneralFlags = Self.clientGeneralFlags(serverGeneralFlags: serverGeneralFlags)
        }
        let clientGeneralFlags = negotiatedGeneralFlags
        lock.unlock()

        if serverGeneralFlags != nil {
            send(RDPClipboardCapabilitiesPDU(generalFlags: clientGeneralFlags).encoded())
        }
        send(RDPClipboardTemporaryDirectoryPDU().encoded())

        lock.lock()
        defer { lock.unlock() }
        hasAnsweredMonitorReady = true
        sendFormatList(for: localContent)
    }

    static func clientGeneralFlags(serverGeneralFlags: UInt32) -> UInt32 {
        serverGeneralFlags & RDPClipboardCapabilitiesPDU.defaultGeneralFlags
    }

    private func sendFormatListResponse(ok: Bool) {
        send(RDPClipboardPDU(
            messageType: RDPClipboardMessageType.formatListResponse,
            messageFlags: ok ? RDPClipboardMessageFlags.responseOK : RDPClipboardMessageFlags.responseFail
        ).encoded())
    }

    func requestUnicodeText() {
        requestFormatData(formatID: RDPClipboardFormatID.unicodeText, expecting: .unicodeText)
    }

    func requestFileGroupDescriptorW(formatID: UInt32) {
        requestFormatData(formatID: formatID, expecting: .fileGroupDescriptorW(formatID: formatID))
    }

    public func requestRemoteFileSize(streamID: UInt32, fileIndex: Int32) throws {
        try send(RDPClipboardFileContentsRequestPDU.size(streamID: streamID, fileIndex: fileIndex).encoded())
    }

    public func requestRemoteFileRange(
        streamID: UInt32,
        fileIndex: Int32,
        position: UInt64,
        requestedByteCount: UInt32
    ) throws {
        try send(RDPClipboardFileContentsRequestPDU.range(
            streamID: streamID,
            fileIndex: fileIndex,
            position: position,
            requestedByteCount: requestedByteCount
        ).encoded())
    }

    /// Format Data Responses arrive in request order, so the oldest outstanding request is answered first.
    func takePendingFormatDataResponse() -> RDPClipboardRequestedFormatDataResponse? {
        lock.lock()
        defer { lock.unlock() }
        return pendingFormatDataResponses.isEmpty ? nil : pendingFormatDataResponses.removeFirst()
    }

    private func respondToFormatDataRequest(_ request: RDPClipboardFormatDataRequestPDU) {
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
            send(RDPClipboardFileContentsResponse.failure(streamID: request.streamID).encoded())
            return
        }

        let file = files[Int(request.fileIndex)]
        if request.flags & RDPClipboardFileContentsFlags.size != 0 {
            send(RDPClipboardFileContentsResponse.fileSize(
                streamID: request.streamID,
                byteCount: file.descriptor.fileSize
            ).encoded())
            return
        }

        // cbRequested is an upper bound; a range that runs past the end of the
        // file returns the bytes that remain (MS-RDPECLIP 2.2.5.3).
        guard request.position <= UInt64(file.contents.count) else {
            send(RDPClipboardFileContentsResponse.failure(streamID: request.streamID).encoded())
            return
        }
        let lowerBound = file.contents.startIndex + Int(request.position)
        let upperBound = lowerBound + min(Int(request.requestedByteCount), file.contents.endIndex - lowerBound)
        send(RDPClipboardFileContentsResponse.range(
            streamID: request.streamID,
            data: file.contents.subdata(in: lowerBound ..< upperBound)
        ).encoded())
    }

    private func publish(_ content: RDPClipboardLocalContent) {
        lock.lock()
        defer { lock.unlock() }
        localContent = content
        if hasAnsweredMonitorReady {
            sendFormatList(for: content)
        }
    }

    /// Callers hold `lock`, so Format Lists go out in the order the local content
    /// changed and the server's last one always matches `localContent`.
    private func sendFormatList(for content: RDPClipboardLocalContent) {
        let entries: [RDPClipboardFormatListEntry] = switch content {
        case .empty:
            []
        case .unicodeText:
            [RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText)]
        case .files:
            [
                RDPClipboardFormatListEntry(
                    formatID: RDPClipboardLocalFormatID.fileGroupDescriptorW,
                    formatName: RDPClipboardRegisteredFormatName.fileGroupDescriptorW
                ),
                RDPClipboardFormatListEntry(
                    formatID: RDPClipboardLocalFormatID.fileContents,
                    formatName: RDPClipboardRegisteredFormatName.fileContents
                ),
            ]
        }
        let useLongFormatNames = negotiatedGeneralFlags & RDPClipboardCapabilityFlags.useLongFormatNames != 0
        send(RDPClipboardFormatListPDU(entries: entries).encoded(useLongFormatNames: useLongFormatNames))
    }

    private func requestFormatData(formatID: UInt32, expecting response: RDPClipboardRequestedFormatDataResponse) {
        lock.lock()
        pendingFormatDataResponses.append(response)
        lock.unlock()
        send(RDPClipboardFormatDataRequestPDU(formatID: formatID).encoded())
    }

    private func currentContent() -> RDPClipboardLocalContent {
        lock.lock()
        defer { lock.unlock() }
        return localContent
    }

    private func send(_ payload: Data) {
        let packets = RDPStaticVirtualChannelPDU.encodedTPKTs(
            payload: payload,
            flags: RDPStaticVirtualChannelFlags.showProtocol,
            initiator: userChannelID,
            channelID: staticChannelID
        )
        if let sentMessageHandler, let pdu = try? RDPClipboardPDU.parse(from: payload), let first = packets.first {
            sentMessageHandler(.summarize(pdu), first)
        }
        channel.eventLoop.execute {
            guard self.channel.isActive else {
                return
            }
            for packet in packets {
                var buffer = self.channel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                self.channel.write(buffer, promise: nil)
            }
            self.channel.flush()
        }
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

enum RDPClipboardEvent: Equatable, Sendable {
    /// Monitor Ready was answered; the session can publish local content.
    case ready
    case text(String)
    case fileGroupDescriptor(RDPClipboardFileGroupDescriptorW)
    case fileContents(RDPClipboardFileContentsResponse)
}

private func encodedClipboardUnicodeText(_ text: String) -> Data {
    var codeUnits: [UInt16] = []
    codeUnits.reserveCapacity(text.utf16.count + 1)
    forEachClipboardUnicodeTextCodeUnit(of: text) { codeUnits.append($0.littleEndian) }
    codeUnits.append(0)
    return codeUnits.withUnsafeBytes { Data($0) }
}

/// CF_UNICODETEXT ends every line with CRLF (Standard Clipboard Formats), so each LF of
/// Apple text that has no CR before it is sent as CRLF.
private func forEachClipboardUnicodeTextCodeUnit(of text: String, _ body: (UInt16) -> Void) {
    let carriageReturn: UInt16 = 0x000D
    let lineFeed: UInt16 = 0x000A
    var previous: UInt16 = 0
    for codeUnit in text.utf16 {
        if codeUnit == lineFeed, previous != carriageReturn {
            body(carriageReturn)
        }
        body(codeUnit)
        previous = codeUnit
    }
}

/// Decodes UTF-16LE up to the first NUL, as used by CF_UNICODETEXT and fixed-size name fields.
private func decodeNullTerminatedUTF16(_ data: Data) throws -> String {
    guard data.count.isMultiple(of: 2) else {
        throw RDPDecodeError.invalidClipboardPDU
    }
    var codeUnits: [UInt16] = []
    codeUnits.reserveCapacity(data.count / 2)
    for index in stride(from: data.startIndex, to: data.endIndex, by: 2) {
        let codeUnit = UInt16(data[index]) | UInt16(data[index + 1]) << 8
        guard codeUnit != 0 else {
            break
        }
        codeUnits.append(codeUnit)
    }
    return String(decoding: codeUnits, as: UTF16.self)
}

/// Writes a NUL-terminated UTF-16LE string into a zero-padded field of `codeUnitCount` code units.
private func appendFixedUnicodeString(_ text: String, codeUnitCount: Int, to data: inout Data) {
    let codeUnits = text.utf16.prefix(codeUnitCount - 1)
    for codeUnit in codeUnits {
        data.appendLittleEndianUInt16(codeUnit)
    }
    data.append(Data(count: (codeUnitCount - codeUnits.count) * 2))
}
