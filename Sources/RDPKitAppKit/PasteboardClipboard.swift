#if os(macOS)
import AppKit
import RDPKit

/// What ``RDPPasteboardClipboard`` sends to: an `RDPClipboardSession`, or a test's stand-in
/// for one, which passes each call on to the session.
public protocol RDPPasteboardClipboardSession: AnyObject, Sendable {
    /// Off while sharing is off, so the server's copies are not even fetched. Turned on, it
    /// fetches a copy the server announced while it was off, unless a publish replaced it.
    var fetchesRemoteCopies: Bool { get set }
    /// Turns fetching on, and says whether a copy the server announced is being fetched then,
    /// even one already handed over by the time it returns.
    func startFetchingRemoteCopies() -> Bool
    /// Whether a publish since replaced, on the server, the remote copy numbered
    /// `remoteCopyNumber`: the `copyNumber` its handler got.
    func hasPublished(since remoteCopyNumber: Int) -> Bool
    func publishLocalUnicodeText(_ text: String?)
    /// Publishes an empty copy at once for files still to be read, and returns its number.
    func beginLocalCopy() -> Int
    /// Offers the files read for copy `copyNumber`, unless a newer copy, local or remote,
    /// replaced it, and says whether it did.
    @discardableResult
    func publishLocalFiles(_ files: [RDPClipboardLocalFile], forCopy copyNumber: Int) -> Bool
    /// Publishes an empty copy while the server's clipboard holds this Mac's last one, and
    /// says whether it did.
    @discardableResult
    func withdrawLocalCopy() -> Bool
    /// Downloads the files `plan` holds, of remote copy `copyNumber`, into `directory`,
    /// handing each to `writeFile`; ends early once a newer copy replaces it, the connection
    /// closes, or its task is cancelled.
    func downloadRemoteFiles(
        _ plan: RDPClipboardDownloadPlan,
        copyNumber: Int,
        into directory: URL,
        progress: (@Sendable (RDPClipboardDownloadProgress) async -> Void)?,
        writeFile: @Sendable (Data, URL) throws -> Void
    ) async throws -> RDPClipboardDownload
}

extension RDPClipboardSession: RDPPasteboardClipboardSession {}

/// Bridges a Mac pasteboard and a session's clipboard channel: publishes the pasteboard's text
/// and files as the user copies them, puts the server's text on the pasteboard, and downloads
/// the server's files into a folder of their own under `downloadRoot`, quarantined, to put
/// them there. Each change is checked for by ``poll()``, which the app calls once a second, as
/// macOS tells no one of a pasteboard change.
///
/// The app hands it the session `onClipboardReady` gives with ``attach(_:)`` (again after a
/// Server Redirection or a restart of the server's clipboard), and what the session's handlers
/// get with ``receiveText(_:copyNumber:)``, ``receiveFileList(_:copyNumber:)`` and
/// ``receiveRemoteCopyUnavailable(isEmpty:copyNumber:)``, on the main thread, in the order
/// the handlers got them. Connect with `RDPConnectionConfiguration.clipboardFetchesRemoteCopies`
/// off: the bridge turns fetching on once it decides the server's copy is newer than the
/// pasteboard. ``onEvent`` tells the app what the user may want to hear.
///
/// Sharing off, nothing of the pasteboard goes, and nothing of the server's is fetched; an
/// emptied server clipboard still clears the pasteboard while it holds what came from that
/// server, as [MS-RDPECLIP] 3.1.5.2.2 has a Format List replace the receiver's clipboard, so a
/// password a password manager cleared there does not stay on the Mac.
@MainActor
public final class RDPPasteboardClipboard {
    /// What happened that the user may want to hear of, for the app to word.
    public enum Event: Equatable, Sendable {
        /// The pasteboard's text went to the server, for ``syncNow()``.
        case localTextShared
        /// The pasteboard has neither text nor files, so the server's clipboard was emptied,
        /// for ``syncNow()``.
        case localClipboardEmpty
        /// The pasteboard's text is too large to send; the server's clipboard was emptied in
        /// its place, so an older copy there does not stay.
        case localTextTooLarge
        /// The pasteboard's files went to the server, for a new copy or ``syncNow()``.
        case localFilesShared(count: Int)
        /// The pasteboard's files could not be read or sent, for a new copy or
        /// ``syncNow()``; the server's clipboard stays empty.
        case localFilesNotShared(RDPClipboardLocalFileReadError)
        /// macOS denies reading the pasteboard, as the user can choose in System Settings, so
        /// nothing goes and the server keeps its copy. Once until a read works again, and for
        /// each ``syncNow()``.
        case pasteboardAccessDenied
        /// ``syncNow()`` found nothing new to send.
        case upToDate
        /// The server's text is on the pasteboard.
        case remoteTextCopied
        /// The server's copy holds nothing the bridge takes, such as an image, or did not
        /// arrive.
        case remoteCopyUnavailable
        /// The server's clipboard was emptied; `clearedHere` when the pasteboard held what came
        /// from it, and was cleared too. Sharing off, only once it was cleared.
        case remoteClipboardEmptied(clearedHere: Bool)
        /// The server's files are not downloaded: RDPKit refuses a copy like that.
        case remoteFilesRefused(RDPClipboardRemoteFileTransferPlanningError)
        /// A file of the server's copy started downloading: the first, then once per tenth of
        /// the files, so a copy of many says how far it is without a report for each.
        case downloadProgress(RDPClipboardDownloadProgress)
        /// The server's files are on the pasteboard.
        case remoteFilesCopied(RDPClipboardDownload)
        /// The server's files did not reach the pasteboard.
        case downloadFailed(DownloadFailure)
        /// ``startTemporarySharing()`` turned sharing on.
        case temporarySharingStarted
        /// A temporary share ran out, and sharing is off again.
        case temporarySharingEnded
    }

    /// Why the server's files did not reach the pasteboard. A download a newer copy, the
    /// session's end or ``detach()`` ended has none: what replaced it says so itself.
    public enum DownloadFailure: Equatable, Sendable {
        /// The server left a request unanswered for `downloadLimits.requestTimeout`.
        case timedOut
        /// The server refused a request.
        case refused
        /// The server's answers did not add up to the files it listed.
        case incomplete
        /// The sizes the server answered add up to more than
        /// `downloadLimits.maximumTotalByteCount`.
        case totalByteLimitExceeded
        /// No folder could be made under `downloadRoot` for the download.
        case folderNotCreated
        /// A file could not be written.
        case notSaved
        /// The user copied something while the last file came, which is newer.
        case clipboardChanged
        /// The pasteboard did not take the files.
        case pasteboardRefused
    }

    public private(set) var session: (any RDPPasteboardClipboardSession)?
    public private(set) var isSharingEnabled: Bool
    /// Tells the app what happened, on the main thread.
    public var onEvent: @MainActor (Event) -> Void = { _ in }
    private let pasteboard: NSPasteboard
    private let downloadRoot: URL
    /// What a copy of the server's files may hold, and how it is fetched, for the app to name
    /// the limits a copy went over.
    public let downloadLimits: RDPClipboardDownloadLimits
    private let quarantineAgentName: String
    private let temporarySharingDuration: TimeInterval
    private let now: @MainActor () -> Date
    private let pasteboardAccessIsDenied: @MainActor () -> Bool
    /// Whether the app heard that the pasteboard cannot be read since it last could.
    private var reportedDeniedPasteboardAccess = false
    private var pasteboardChangeCount: Int
    /// Whether the local copy last seen has not reached the server: it could not be read or
    /// sent, or its read was cut short. A remote copy since is newer, which clears it.
    private var localCopyIsUnsent = false
    private var localFileRead: Task<Void, Never>?
    /// Whether the running read reports its result even when it is no news, for a sync the
    /// user asked for.
    private var localFileReadAnnounces = false
    private var temporarySharingExpiresAt: Date?
    private var fileDownload: FileDownload?
    /// The last download put on the pasteboard, and the pasteboard's change count once it was
    /// there: a later count means its files are gone from the pasteboard.
    private var copiedDownload: (directory: URL, changeCount: Int)?
    /// The pasteboard's change count once a remote copy was put on it: while it is unchanged,
    /// the pasteboard holds what came from the server.
    private var remoteCopyChangeCount: Int?

    /// - Parameters:
    ///   - isSharingEnabled: Whether the pasteboard and the server's clipboard are shared.
    ///   - pasteboard: The user's clipboard; a test passes one of its own.
    ///   - downloadRoot: Holds a folder, named by a UUID, for each download of the server's
    ///     files, such as one in the temporary directory named for the app.
    ///     ``removeStaleDownloadDirectories(in:changedBefore:keeping:)`` clears what earlier
    ///     runs left there.
    ///   - downloadLimits: What a copy of the server's files may hold and how it is fetched.
    ///   - quarantineAgentName: The app named in each downloaded file's quarantine mark,
    ///     which has Gatekeeper check the file before it opens, as for a browser download;
    ///     the process's name by default.
    ///   - temporarySharingDuration: How long ``startTemporarySharing()`` shares.
    ///   - now: The clock, for temporary shares; a test moves its own.
    ///   - pasteboardAccessIsDenied: Whether macOS denies reading `pasteboard`; by default,
    ///     its `accessBehavior` on macOS 15.4 and later.
    public init(
        isSharingEnabled: Bool,
        pasteboard: NSPasteboard = .general,
        downloadRoot: URL,
        downloadLimits: RDPClipboardDownloadLimits = RDPClipboardDownloadLimits(),
        quarantineAgentName: String = ProcessInfo.processInfo.processName,
        temporarySharingDuration: TimeInterval = 30,
        now: @escaping @MainActor () -> Date = { Date() },
        pasteboardAccessIsDenied: (@MainActor () -> Bool)? = nil
    ) {
        self.isSharingEnabled = isSharingEnabled
        self.pasteboard = pasteboard
        self.downloadRoot = downloadRoot
        self.downloadLimits = downloadLimits
        self.quarantineAgentName = quarantineAgentName
        self.temporarySharingDuration = temporarySharingDuration
        self.now = now
        self.pasteboardAccessIsDenied = pasteboardAccessIsDenied ?? { Self.deniesAccess(to: pasteboard) }
        pasteboardChangeCount = pasteboard.changeCount
    }

    /// Whether ``syncNow()`` can send: sharing is on and a session is attached.
    public var canSync: Bool {
        isSharingEnabled && session != nil
    }

    public var isTemporarySharingActive: Bool {
        temporarySharingExpiresAt != nil
    }

    /// Off while sharing is on for good, which a temporary share would end.
    public var canStartTemporarySharing: Bool {
        session != nil && (isSharingEnabled == false || isTemporarySharingActive)
    }

    /// The whole seconds a temporary share has left, or nil without one.
    public var temporarySharingSecondsRemaining: Int? {
        guard let temporarySharingExpiresAt else {
            return nil
        }
        return max(0, Int(ceil(temporarySharingExpiresAt.timeIntervalSince(now()))))
    }

    /// The download under way, for a test to await.
    public var fileDownloadTask: Task<Void, Never>? {
        fileDownload?.task
    }

    /// The read of copied local files under way, for a test to await.
    public var localFileReadTask: Task<Void, Never>? {
        localFileRead
    }

    /// Applies the sharing choice to `session`, which starts with fetching off. A Server
    /// Redirection, or the server's clipboard restarting, attaches again without a
    /// ``detach()``; a restart turns fetching off again before RDPKit hands the session over,
    /// so nothing the restarted clipboard announces is fetched before this decides again.
    public func attach(_ session: any RDPPasteboardClipboardSession) {
        // A download in flight gets no answers on the new session, and a local file read in
        // flight must not send its files over a copy the server announced since; the
        // pasteboard is read again below when it is to go.
        discardFileTransfer()
        cancelLocalFileRead()
        // A server redirected to has a clipboard of its own.
        if session !== self.session {
            remoteCopyChangeCount = nil
        }
        self.session = session
        guard isSharingEnabled else {
            session.fetchesRemoteCopies = false
            session.publishLocalUnicodeText(nil)
            return
        }
        // Turning fetching on fetches a copy the server announced before the bridge attached,
        // also after a restart. It is newer than the pasteboard, which publishing now would put
        // in its place on the server; should it never arrive, Sync Now sends the pasteboard.
        // Asked as fetching turns on, since the copy can come before a later look.
        guard session.startFetchingRemoteCopies() == false else {
            pasteboardChangeCount = pasteboard.changeCount
            localCopyIsUnsent = true
            return
        }
        publishPasteboardIfChanged(force: true)
    }

    /// Forgets the session once its channel is gone, so polling and syncing stop talking to
    /// it, and drops any download in flight. A finished download stays only while its files
    /// are still on the pasteboard.
    public func detach() {
        session = nil
        // A later session's server has a clipboard of its own.
        remoteCopyChangeCount = nil
        discardFileTransfer()
        cancelLocalFileRead()
        removeCopiedDownloadIfReplaced()
        pasteboardChangeCount = pasteboard.changeCount
    }

    /// The user's choice, which also ends a temporary share.
    public func setSharingEnabled(_ enabled: Bool) {
        let wasEnabled = isSharingEnabled
        isSharingEnabled = enabled
        temporarySharingExpiresAt = nil
        guard enabled else {
            session?.fetchesRemoteCopies = false
            discardFileTransfer()
            cancelLocalFileRead()
            // Takes back the local copy. Windows empties its clipboard for the empty Format
            // List, so a copy made there since is left be.
            session?.withdrawLocalCopy()
            pasteboardChangeCount = pasteboard.changeCount
            return
        }
        // Already on, the server may hold a newer copy, or be sending one, that sending the
        // pasteboard again would replace, so only what Sync Now would send goes.
        guard wasEnabled == false else {
            publishPasteboardIfChanged(force: resendsUnsentLocalCopy)
            return
        }
        // The pasteboard goes first: it replaces on the server a copy announced while sharing
        // was off, which turning fetching on would fetch.
        publishPasteboardIfChanged(force: true)
        session?.fetchesRemoteCopies = true
    }

    /// Sends a local copy the poll has not yet, or again one that has not reached the server,
    /// such as a file iCloud had not downloaded yet, and reports the result, even when there is
    /// nothing new. A pasteboard the server has, or that a newer remote copy replaced, is not
    /// sent again, so that copy, or its download, is kept.
    public func syncNow() {
        guard publishPasteboardIfChanged(force: resendsUnsentLocalCopy, announce: true) == false,
              canSync
        else {
            return
        }
        if localFileRead != nil {
            // The copied files are still being read; their result is news.
            localFileReadAnnounces = true
        } else {
            onEvent(.upToDate)
        }
    }

    /// Turns sharing on for `temporarySharingDuration`, or restarts a temporary share.
    public func startTemporarySharing() {
        guard canStartTemporarySharing else {
            return
        }
        setSharingEnabled(true)
        temporarySharingExpiresAt = now().addingTimeInterval(temporarySharingDuration)
        onEvent(.temporarySharingStarted)
    }

    /// Ends an expired temporary share and publishes what the user copied since the last poll.
    /// The app calls it once a second.
    public func poll() {
        // A temporary share is always one that turned sharing on.
        if let temporarySharingExpiresAt, now() >= temporarySharingExpiresAt {
            setSharingEnabled(false)
            onEvent(.temporarySharingEnded)
        }
        if canSync {
            publishPasteboardIfChanged()
        }
    }

    /// The server's text, from the `onClipboardText` handler.
    public func receiveText(_ text: String, copyNumber: Int) {
        guard isUnreplaced(copyNumber), isSharingEnabled else {
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount
        remoteCopyChangeCount = pasteboardChangeCount
        localCopyIsUnsent = false
        removeCopiedDownloadIfReplaced()
        onEvent(.remoteTextCopied)
    }

    /// A remote copy none of which comes, from the `onClipboardRemoteCopyUnavailable` handler:
    /// the server's clipboard was emptied (`isEmpty`), or holds nothing the bridge takes, such
    /// as an image, or failed to arrive. Like any remote copy, it is newer than a download still
    /// running and a local copy not yet sent. An emptied server clipboard also clears the
    /// pasteboard while it still holds what came from the server, also while sharing is off:
    /// RDPKit then fetches nothing, but still reports the server's clipboard emptied.
    public func receiveRemoteCopyUnavailable(isEmpty: Bool, copyNumber: Int) {
        guard isUnreplaced(copyNumber) else {
            return
        }
        guard isSharingEnabled else {
            if isEmpty, clearRemoteCopyFromPasteboard() {
                onEvent(.remoteClipboardEmptied(clearedHere: true))
            }
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        if isEmpty {
            onEvent(.remoteClipboardEmptied(clearedHere: clearRemoteCopyFromPasteboard()))
        } else {
            onEvent(.remoteCopyUnavailable)
        }
        pasteboardChangeCount = pasteboard.changeCount
        localCopyIsUnsent = false
        removeCopiedDownloadIfReplaced()
    }

    /// The server's files, from the `onClipboardFileGroupDescriptor` handler: downloads them
    /// and puts them on the pasteboard.
    public func receiveFileList(_ descriptorList: RDPClipboardFileGroupDescriptorW, copyNumber: Int) {
        guard isUnreplaced(copyNumber), isSharingEnabled else {
            return
        }
        // The remote copy is newer than what the pasteboard holds now, so a local copy the
        // poll has not published yet, or that never reached the server, must not replace it;
        // only one made from here on is newer.
        cancelLocalFileRead()
        discardFileTransfer()
        pasteboardChangeCount = pasteboard.changeCount
        localCopyIsUnsent = false
        removeCopiedDownloadIfReplaced()
        guard let session else {
            return
        }
        // Planned before the download, so a copy RDPKit would refuse gets no folder.
        let plan: RDPClipboardDownloadPlan
        let directory: URL
        do {
            plan = try descriptorList.downloadPlan(limits: downloadLimits)
            directory = try makeDownloadDirectory()
        } catch let error as RDPClipboardRemoteFileTransferPlanningError {
            onEvent(.remoteFilesRefused(error))
            return
        } catch {
            onEvent(.downloadFailed(.folderNotCreated))
            return
        }
        let id = UUID()
        // Awaited: RDPKit waits for each report, so they arrive in order, and the last before
        // the download returns.
        let progress: @Sendable (RDPClipboardDownloadProgress) async -> Void = { [weak self] progress in
            await self?.receiveDownloadProgress(progress, of: id)
        }
        let quarantineAgentName = quarantineAgentName
        let task = Task { [weak self] in
            let outcome: Result<RDPClipboardDownload, Error>
            do {
                outcome = try .success(await session.downloadRemoteFiles(
                    plan,
                    copyNumber: copyNumber,
                    into: directory,
                    progress: progress,
                    writeFile: { data, fileURL in
                        try Self.writeQuarantined(data, to: fileURL, agentName: quarantineAgentName)
                    }
                ))
            } catch {
                outcome = .failure(error)
            }
            // A bridge freed meanwhile, its window closed, had dropped the download, but a
            // file write under way then finished first.
            guard let self else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            finishFileDownload(id, with: outcome, in: directory)
        }
        fileDownload = FileDownload(id: id, task: task, directory: directory)
    }

    /// Removes the UUID-named folders in `directory` last changed before `cutoff`, other than
    /// those at `keptDirectoryPaths`, such as the folders of files still on the pasteboard:
    /// downloads earlier runs left, cut short by a crash or on the pasteboard at quit. Anything
    /// else there, and links, are left alone. Reading which files the pasteboard holds reads
    /// its contents, which an app that does not share it may not want to; it can leave the
    /// folders be while the pasteboard holds any file instead.
    public nonisolated static func removeStaleDownloadDirectories(
        in directory: URL,
        changedBefore cutoff: Date,
        keeping keptDirectoryPaths: Set<String> = []
    ) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let changedAt = values.contentModificationDate,
                  changedAt < cutoff,
                  keptDirectoryPaths.contains(entry.resolvingSymlinksInPath().path) == false
            else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// The paths of the folders holding the files on `pasteboard`, links resolved: what
    /// ``removeStaleDownloadDirectories(in:changedBefore:keeping:)`` keeps.
    public static func fileDirectoryPaths(on pasteboard: NSPasteboard) -> Set<String> {
        Set(fileURLs(on: pasteboard).map { $0.deletingLastPathComponent().resolvingSymlinksInPath().path })
    }

    /// Whether no publish has replaced remote copy `copyNumber` on the server: one the
    /// session handed over before a publish here can still reach the main thread after it.
    private func isUnreplaced(_ copyNumber: Int) -> Bool {
        session?.hasPublished(since: copyNumber) == false
    }

    /// Clears the pasteboard while it still holds what came from the server, a download's
    /// files included, and says whether it did.
    private func clearRemoteCopyFromPasteboard() -> Bool {
        guard pasteboard.changeCount == remoteCopyChangeCount else {
            return false
        }
        pasteboard.clearContents()
        remoteCopyChangeCount = nil
        removeCopiedDownloadIfReplaced()
        return true
    }

    // MARK: - Local pasteboard

    /// Whether an unchanged pasteboard is sent again: its last send failed or was cut short,
    /// and no read of it is still running.
    private var resendsUnsentLocalCopy: Bool {
        localCopyIsUnsent && localFileRead == nil
    }

    /// `force` sends an unchanged pasteboard too: to a server that has had nothing of it, one
    /// just attached or with sharing just turned on, or again after a send that failed.
    /// `announce` reports the result even when it is no news, for a sync the user asked for.
    /// Returns whether it sends, starts reading files to send, or says the pasteboard cannot
    /// be read.
    @discardableResult
    private func publishPasteboardIfChanged(force: Bool = false, announce: Bool = false) -> Bool {
        guard isSharingEnabled, let session else {
            pasteboardChangeCount = pasteboard.changeCount
            return false
        }
        let nextChangeCount = pasteboard.changeCount
        let isNewCopy = nextChangeCount != pasteboardChangeCount
        guard force || isNewCopy else {
            return false
        }
        if isNewCopy {
            // A newer local copy replaces a remote one still downloading, and one already on
            // the pasteboard.
            discardFileTransfer()
            removeCopiedDownloadIfReplaced()
        }
        pasteboardChangeCount = nextChangeCount
        localCopyIsUnsent = true
        cancelLocalFileRead()
        // A denied read would look like an empty clipboard and empty the server's too, so
        // nothing goes, and the server keeps its copy.
        guard pasteboardAccessIsDenied() == false else {
            if announce || reportedDeniedPasteboardAccess == false {
                reportedDeniedPasteboardAccess = true
                onEvent(.pasteboardAccessDenied)
            }
            return true
        }
        reportedDeniedPasteboardAccess = false
        let fileURLs = Self.fileURLs(on: pasteboard)
        guard fileURLs.isEmpty else {
            // The files go once read, but they replace the server's copy now, as text does:
            // RDPKit publishes an empty copy at once, so the server's older copy is not fetched
            // when sharing turns on, nor applied should it reach this thread late. A remote copy
            // made during the read is newer still, and wins: RDPKit then does not offer the files.
            let copyNumber = session.beginLocalCopy()
            // Reading up to 32 MiB, or a file iCloud has to download first, on the main thread
            // would stall the window and its input. A newer local copy, remote copy, or sharing
            // turned off cancels the publish at once; RDPKit's read stops before the next MiB it
            // reads, and a file iCloud still has to download blocks it until it is available.
            localFileReadAnnounces = announce
            localFileRead = Task { [weak self] in
                let read = Task.detached(priority: .userInitiated) {
                    Result { try RDPClipboardLocalFile.read(contentsOf: fileURLs) }
                }
                let files = await withTaskCancellationHandler {
                    await read.value
                } onCancel: {
                    read.cancel()
                }
                guard Task.isCancelled == false, let self else {
                    return
                }
                localFileRead = nil
                publishReadFiles(files, forCopy: copyNumber, announce: localFileReadAnnounces, isNewCopy: isNewCopy)
            }
            return true
        }
        publishText(announce: announce, isNewCopy: isNewCopy)
        return true
    }

    /// Reports text that could not be sent, for a new local copy or a sync the user asked for;
    /// `announce` also reports text sent and an empty pasteboard. A publish on attaching or as
    /// sharing turns on stays quiet about what the pasteboard already held.
    private func publishText(announce: Bool, isNewCopy: Bool) {
        guard isSharingEnabled, let session else {
            return
        }
        guard let text = pasteboard.string(forType: .string) else {
            session.publishLocalUnicodeText(nil)
            localCopyIsUnsent = false
            if announce {
                onEvent(.localClipboardEmpty)
            }
            return
        }
        // Too large to send, it still replaces the server's older copy, with an empty
        // clipboard, as text sent would: that copy is neither fetched once sharing turns on nor
        // applied should it reach this thread late.
        guard RDPClipboardLimits.canPublishUnicodeText(text) else {
            session.publishLocalUnicodeText(nil)
            if announce || isNewCopy {
                onEvent(.localTextTooLarge)
            }
            return
        }
        session.publishLocalUnicodeText(text)
        localCopyIsUnsent = false
        if announce {
            onEvent(.localTextShared)
        }
    }

    /// Offers the files read for local copy `copyNumber`, unless a newer copy replaced it, or
    /// says why they could not be read; the empty copy that began it stays on the server either
    /// way. Files shared, or why not, are reported for a new local copy or a sync the user
    /// asked for.
    private func publishReadFiles(
        _ result: Result<[RDPClipboardLocalFile], Error>,
        forCopy copyNumber: Int,
        announce: Bool,
        isNewCopy: Bool
    ) {
        guard isSharingEnabled, let session else {
            return
        }
        let reportsResult = announce || isNewCopy
        switch result {
        case let .success(files):
            guard session.publishLocalFiles(files, forCopy: copyNumber) else {
                return
            }
            localCopyIsUnsent = false
            if reportsResult {
                onEvent(.localFilesShared(count: files.count))
            }
        case let .failure(error as RDPClipboardLocalFileReadError):
            if reportsResult {
                onEvent(.localFilesNotShared(error))
            }
        case .failure:
            // Cancelled.
            return
        }
    }

    private func cancelLocalFileRead() {
        localFileRead?.cancel()
        localFileRead = nil
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            appendFileURL(item.string(forType: .fileURL), to: &urls)
        }
        if urls.isEmpty, pasteboard.types?.contains(.fileURL) == true {
            appendFileURL(pasteboard.string(forType: .fileURL), to: &urls)
        }
        return urls
    }

    private static func appendFileURL(_ value: String?, to urls: inout [URL]) {
        guard let value,
              let url = URL(string: value),
              url.isFileURL,
              urls.contains(url) == false
        else {
            return
        }
        urls.append(url)
    }

    /// Whether the user turned off this app's access to `pasteboard` in System Settings, which
    /// macOS 15.4 added.
    private static func deniesAccess(to pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) {
            return pasteboard.accessBehavior == .alwaysDeny
        }
        return false
    }

    // MARK: - Remote file downloads

    /// Reports which file of download `id` starts, while it is the download under way: a newer
    /// copy can discard it while a report is on its way here. RDPKit reports each file as it
    /// starts, then as it comes; only its start is news, and of many files, once per tenth.
    private func receiveDownloadProgress(_ progress: RDPClipboardDownloadProgress, of id: UUID) {
        guard fileDownload?.id == id, progress.fileByteCount == nil else {
            return
        }
        let offset = progress.fileOffset
        let fileCount = progress.fileCount
        guard offset == 0 || offset * 10 / fileCount != (offset - 1) * 10 / fileCount else {
            return
        }
        onEvent(.downloadProgress(progress))
    }

    /// Puts the files of download `id` on the pasteboard, unless a newer copy discarded them,
    /// or says why it failed. Discarding a download cancelled it and removed its folder, but a
    /// file write under way then finished first, so its `directory` is removed again.
    private func finishFileDownload(_ id: UUID, with outcome: Result<RDPClipboardDownload, Error>, in directory: URL) {
        guard let fileDownload, fileDownload.id == id else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let download: RDPClipboardDownload
        switch outcome {
        case let .success(value):
            download = value
        case let .failure(error):
            failFileDownload(Self.downloadFailure(for: error))
            return
        }
        // A local copy made since the remote one, which the poll has not seen yet, is newer
        // than the download, so it stays. RDPKit does not end a download for a copy that comes
        // after its last answer.
        guard pasteboard.changeCount == pasteboardChangeCount else {
            failFileDownload(.clipboardChanged)
            return
        }
        cancelLocalFileRead()
        pasteboard.clearContents()
        removeCopiedDownloadIfReplaced()
        guard pasteboard.writeObjects(download.fileURLs.map { $0 as NSURL }) else {
            failFileDownload(.pasteboardRefused)
            return
        }
        self.fileDownload = nil
        pasteboardChangeCount = pasteboard.changeCount
        remoteCopyChangeCount = pasteboardChangeCount
        copiedDownload = (fileDownload.directory, pasteboardChangeCount)
        onEvent(.remoteFilesCopied(download))
    }

    /// Ends the download under way, its folder removed, saying why; nil says nothing.
    private func failFileDownload(_ failure: DownloadFailure?) {
        discardFileTransfer()
        if let failure {
            onEvent(.downloadFailed(failure))
        }
    }

    /// Why a download failed, or nil when there is nothing to say: a newer copy or the
    /// session's end replaced it, and says so itself.
    private static func downloadFailure(for error: Error) -> DownloadFailure? {
        switch error {
        case RDPClipboardDownloadError.replaced, RDPClipboardDownloadError.sessionEnded, is CancellationError:
            nil
        case RDPClipboardDownloadError.timedOut:
            .timedOut
        case RDPClipboardDownloadError.refused:
            .refused
        case RDPClipboardDownloadError.incomplete:
            .incomplete
        case RDPClipboardDownloadError.totalByteLimitExceeded:
            .totalByteLimitExceeded
        default:
            .notSaved
        }
    }

    /// Cancels the download under way and removes its folder. A file write under way finishes
    /// first, so the download's task removes the folder again once it ends, also once the
    /// bridge is gone.
    private func discardFileTransfer() {
        guard let fileDownload else {
            return
        }
        fileDownload.task.cancel()
        try? FileManager.default.removeItem(at: fileDownload.directory)
        self.fileDownload = nil
    }

    /// Removes the last download put on the pasteboard once something else replaced it there.
    private func removeCopiedDownloadIfReplaced() {
        guard let copiedDownload, pasteboard.changeCount != copiedDownload.changeCount else {
            return
        }
        try? FileManager.default.removeItem(at: copiedDownload.directory)
        self.copiedDownload = nil
    }

    /// A new folder for each download, so the files of the one before stay on the pasteboard
    /// until this one replaces them.
    private func makeDownloadDirectory() throws -> URL {
        let directory = downloadRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a remote file quarantined, as a browser download is, so Gatekeeper checks an app
    /// or script from the server before it runs. Finder keeps the mark on the copy a paste makes.
    private nonisolated static func writeQuarantined(_ contents: Data, to fileURL: URL, agentName: String) throws {
        var fileURL = fileURL
        try contents.write(to: fileURL, options: .atomic)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try fileURL.setResourceValues(values)
    }
}

/// A remote copy of files RDPKit is downloading into `directory`.
private struct FileDownload {
    let id: UUID
    let task: Task<Void, Never>
    let directory: URL
}
#endif
