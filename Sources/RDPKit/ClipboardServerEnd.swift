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
    }

    /// What a message from the session brings besides the server's answers.
    package enum ClientReply: Equatable, Sendable {
        /// The client's answer to `textRequest`: its text, or nil when it failed.
        case text(String?)
    }

    private static let fileGroupDescriptorFormatID: UInt32 = 0xC0A3

    /// Capabilities, then Monitor Ready, which starts the session ([MS-RDPECLIP] 1.3.2.1).
    package static let startMessages = [RDPClipboardCapabilitiesPDU().encoded(), monitorReady]
    /// A restart of the server's clipboard, as rdpclip.exe starting again sends.
    package static let monitorReady = RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady).encoded()
    /// Asks the client for its copy's text.
    package static let textRequest = RDPClipboardFormatDataRequestPDU(formatID: RDPClipboardFormatID.unicodeText).encoded()

    private var copy = Copy.empty
    /// Whether file contents requests get an answer; without one, a download waits for its timeout.
    package var answersFileRequests = true
    package private(set) var fileRequestCount = 0

    package init() {}

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
        }
        return RDPClipboardFormatListPDU(entries: entries).encoded()
    }

    /// The server's answers to `message`, which the session sent whole, and what else it brings.
    package mutating func answers(to message: Data) throws -> (answers: [Data], reply: ClientReply?) {
        let pdu = try RDPClipboardPDU.parse(from: message)
        if try RDPClipboardFormatListPDU.parseIfPresent(from: pdu) != nil {
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
            return (answersFileRequests ? [fileContents(for: request).encoded()] : [], nil)
        }
        if let response = try RDPClipboardFormatDataResponsePDU.parseIfPresent(from: pdu) {
            return ([], .text(response.ok ? try? response.decodedUnicodeText() : nil))
        }
        return ([], nil)
    }

    private func formatData(for formatID: UInt32) -> RDPClipboardFormatDataResponsePDU {
        switch copy {
        case let .text(text) where formatID == RDPClipboardFormatID.unicodeText:
            .unicodeText(text)
        case let .files(files) where formatID == Self.fileGroupDescriptorFormatID:
            .fileGroupDescriptorW(RDPClipboardFileGroupDescriptorW(descriptors: files.map(\.descriptor)))
        default:
            .failure()
        }
    }

    private func fileContents(for request: RDPClipboardFileContentsRequestPDU) -> RDPClipboardFileContentsResponse {
        guard case let .files(files) = copy, files.indices.contains(Int(request.fileIndex)) else {
            return .failure(streamID: request.streamID)
        }
        let contents = files[Int(request.fileIndex)].contents
        if request.flags & RDPClipboardFileContentsFlags.size != 0 {
            return .fileSize(streamID: request.streamID, byteCount: UInt64(contents.count))
        }
        let lowerBound = min(Int(clamping: request.position), contents.count)
        let upperBound = min(lowerBound + Int(request.requestedByteCount), contents.count)
        return .range(streamID: request.streamID, data: contents.subdata(in: lowerBound ..< upperBound))
    }
}
