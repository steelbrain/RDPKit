import Foundation
import NIOCore
import NIOEmbedded
import RDPKit

/// The server's end of a clipboard channel, in memory, to test an application's clipboard code
/// against a real `RDPClipboardSession`: the server copies text, files or other formats, empties
/// or restarts its clipboard, answers the session's requests, file downloads included, as told,
/// records the client's copies, and pastes the client's text or files. Each server message is
/// handled on a thread of the server's own, the session's thread, which calls the handlers as
/// `RDPSessionClient.run` does, a remote copy with its number. A server action returns at once;
/// `settle()` waits until what it set off is done, and `isStepping` holds the server's messages
/// for the test to hand over one at a time.
public final class RDPClipboardTestServer: @unchecked Sendable {
    /// A format a server copy offers: its ID, the name of a registered format, such as
    /// "HTML Format", and the data the server answers a request for it with.
    public struct Format: Equatable, Sendable {
        public var id: UInt32
        public var name: String?
        public var data: Data

        public init(id: UInt32, name: String? = nil, data: Data) {
            self.id = id
            self.name = name
            self.data = data
        }
    }

    /// A copy the client published, as its Format List announced it.
    public enum ClientCopy: Equatable, Sendable {
        /// An empty clipboard, which joining the clipboard and withdrawing a copy announce.
        case empty
        case text
        case files
        /// Formats with neither text nor files, such as HTML or an image alone.
        case other
    }

    /// A request of the session's for a file of the server's copy: its size, or a range of it.
    public struct FileRequest: Equatable, Sendable {
        public var fileIndex: Int
        public var isSizeRequest: Bool
        public var position: UInt64
        public var byteCount: Int
    }

    /// How the server answers a file request.
    public enum FileRequestAnswer: Equatable, Sendable {
        /// In full.
        case answer
        /// With a failure, which a download throws as `RDPClipboardDownloadError.refused`.
        case fail
        /// A range with at most this many bytes, 0 for none, which a download throws as
        /// `RDPClipboardDownloadError.incomplete` when it ends before the file does; a size in
        /// full.
        case truncate(to: Int)
        /// Not yet: `answerHeldFileRequests(_:)` answers it later, after the download timed out
        /// or another began, say.
        case hold
    }

    /// The session, which `onClipboardReady` got too.
    public let session: RDPClipboardSession
    private let channel: NIOAsyncTestingChannel
    private let handlers: RDPClipboardHandlers
    private let thread = DispatchQueue(label: "RDPClipboardTestServer")
    private let lock = NSLock()
    private var end = RDPClipboardServerEnd()
    private var fileRequestAnswerStorage: @Sendable (FileRequest) -> FileRequestAnswer = { _ in .answer }
    private var outstandingWork = 0
    /// The work counted so far, so `settle(alongside:)` can tell work that began and ended
    /// while it waited for its queue.
    private var startedWorkCount = 0
    private var isSteppingStorage = false
    private var heldMessages: [Data] = []
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var pasteWaiters: [CheckedContinuation<String?, Never>] = []
    private var filePasteWaiters: [CheckedContinuation<[RDPClipboardLocalFile]?, Never>] = []

    /// Starts the clipboard session as a server does, and returns once `onClipboardReady` has
    /// run. As in a session `run` makes, it fetches every format of a remote copy when
    /// `onClipboardContent` is set, and a copy of files as its file list when
    /// `onClipboardFileGroupDescriptor` is.
    public init(
        fetchesRemoteCopies: Bool = true,
        onClipboardReady: RDPClipboardSessionHandler? = nil,
        onClipboardText: RDPClipboardTextHandler? = nil,
        onClipboardContent: RDPClipboardContentHandler? = nil,
        onClipboardFileGroupDescriptor: RDPClipboardFileGroupDescriptorHandler? = nil,
        onClipboardFileContents: RDPClipboardFileContentsHandler? = nil,
        onClipboardRemoteCopyUnavailable: RDPClipboardRemoteCopyUnavailableHandler? = nil
    ) async throws {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389))
        let handlers = RDPClipboardHandlers(
            onReady: onClipboardReady,
            onText: onClipboardText,
            onContent: onClipboardContent,
            onFileGroupDescriptor: onClipboardFileGroupDescriptor,
            onFileContents: onClipboardFileContents,
            onRemoteCopyUnavailable: onClipboardRemoteCopyUnavailable
        )
        // The session's hooks reach the server, which does not exist until the session does.
        let relay = Relay()
        self.channel = channel
        self.handlers = handlers
        session = RDPClipboardSession.make(
            channel: channel,
            handlers: handlers,
            fetchesRemoteCopies: fetchesRemoteCopies,
            sentPayloadHandler: { relay.server?.sessionSent($0) },
            pendingEventHandler: { relay.server?.deliverPendingEvent() }
        )
        relay.server = self
        for message in RDPClipboardServerEnd.startMessages {
            send(message)
        }
        await settle()
    }

    deinit {
        let channel = channel
        Task { try? await channel.close() }
    }

    /// Copies `text` on the server.
    public func copyText(_ text: String) {
        send(lock.withLock { end.formatList(announcing: .text(text)) })
    }

    /// Copies `files` on the server, whose contents downloads get.
    public func copyFiles(_ files: [RDPClipboardLocalFile]) {
        send(lock.withLock { end.formatList(announcing: .files(files)) })
    }

    /// Copies `formats` on the server, such as an image (CF_DIB, 8) or "HTML Format", which the
    /// session fetches when `onClipboardContent` is set.
    public func copyFormats(_ formats: [Format]) {
        let formats = formats.map { RDPClipboardServerEnd.Format(formatID: $0.id, formatName: $0.name, data: $0.data) }
        send(lock.withLock { end.formatList(announcing: .formats(formats)) })
    }

    /// Whether the server answers the session's requests for a copy's formats with a failure,
    /// which the session reports to `onClipboardRemoteCopyUnavailable` with `isEmpty` false;
    /// false by default.
    public var failsFormatDataRequests: Bool {
        get { lock.withLock { end.failsFormatDataRequests } }
        set { lock.withLock { end.failsFormatDataRequests = newValue } }
    }

    /// Empties the server's clipboard, as Windows 11 announces it.
    public func emptyClipboard() {
        send(lock.withLock { end.formatList(announcing: .empty) })
    }

    /// Restarts the server's clipboard, as rdpclip.exe starting again does: `onClipboardReady`
    /// gets the session again.
    public func restartClipboard() {
        send(RDPClipboardServerEnd.monitorReady)
    }

    /// How the server answers each file request the session sends, in full by default. Called
    /// on the session's thread as the request comes, under the server's lock, so it must not
    /// call the server. A request held waits for `answerHeldFileRequests(_:)`, or else for the
    /// download's request timeout, which `advanceTime(by:)` passes.
    public var fileRequestAnswer: @Sendable (FileRequest) -> FileRequestAnswer {
        get { lock.withLock { fileRequestAnswerStorage } }
        set {
            lock.withLock {
                fileRequestAnswerStorage = newValue
                end.fileAnswer = { request in
                    newValue(FileRequest(request)).serverEndAnswer
                }
            }
        }
    }

    /// The file requests, for sizes and ranges, the session has sent.
    public var fileRequestCount: Int {
        lock.withLock { end.fileRequestCount }
    }

    /// The file requests held for `answerHeldFileRequests(_:)`.
    public var heldFileRequestCount: Int {
        lock.withLock { end.heldFileRequestCount }
    }

    /// Answers the file requests held so far as `answer` says, each about the copy it asked
    /// about; `.hold` keeps them.
    public func answerHeldFileRequests(_ answer: FileRequestAnswer = .answer) {
        let answers = lock.withLock { end.answerHeldFileRequests(answer.serverEndAnswer) }
        for answer in answers {
            send(answer)
        }
    }

    /// The copies the client has published, empty ones included, in the order their Format
    /// Lists reached the server: joining the clipboard announces an empty one first.
    public var clientCopies: [ClientCopy] {
        lock.withLock { end.clientCopies.map(ClientCopy.init) }
    }

    /// Pastes on the server: the text of the client's copy, once what is under way has settled;
    /// nil when the client offers no text, which it answers with a failure. One paste at a time.
    public func pasteText() async -> String? {
        await settle()
        return await withCheckedContinuation { continuation in
            let request = lock.withLock {
                pasteWaiters.append(continuation)
                return end.textRequest()
            }
            send(request)
        }
    }

    /// Pastes the client's files on the server, once what is under way has settled: reads its
    /// file list, then each file through the session's file contents answers, a size and then
    /// ranges of 4096 bytes, a folder's size 0 as the session answers it. Nil when the client's last copy offers no files, or the client fails a
    /// request. One paste at a time.
    public func pasteFiles() async -> [RDPClipboardLocalFile]? {
        await settle()
        return await withCheckedContinuation { continuation in
            let request = lock.withLock {
                let request = end.fileListRequest()
                if request != nil {
                    filePasteWaiters.append(continuation)
                }
                return request
            }
            guard let request else {
                continuation.resume(returning: nil)
                return
            }
            send(request)
        }
    }

    /// Moves the session's clock on, so requests left unanswered time out.
    public func advanceTime(by seconds: TimeInterval) async {
        await channel.testingEventLoop.advanceTime(by: .nanoseconds(Int64(seconds * 1_000_000_000)))
    }

    /// Closes the connection, which ends downloads with `RDPClipboardDownloadError.sessionEnded`.
    public func endSession() async {
        try? await channel.close()
    }

    /// While on, each message the server sends, a server action's or an answer to the session,
    /// waits, in order, until `step()` hands it to the session, so a test can do its own work
    /// between a Format List and its data, say. Turned off, the server hands over what waits.
    /// `settle()` does not wait for a message held, nor a paste for its answer.
    public var isStepping: Bool {
        get { lock.withLock { isSteppingStorage } }
        set {
            lock.withLock {
                isSteppingStorage = newValue
                guard !newValue else {
                    return
                }
                for message in heldMessages {
                    performLocked(receiving(message))
                }
                heldMessages = []
            }
        }
    }

    /// The messages `isStepping` holds.
    public var heldMessageCount: Int {
        lock.withLock { heldMessages.count }
    }

    /// Hands the next message `isStepping` holds to the session; false when none waits.
    @discardableResult
    public func step() -> Bool {
        lock.withLock {
            guard !heldMessages.isEmpty else {
                return false
            }
            performLocked(receiving(heldMessages.removeFirst()))
            return true
        }
    }

    /// Whether nothing the server set off is under way, as when `settle()` returns.
    public var isSettled: Bool {
        lock.withLock { outstandingWork == 0 }
    }

    /// Waits until every server message sent so far, and the answers and handlers they set
    /// off, are done. A handler that hands work to another thread, such as the main one, is
    /// done once it returns; ``settle(alongside:)`` also waits for what handlers hand a queue.
    public func settle() async {
        await withCheckedContinuation { continuation in
            let isIdle = lock.withLock {
                if outstandingWork == 0 {
                    return true
                }
                settleWaiters.append(continuation)
                return false
            }
            if isIdle {
                continuation.resume()
            }
        }
    }

    /// Waits until the server and `queue`, such as the main one its handlers hand work to, are
    /// both done, though each sets off more on the other: settles the server, then waits for
    /// what `queue` holds, until a wait finds the server set nothing off meanwhile. Work that
    /// `queue` hands itself again, or a task's next step, is not waited for.
    public func settle(alongside queue: DispatchQueue) async {
        while true {
            await settle()
            // Read while nothing is under way: any work after it counts, and all work before it
            // has handed `queue` what it hands it.
            guard let started = lock.withLock({ outstandingWork == 0 ? startedWorkCount : nil }) else {
                continue
            }
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
            // Work that began and ended while `queue` ran may have handed it more.
            if lock.withLock({ startedWorkCount == started }) {
                return
            }
        }
    }

    /// Handles `message` from the server on the session's thread, in the order sent, unless
    /// `isStepping` holds it.
    private func send(_ message: Data) {
        lock.withLock {
            if isSteppingStorage {
                heldMessages.append(message)
            } else {
                performLocked(receiving(message))
            }
        }
    }

    private func receiving(_ message: Data) -> @Sendable () -> Void {
        { [self] in
            let event = try? session.receive(serverMessage: message)
            handlers.deliver(event, from: session)
        }
    }

    /// Answers what the session sent, on whichever thread it sent it.
    private func sessionSent(_ message: Data) {
        let outcome = lock.withLock { try? end.answers(to: message) }
        for answer in outcome?.answers ?? [] {
            send(answer)
        }
        switch outcome?.reply {
        case let .text(text):
            let waiters = lock.withLock {
                defer { pasteWaiters = [] }
                return pasteWaiters
            }
            for waiter in waiters {
                waiter.resume(returning: text)
            }
        case let .files(files):
            let waiters = lock.withLock {
                defer { filePasteWaiters = [] }
                return filePasteWaiters
            }
            for waiter in waiters {
                waiter.resume(returning: files)
            }
        case nil:
            break
        }
    }

    private func deliverPendingEvent() {
        perform { [self] in
            handlers.deliver(session.takePendingEvent(), from: session)
        }
    }

    private func perform(_ work: @escaping @Sendable () -> Void) {
        lock.withLock { performLocked(work) }
    }

    /// Callers hold `lock`, so work runs in the order it was counted.
    private func performLocked(_ work: @escaping @Sendable () -> Void) {
        outstandingWork += 1
        startedWorkCount += 1
        thread.async { [self] in
            work()
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                outstandingWork -= 1
                guard outstandingWork == 0 else {
                    return []
                }
                defer { settleWaiters = [] }
                return settleWaiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

private final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedServer: RDPClipboardTestServer?

    var server: RDPClipboardTestServer? {
        get { lock.withLock { storedServer } }
        set { lock.withLock { storedServer = newValue } }
    }
}

extension RDPClipboardTestServer.FileRequest {
    init(_ request: RDPClipboardServerEnd.FileRequest) {
        fileIndex = request.fileIndex
        isSizeRequest = request.isSizeRequest
        position = request.position
        byteCount = request.byteCount
    }
}

extension RDPClipboardTestServer.FileRequestAnswer {
    var serverEndAnswer: RDPClipboardServerEnd.FileAnswer {
        switch self {
        case .answer:
            .answer
        case .fail:
            .fail
        case let .truncate(byteCount):
            .truncate(to: byteCount)
        case .hold:
            .hold
        }
    }
}

extension RDPClipboardTestServer.ClientCopy {
    init(_ copy: RDPClipboardServerEnd.ClientCopy) {
        switch copy {
        case .empty:
            self = .empty
        case .text:
            self = .text
        case .files:
            self = .files
        case .other:
            self = .other
        }
    }
}
