import Foundation
import NIOCore

/// The clipboard handlers of a `run` or `connect` call, which a clipboard session's events go to.
package struct RDPClipboardHandlers: Sendable {
    package var onReady: RDPClipboardSessionHandler?
    package var onText: RDPClipboardTextHandler?
    package var onContent: RDPClipboardContentHandler?
    package var onFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler?
    package var onFileContents: RDPClipboardFileContentsHandler?
    package var onRemoteCopyUnavailable: RDPClipboardRemoteCopyUnavailableHandler?

    package init(
        onReady: RDPClipboardSessionHandler? = nil,
        onText: RDPClipboardTextHandler? = nil,
        onContent: RDPClipboardContentHandler? = nil,
        onFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onFileContents: RDPClipboardFileContentsHandler? = nil,
        onRemoteCopyUnavailable: RDPClipboardRemoteCopyUnavailableHandler? = nil
    ) {
        self.onReady = onReady
        self.onText = onText
        self.onContent = onContent
        self.onFileGroupDescriptor = onFileGroupDescriptor
        self.onFileContents = onFileContents
        self.onRemoteCopyUnavailable = onRemoteCopyUnavailable
    }

    /// Hands `event` to its handler, a remote copy with its number.
    package func deliver(_ event: RDPClipboardEvent?, from clipboard: RDPClipboardSession) {
        switch event {
        case .ready:
            onReady?(clipboard)
        case let .text(text):
            onText?(text, clipboard.deliveredRemoteCopyNumber)
        case let .content(content):
            let copyNumber = clipboard.deliveredRemoteCopyNumber
            if let text = content.text {
                onText?(text, copyNumber)
            }
            onContent?(content, copyNumber)
        case let .fileGroupDescriptor(descriptor):
            onFileGroupDescriptor?(descriptor, clipboard.deliveredRemoteCopyNumber)
        case let .remoteCopyUnavailable(isEmpty):
            onRemoteCopyUnavailable?(isEmpty, clipboard.deliveredRemoteCopyNumber)
        case let .fileContents(contents):
            onFileContents?(contents)
        case nil:
            break
        }
    }
}

extension RDPClipboardSession {
    /// A session over `channel`, made as a connection makes one: it fetches rich formats when
    /// `handlers` has `onContent`, and file lists when it has `onFileGroupDescriptor`.
    /// `sentPayloadHandler` gets each message it sends, whole.
    package static func make(
        channel: Channel,
        handlers: RDPClipboardHandlers,
        fetchesRemoteCopies: Bool,
        sentPayloadHandler: @escaping @Sendable (Data) -> Void,
        pendingEventHandler: @escaping @Sendable () -> Void
    ) -> RDPClipboardSession {
        RDPClipboardSession(
            userChannelID: 1007,
            staticChannelID: 1004,
            channel: channel,
            requestsRichFormats: handlers.onContent != nil,
            requestsFileLists: handlers.onFileGroupDescriptor != nil,
            fetchesRemoteCopies: fetchesRemoteCopies,
            sentPayloadHandler: sentPayloadHandler,
            pendingEventHandler: pendingEventHandler
        )
    }

    /// Takes a whole message from the server.
    package func receive(serverMessage: Data) throws -> RDPClipboardEvent? {
        try receive(RDPClipboardPDU.parse(from: serverMessage))
    }
}

/// The server's end of a clipboard channel: the messages a server sends, and how it answers
/// those a session sends ([MS-RDPECLIP] 1.3.2), as Windows does for text and files.
package struct RDPClipboardServerEnd: Sendable {
    package enum Copy: Equatable, Sendable {
        case empty
        case text(String)
        case files([RDPClipboardLocalFile])
        case formats([Format])
    }

    /// A format a copy offers, a registered one with its name, and the data it is answered with.
    package struct Format: Equatable, Sendable {
        package var formatID: UInt32
        package var formatName: String?
        package var data: Data

        package init(formatID: UInt32, formatName: String?, data: Data) {
            self.formatID = formatID
            self.formatName = formatName
            self.data = data
        }
    }

    /// What a Format List from the session announced.
    package enum ClientCopy: Equatable, Sendable {
        case empty
        case text
        case files
        /// Formats with neither text nor files, such as HTML or an image alone.
        case other
    }

    /// How a file contents request is answered.
    package enum FileAnswer: Equatable, Sendable {
        case answer
        case fail
        /// A range with at most this many bytes; a size in full.
        case truncate(to: Int)
        case hold
    }

    /// A file contents request the session sent.
    package struct FileRequest: Equatable, Sendable {
        package var fileIndex: Int
        package var isSizeRequest: Bool
        package var position: UInt64
        package var byteCount: Int
    }

    /// What a message from the session brings besides the server's answers.
    package enum ClientReply: Equatable, Sendable {
        /// The client's answer to `textRequest()`: its text, or nil when it failed.
        case text(String?)
        /// The files `fileListRequest()` set off reading, or nil when a request failed or a
        /// range brought nothing before a file's end.
        case files([RDPClipboardLocalFile]?)
    }

    private enum Paste {
        case text
        case files
    }

    /// The client's files being read: those read so far, and the next one's size and bytes.
    private struct FilePaste {
        var descriptors: [RDPClipboardFileDescriptorW]
        var files: [RDPClipboardLocalFile] = []
        var size: UInt64?
        var contents = Data()
        var streamID: UInt32 = 0
    }

    private static let fileGroupDescriptorFormatID: UInt32 = 0xC0A3
    /// The bytes a range request of the client's files asks for, so a larger file takes several.
    package static let pasteRangeByteCount = 4096

    /// Capabilities, then Monitor Ready, which starts the session ([MS-RDPECLIP] 1.3.2.1).
    package static let startMessages = [RDPClipboardCapabilitiesPDU().encoded(), monitorReady]
    /// A restart of the server's clipboard, as rdpclip.exe starting again sends.
    package static let monitorReady = RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady).encoded()

    private var copy = Copy.empty
    /// Whether format data requests are answered with a failure.
    package var failsFormatDataRequests = false
    /// How each file contents request is answered; called under the caller's lock.
    package var fileAnswer: @Sendable (FileRequest) -> FileAnswer = { _ in .answer }
    package private(set) var fileRequestCount = 0
    /// Requests `.hold` kept, with the copy each asked about.
    private var heldFileRequests: [(request: RDPClipboardFileContentsRequestPDU, copy: Copy)] = []
    /// The copies the session's Format Lists announced, in order.
    package private(set) var clientCopies: [ClientCopy] = []
    /// The ID the session's last Format List gave its file list, when it offered files.
    private var clientFileListFormatID: UInt32?
    private var awaitedPaste: Paste?
    private var filePaste: FilePaste?
    private var lastPasteStreamID: UInt32 = 0

    package init() {}

    package var heldFileRequestCount: Int {
        heldFileRequests.count
    }

    /// Makes `copy` the server's clipboard, and returns the Format List announcing it.
    package mutating func formatList(announcing copy: Copy) -> Data {
        self.copy = copy
        let entries: [RDPClipboardFormatListEntry] = switch copy {
        case .empty:
            []
        case .text:
            [RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText)]
        case .files:
            [RDPClipboardFormatListEntry(formatID: Self.fileGroupDescriptorFormatID, formatName: "FileGroupDescriptorW")]
        case let .formats(formats):
            formats.map { RDPClipboardFormatListEntry(formatID: $0.formatID, formatName: $0.formatName) }
        }
        return RDPClipboardFormatListPDU(entries: entries).encoded()
    }

    /// Asks the client for its copy's text; the answer comes as `ClientReply.text`.
    package mutating func textRequest() -> Data {
        awaitedPaste = .text
        return RDPClipboardFormatDataRequestPDU(formatID: RDPClipboardFormatID.unicodeText).encoded()
    }

    /// Asks the client for its copy's file list, then reads each file, which comes as
    /// `ClientReply.files`; nil when the client's last Format List offered no files.
    package mutating func fileListRequest() -> Data? {
        guard let clientFileListFormatID else {
            return nil
        }
        awaitedPaste = .files
        filePaste = nil
        return RDPClipboardFormatDataRequestPDU(formatID: clientFileListFormatID).encoded()
    }

    /// The server's answers to `message`, which the session sent whole, and what else it brings.
    package mutating func answers(to message: Data) throws -> (answers: [Data], reply: ClientReply?) {
        let pdu = try RDPClipboardPDU.parse(from: message)
        if let formatList = try RDPClipboardFormatListPDU.parseIfPresent(from: pdu) {
            clientCopies.append(ClientCopy(formatList))
            clientFileListFormatID = formatList.fileGroupDescriptorWFormatID
            let response = RDPClipboardPDU(
                messageType: RDPClipboardMessageType.formatListResponse,
                messageFlags: RDPClipboardMessageFlags.responseOK
            )
            return ([response.encoded()], nil)
        }
        if let request = try RDPClipboardFormatDataRequestPDU.parseIfPresent(from: pdu) {
            return ([formatData(for: request.formatID).encoded()], nil)
        }
        if let request = try RDPClipboardFileContentsRequestPDU.parseIfPresent(from: pdu) {
            fileRequestCount += 1
            let answer = fileAnswer(FileRequest(request))
            guard answer != .hold else {
                heldFileRequests.append((request, copy))
                return ([], nil)
            }
            return ([Self.fileContents(for: request, of: copy, answer: answer).encoded()], nil)
        }
        if let response = try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu) {
            defer { awaitedPaste = nil }
            switch awaitedPaste {
            case .text:
                return ([], .text(response.ok ? try? response.decodedUnicodeText() : nil))
            case .files:
                guard let list = try? response.decodedFileGroupDescriptorW() else {
                    return ([], .files(nil))
                }
                filePaste = FilePaste(descriptors: list.descriptors)
                return nextFileRequest()
            case nil:
                return ([], nil)
            }
        }
        if let response = try RDPClipboardFileContentsResponse.parseIfPresent(from: pdu) {
            return continuePasting(with: response)
        }
        return ([], nil)
    }

    /// Answers the requests `.hold` kept, about the copy each asked about, unless `answer` is
    /// `.hold`, which keeps them.
    package mutating func answerHeldFileRequests(_ answer: FileAnswer) -> [Data] {
        guard answer != .hold else {
            return []
        }
        defer { heldFileRequests = [] }
        return heldFileRequests.map { Self.fileContents(for: $0.request, of: $0.copy, answer: answer).encoded() }
    }

    private func formatData(for formatID: UInt32) -> RDPClipboardFormatDataResponsePDU {
        guard !failsFormatDataRequests else {
            return .failure()
        }
        switch copy {
        case let .text(text) where formatID == RDPClipboardFormatID.unicodeText:
            return .unicodeText(text)
        case let .files(files) where formatID == Self.fileGroupDescriptorFormatID:
            return .fileGroupDescriptorW(RDPClipboardFileGroupDescriptorW(descriptors: files.map(\.descriptor)))
        case let .formats(formats):
            guard let format = formats.first(where: { $0.formatID == formatID }) else {
                return .failure()
            }
            return RDPClipboardFormatDataResponsePDU(ok: true, data: format.data)
        default:
            return .failure()
        }
    }

    private static func fileContents(
        for request: RDPClipboardFileContentsRequestPDU,
        of copy: Copy,
        answer: FileAnswer
    ) -> RDPClipboardFileContentsResponse {
        guard answer != .fail, case let .files(files) = copy, files.indices.contains(Int(request.fileIndex)) else {
            return .failure(streamID: request.streamID)
        }
        let contents = files[Int(request.fileIndex)].contents
        if request.flags & RDPClipboardFileContentsFlags.size != 0 {
            return .fileSize(streamID: request.streamID, byteCount: UInt64(contents.count))
        }
        let lowerBound = min(Int(clamping: request.position), contents.count)
        var upperBound = min(lowerBound + Int(request.requestedByteCount), contents.count)
        if case let .truncate(byteCount) = answer {
            upperBound = min(upperBound, lowerBound + max(0, byteCount))
        }
        return .range(streamID: request.streamID, data: contents.subdata(in: lowerBound ..< upperBound))
    }

    /// The request for the next part of the client's files, or the files once all are read.
    private mutating func nextFileRequest() -> (answers: [Data], reply: ClientReply?) {
        guard var paste = filePaste else {
            return ([], nil)
        }
        guard paste.files.count < paste.descriptors.count else {
            filePaste = nil
            return ([], .files(paste.files))
        }
        lastPasteStreamID &+= 1
        paste.streamID = lastPasteStreamID
        let fileIndex = Int32(paste.files.count)
        let request: RDPClipboardFileContentsRequestPDU = if let size = paste.size {
            .range(
                streamID: paste.streamID,
                fileIndex: fileIndex,
                position: UInt64(paste.contents.count),
                requestedByteCount: UInt32(min(UInt64(Self.pasteRangeByteCount), size - UInt64(paste.contents.count)))
            )
        } else {
            .size(streamID: paste.streamID, fileIndex: fileIndex)
        }
        guard let encoded = try? request.encoded() else {
            filePaste = nil
            return ([], .files(nil))
        }
        filePaste = paste
        return ([encoded], nil)
    }

    private mutating func continuePasting(with response: RDPClipboardFileContentsResponse) -> (answers: [Data], reply: ClientReply?) {
        guard var paste = filePaste, response.streamID == paste.streamID else {
            return ([], nil)
        }
        if let size = paste.size {
            guard response.ok, !response.data.isEmpty else {
                filePaste = nil
                return ([], .files(nil))
            }
            paste.contents += response.data
            if UInt64(paste.contents.count) >= size {
                paste.files.append(RDPClipboardLocalFile(descriptor: paste.descriptors[paste.files.count], contents: paste.contents))
                paste.size = nil
                paste.contents = Data()
            }
        } else {
            guard let size = try? response.decodedFileSize() else {
                filePaste = nil
                return ([], .files(nil))
            }
            if size == 0 {
                paste.files.append(RDPClipboardLocalFile(descriptor: paste.descriptors[paste.files.count], contents: Data()))
            } else {
                paste.size = size
            }
        }
        filePaste = paste
        return nextFileRequest()
    }
}

extension RDPClipboardServerEnd.ClientCopy {
    init(_ formatList: RDPClipboardFormatListPDU) {
        if formatList.entries.isEmpty {
            self = .empty
        } else if formatList.fileGroupDescriptorWFormatID != nil {
            self = .files
        } else if formatList.formatIDs.contains(RDPClipboardFormatID.unicodeText) {
            self = .text
        } else {
            self = .other
        }
    }
}

extension RDPClipboardServerEnd.FileRequest {
    init(_ request: RDPClipboardFileContentsRequestPDU) {
        fileIndex = Int(request.fileIndex)
        isSizeRequest = request.flags & RDPClipboardFileContentsFlags.size != 0
        position = request.position
        byteCount = Int(request.requestedByteCount)
    }
}
