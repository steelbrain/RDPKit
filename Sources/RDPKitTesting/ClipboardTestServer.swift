import Foundation
import NIOCore
import NIOEmbedded
import RDPKit

/// The server's end of a clipboard channel, in memory, to test an application's clipboard code
/// against a real `RDPClipboardSession`: the server copies text or files, empties or restarts
/// its clipboard, answers the session's requests, file downloads included, and pastes the
/// client's text. Each server message is handled on a thread of the server's own, the session's
/// thread, which calls the handlers as `RDPSessionClient.run` does, a remote copy with its
/// number. A server action returns at once; `settle()` waits until what it set off is done.
public final class RDPClipboardTestServer: @unchecked Sendable {
    /// The session, which `onClipboardReady` got too.
    public let session: RDPClipboardSession
    private let channel: NIOAsyncTestingChannel
    private let handlers: RDPClipboardHandlers
    private let thread = DispatchQueue(label: "RDPClipboardTestServer")
    private let lock = NSLock()
    private var end = RDPClipboardServerEnd()
    private var outstandingWork = 0
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var pasteWaiters: [CheckedContinuation<String?, Never>] = []

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

    /// Empties the server's clipboard, as Windows 11 announces it.
    public func emptyClipboard() {
        send(lock.withLock { end.formatList(announcing: .empty) })
    }

    /// Restarts the server's clipboard, as rdpclip.exe starting again does: `onClipboardReady`
    /// gets the session again.
    public func restartClipboard() {
        send(RDPClipboardServerEnd.monitorReady)
    }

    /// Whether the server answers file requests; true by default. Unanswered, a download
    /// waits for its request timeout, which `advanceTime(by:)` passes.
    public var answersFileRequests: Bool {
        get { lock.withLock { end.answersFileRequests } }
        set { lock.withLock { end.answersFileRequests = newValue } }
    }

    /// The file requests, for sizes and ranges, the session has sent.
    public var fileRequestCount: Int {
        lock.withLock { end.fileRequestCount }
    }

    /// Pastes on the server: the text of the client's copy, once what is under way has settled;
    /// nil when the client offers no text, which it answers with a failure.
    public func pasteText() async -> String? {
        await settle()
        return await withCheckedContinuation { continuation in
            lock.withLock { pasteWaiters.append(continuation) }
            send(RDPClipboardServerEnd.textRequest)
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

    /// Waits until every server message sent so far, and the answers and handlers they set
    /// off, are done. A handler that hands work to another thread, such as the main one, is
    /// done once it returns.
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

    /// Handles `message` from the server on the session's thread.
    private func send(_ message: Data) {
        perform { [self] in
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
        if case let .text(text) = outcome?.reply {
            let waiters = lock.withLock {
                defer { pasteWaiters = [] }
                return pasteWaiters
            }
            for waiter in waiters {
                waiter.resume(returning: text)
            }
        }
    }

    private func deliverPendingEvent() {
        perform { [self] in
            handlers.deliver(session.takePendingEvent(), from: session)
        }
    }

    private func perform(_ work: @escaping @Sendable () -> Void) {
        lock.withLock { outstandingWork += 1 }
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
