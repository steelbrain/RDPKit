import AppKit
import RDPKit

/// What a remote copy of files may hold: RDPKit's defaults, 32 MiB and 1000 files.
private let remoteFileDownloadLimits = RDPClipboardDownloadLimits()
/// Age at which a download folder an earlier run left is removed at launch. A newer one
/// may belong to another copy of the app that is still downloading.
private let staleDownloadDirectoryAge: TimeInterval = 60 * 60

/// Where the clipboard bridge sends: the session's `RDPClipboardSession`.
protocol RDPClipboardSending: AnyObject, Sendable {
    /// Off while sharing is off, so the server's copies are not even fetched. Turned on, it
    /// fetches a copy the server announced while it was off, unless a publish replaced it.
    var fetchesRemoteCopies: Bool { get set }
    var isAwaitingRemoteCopy: Bool { get }
    /// Whether a publish since replaced, on the server, the remote copy numbered
    /// `remoteCopyNumber`: the `copyNumber` its handler got.
    func hasPublished(since remoteCopyNumber: Int) -> Bool
    func publishLocalUnicodeText(_ text: String?)
    func publishLocalFiles(_ files: [RDPClipboardLocalFile])
    /// Publishes an empty copy while the server's clipboard holds this Mac's last one.
    @discardableResult
    func withdrawLocalCopy() -> Bool
    /// Publishes an empty copy at once for files still to be read, and returns its number.
    func beginLocalCopy() -> Int
    /// Offers the files read for copy `copyNumber`, unless a newer copy replaced it.
    @discardableResult
    func publishLocalFiles(_ files: [RDPClipboardLocalFile], forCopy copyNumber: Int) -> Bool
    func downloadRemoteFiles(
        _ list: RDPClipboardFileGroupDescriptorW,
        copyNumber: Int,
        into directory: URL,
        limits: RDPClipboardDownloadLimits,
        progress: (@Sendable (RDPClipboardDownloadProgress) -> Void)?,
        writeFile: @Sendable (Data, URL) throws -> Void
    ) async throws -> RDPClipboardDownload
}

extension RDPClipboardSession: RDPClipboardSending {}

/// Bridges the macOS pasteboard and a session's CLIPRDR channel: publishes local text and
/// files, applies remote text, and downloads remote files into a temporary directory.
@MainActor
final class RDPRemoteSessionClipboard {
    private(set) var session: (any RDPClipboardSending)?
    private(set) var isSharingEnabled: Bool
    private let pasteboard: NSPasteboard
    private var message: String?
    private var pasteboardChangeCount: Int
    /// Whether the local copy last seen has not reached the server: it could not be read or
    /// sent, or its read was cut short. A remote copy since is newer, which clears it.
    private var localCopyIsUnsent = false
    /// Nil once the read has finished.
    private var localFileRead: Task<Void, Never>?
    private var temporarySharingExpiresAt: Date?
    private var timerTick = Date()
    private var fileDownload: FileDownload?
    /// The last download put on the pasteboard, kept while the pasteboard may list its files.
    private var pastedDownload: PastedDownload?
    /// The pasteboard's change count once a remote copy was put on it: while it is unchanged,
    /// the pasteboard holds what came from the server.
    private var remoteCopyChangeCount: Int?

    init(isSharingEnabled: Bool, pasteboard: NSPasteboard = .general) {
        self.isSharingEnabled = isSharingEnabled
        self.pasteboard = pasteboard
        pasteboardChangeCount = pasteboard.changeCount
    }

    var canSync: Bool {
        isSharingEnabled && session != nil
    }

    /// Off while sharing is on for good, which a temporary share would end.
    var canStartTemporarySharing: Bool {
        session != nil && (isSharingEnabled == false || temporarySharingExpiresAt != nil)
    }

    var statusMessage: String {
        guard isSharingEnabled else {
            return "Disabled."
        }
        return message ?? (session == nil ? "Not ready." : "Ready.")
    }

    var temporarySharingButtonTitle: String {
        guard let temporarySharingExpiresAt else {
            return "Share for 30s"
        }
        let remainingSeconds = temporarySharingExpiresAt.timeIntervalSince(timerTick)
        return "Sharing \(max(0, Int(ceil(remainingSeconds))))s"
    }

    func attach(_ session: any RDPClipboardSending) {
        self.session = session
        session.fetchesRemoteCopies = isSharingEnabled
        guard isSharingEnabled else {
            session.publishLocalUnicodeText(nil)
            message = "Disabled."
            return
        }
        message = "Ready."
        // The session is fetching a copy the server announced before the bridge attached. It is
        // newer than the pasteboard, which publishing now would put in its place on the server;
        // should it never arrive, Sync Now sends the pasteboard.
        guard session.isAwaitingRemoteCopy == false else {
            pasteboardChangeCount = pasteboard.changeCount
            localCopyIsUnsent = true
            return
        }
        publishPasteboardIfChanged(force: true)
    }

    func detach() {
        session = nil
        message = nil
        // A later session's server has a clipboard of its own.
        remoteCopyChangeCount = nil
        discardFileTransfer()
        cancelLocalFileRead()
        removePastedDownloadUnlessOnPasteboard()
        pasteboardChangeCount = pasteboard.changeCount
    }

    /// The user's choice, which also ends a temporary share.
    func setSharingEnabled(_ enabled: Bool) {
        let wasEnabled = isSharingEnabled
        isSharingEnabled = enabled
        temporarySharingExpiresAt = nil
        guard enabled else {
            session?.fetchesRemoteCopies = false
            discardFileTransfer()
            cancelLocalFileRead()
            // Windows empties its clipboard for an empty Format List, so only this Mac's copy
            // is taken back: one the server's user made since is theirs, and left alone.
            session?.withdrawLocalCopy()
            message = "Disabled."
            pasteboardChangeCount = pasteboard.changeCount
            return
        }
        // Already on, the server may hold a newer copy, or be sending one, that sending the
        // pasteboard again would replace, so only what Sync Now sends goes.
        guard wasEnabled == false else {
            syncNow()
            return
        }
        message = session == nil ? nil : "Ready."
        // The pasteboard goes first: it replaces on the server a copy announced while sharing
        // was off, which turning fetching on would fetch.
        publishPasteboardIfChanged(force: true)
        session?.fetchesRemoteCopies = true
    }

    /// Sends a local copy the next poll would, or again one that has not reached the server,
    /// such as a file iCloud had not downloaded yet. A pasteboard the server has, or that a
    /// newer remote copy replaced, is not sent again, so that copy, or its download, is kept.
    func syncNow() {
        publishPasteboardIfChanged(force: localCopyIsUnsent && localFileRead == nil)
    }

    func startTemporarySharing() {
        guard canStartTemporarySharing else {
            if session == nil {
                message = "Not ready."
            }
            return
        }

        setSharingEnabled(true)
        let now = Date()
        timerTick = now
        temporarySharingExpiresAt = now.addingTimeInterval(30)
        message = "Temporary sharing enabled."
    }

    /// Called once a second: removes a download a newer copy replaced, ends temporary sharing
    /// and publishes local pasteboard changes.
    func poll(now: Date = Date()) {
        if let pastedDownload, pasteboard.changeCount != pastedDownload.pasteboardChangeCount {
            removePastedDownloadUnlessOnPasteboard()
        }
        if let temporarySharingExpiresAt {
            timerTick = now
            if now >= temporarySharingExpiresAt {
                self.temporarySharingExpiresAt = nil
                if isSharingEnabled {
                    setSharingEnabled(false)
                    message = "Temporary sharing ended."
                }
            }
        }
        if canSync {
            publishPasteboardIfChanged()
        }
    }

    func receiveText(_ text: String, copyNumber: Int) {
        guard isSharingEnabled, isUnreplaced(copyNumber) else {
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount
        remoteCopyChangeCount = pasteboardChangeCount
        localCopyIsUnsent = false
        message = "Remote text copied."
    }

    /// A remote copy none of which comes: the server's clipboard was emptied (`isEmpty`), or
    /// holds nothing this bridge takes, such as an image, or what it does could not be fetched.
    /// It is newer than the remote copy before it, whose download is dropped. An emptied
    /// clipboard also clears the pasteboard while it holds what came from the server, as
    /// [MS-RDPECLIP] 3.1.5.2.2 has a Format List replace the local clipboard, so a password a
    /// password manager cleared there does not stay here; a local copy since is kept.
    func receiveRemoteCopyUnavailable(isEmpty: Bool, copyNumber: Int) {
        guard isSharingEnabled, isUnreplaced(copyNumber) else {
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        if isEmpty, pasteboard.changeCount == remoteCopyChangeCount {
            pasteboard.clearContents()
            remoteCopyChangeCount = nil
            message = "Remote clipboard emptied; cleared here too."
        } else {
            message = isEmpty ? "Remote clipboard emptied." : "No text or files arrived from the remote copy."
        }
        // A local copy the poll has not published yet is older than this one.
        pasteboardChangeCount = pasteboard.changeCount
        localCopyIsUnsent = false
    }

    func receiveFileList(_ descriptorList: RDPClipboardFileGroupDescriptorW, copyNumber: Int) {
        guard isSharingEnabled, isUnreplaced(copyNumber) else {
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        // A local copy the poll has not published yet, or that never reached the server, is
        // older than these files.
        pasteboardChangeCount = pasteboard.changeCount
        localCopyIsUnsent = false
        guard let session else {
            return
        }
        let files: [RDPClipboardRemoteFileTransferFile]
        let directory: URL
        do {
            files = try descriptorList.remoteFileTransferFiles(
                maximumTotalByteCount: remoteFileDownloadLimits.maximumTotalByteCount,
                maximumFileCount: remoteFileDownloadLimits.maximumFileCount
            )
            directory = try makeDownloadDirectory()
        } catch let error as RDPClipboardRemoteFileTransferPlanningError {
            message = planningMessage(for: error)
            return
        } catch {
            message = "Remote files could not be prepared."
            return
        }
        let id = UUID()
        let showProgress: @Sendable (RDPClipboardDownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor [self] in
                self?.showDownloadProgress(progress, of: id)
            }
        }
        let task = Task { [weak self] in
            let outcome: Result<RDPClipboardDownload, Error>
            do {
                outcome = try .success(await session.downloadRemoteFiles(
                    descriptorList,
                    copyNumber: copyNumber,
                    into: directory,
                    limits: remoteFileDownloadLimits,
                    progress: showProgress,
                    writeFile: { data, fileURL in
                        try data.write(to: fileURL, options: .atomic)
                        try Self.quarantine(fileURL)
                    }
                ))
            } catch {
                outcome = .failure(error)
            }
            self?.finishFileDownload(id, with: outcome, in: directory)
        }
        fileDownload = FileDownload(id: id, task: task, directory: directory, pasteboardChangeCount: pasteboardChangeCount)
        showDownloadProgress(
            RDPClipboardDownloadProgress(
                fileOffset: 0,
                fileCount: files.count,
                fileName: files[0].fileName,
                receivedByteCount: 0,
                fileByteCount: nil
            ),
            of: id
        )
    }

    /// The download under way, for tests to wait on.
    var fileDownloadTask: Task<Void, Never>? {
        fileDownload?.task
    }

    /// Whether no publish has replaced remote copy `copyNumber` on the server. One the session
    /// handed over before a publish here can still reach the main thread after it.
    private func isUnreplaced(_ copyNumber: Int) -> Bool {
        session?.hasPublished(since: copyNumber) == false
    }

    /// `force` sends an unchanged pasteboard too, to a server that has had nothing of it:
    /// one just attached, or with sharing just turned on.
    private func publishPasteboardIfChanged(force: Bool = false) {
        guard isSharingEnabled, session != nil else {
            pasteboardChangeCount = pasteboard.changeCount
            return
        }

        let nextChangeCount = pasteboard.changeCount
        guard force || nextChangeCount != pasteboardChangeCount else {
            return
        }

        pasteboardChangeCount = nextChangeCount
        localCopyIsUnsent = true
        // The local copy is newer than remote files still downloading.
        discardFileTransfer()
        cancelLocalFileRead()
        let fileURLs = Self.fileURLs(on: pasteboard)
        guard fileURLs.isEmpty else {
            // The files go once read, but they replace the server's copy now, as text does: an
            // empty clipboard goes at once, so the server's older copy is not fetched when
            // sharing turns on, nor applied should it reach this thread late. A remote copy made
            // during the read is newer still, and wins.
            guard let copyNumber = session?.beginLocalCopy() else {
                return
            }
            // Reading up to 32 MiB, or a file iCloud has to download first, would stall the UI.
            localFileRead = Task { [weak self] in
                let read = Task.detached(priority: .userInitiated) {
                    // RDPKit reads at most 32 MiB.
                    Result { try RDPClipboardLocalFile.read(contentsOf: fileURLs) }
                }
                let files = await withTaskCancellationHandler {
                    await read.value
                } onCancel: {
                    read.cancel()
                }
                guard Task.isCancelled == false else {
                    return
                }
                self?.localFileRead = nil
                self?.publishReadFiles(files, forCopy: copyNumber)
            }
            return
        }
        publish(localTextPayload())
    }

    private func publish(_ payload: LocalPayload) {
        guard isSharingEnabled, let session else {
            return
        }
        switch payload {
        case let .text(text):
            session.publishLocalUnicodeText(text)
            localCopyIsUnsent = false
            message = "Local text synced."
        case .empty:
            session.publishLocalUnicodeText(nil)
            localCopyIsUnsent = false
            message = "Local clipboard has no text."
        case let .unsupported(reason):
            session.publishLocalUnicodeText(nil)
            message = reason
        }
    }

    /// Offers the files read for local copy `copyNumber`, unless a newer copy replaced it, or
    /// says why they could not be read; the empty copy that began it stays on the server.
    private func publishReadFiles(_ result: Result<[RDPClipboardLocalFile], Error>, forCopy copyNumber: Int) {
        guard isSharingEnabled, let session else {
            return
        }
        switch result {
        case let .success(files):
            guard session.publishLocalFiles(files, forCopy: copyNumber) else {
                return
            }
            localCopyIsUnsent = false
            message = files.count == 1 ? "Local file synced." : "\(files.count) local files synced."
        case let .failure(error as RDPClipboardLocalFileReadError):
            message = switch error {
            case .notARegularFile:
                "Local clipboard has non-file items; remote clipboard cleared."
            case .invalidFileName:
                "Local file clipboard was not shared."
            case .unreadable:
                "Local file clipboard could not be read; remote clipboard cleared."
            case .totalByteLimitExceeded:
                "Local clipboard files exceed 32 MiB; remote clipboard cleared."
            }
        case .failure:
            return
        }
    }

    private func cancelLocalFileRead() {
        localFileRead?.cancel()
        localFileRead = nil
    }

    private func localTextPayload() -> LocalPayload {
        if let text = pasteboard.string(forType: .string) {
            // Too large to send, it still replaces the server's older copy, with an empty
            // clipboard, as text sent would: that copy is neither fetched once sharing turns on
            // nor applied should it reach this thread late.
            guard RDPClipboardLimits.canPublishUnicodeText(text) else {
                return .unsupported("Local text is too large to sync; remote clipboard cleared.")
            }
            return .text(text)
        }
        return .empty
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

    /// The paths of the folders holding the files on `pasteboard`, links resolved.
    private static func fileDirectoryPaths(on pasteboard: NSPasteboard) -> Set<String> {
        Set(fileURLs(on: pasteboard).map { $0.deletingLastPathComponent().resolvingSymlinksInPath().path })
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

    /// Marks a file the server sent as downloaded, so Gatekeeper checks it before it is
    /// opened, as it checks a browser download. Copies pasted from it keep the mark.
    nonisolated private static func quarantine(_ fileURL: URL) throws {
        var fileURL = fileURL
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "RDPClient",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try fileURL.setResourceValues(values)
    }

    /// Says which file of download `id` is coming, while it is the download under way.
    private func showDownloadProgress(_ progress: RDPClipboardDownloadProgress, of id: UUID) {
        guard fileDownload?.id == id else {
            return
        }
        message = progress.fileCount == 1
            ? "Downloading remote file: \(progress.fileName)."
            : "Downloading remote files: \(progress.fileOffset + 1) of \(progress.fileCount)."
    }

    /// Puts the files of download `id` on the pasteboard, unless a newer copy replaced them, or
    /// says why it failed. One a newer copy discarded leaves nothing behind.
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
            failFileDownload(message: downloadFailureMessage(for: error))
            return
        }
        // Something copied since the download began is newer than these files.
        guard pasteboard.changeCount == fileDownload.pasteboardChangeCount else {
            failFileDownload(message: "Clipboard changed; remote files were not copied.")
            return
        }
        cancelLocalFileRead()
        pasteboard.clearContents()
        guard pasteboard.writeObjects(download.fileURLs.map { $0 as NSURL }) else {
            failFileDownload(message: "Remote files could not be copied.")
            return
        }

        pasteboardChangeCount = pasteboard.changeCount
        remoteCopyChangeCount = pasteboardChangeCount
        self.fileDownload = nil
        // The files these replaced on the pasteboard can go.
        if let pastedDownload {
            try? FileManager.default.removeItem(at: pastedDownload.directory)
        }
        pastedDownload = PastedDownload(directory: directory, pasteboardChangeCount: pasteboardChangeCount)
        if download.fileURLs.count == 1, let fileURL = download.fileURLs.first {
            message = "Remote file copied: \(fileURL.lastPathComponent)."
        } else {
            message = "\(download.fileURLs.count) remote files copied."
        }
    }

    /// Ends the download under way, its files removed, saying why; nil says nothing.
    private func failFileDownload(message: String?) {
        discardFileTransfer()
        if let message {
            self.message = message
        }
    }

    private func discardFileTransfer() {
        guard let fileDownload else {
            return
        }
        fileDownload.task.cancel()
        try? FileManager.default.removeItem(at: fileDownload.directory)
        self.fileDownload = nil
    }

    /// Why a download failed, or nil when there is nothing to say: a newer copy, or the
    /// session ending, replaced it, and says so itself.
    private func downloadFailureMessage(for error: Error) -> String? {
        switch error {
        case let error as RDPClipboardDownloadError:
            switch error {
            case .replaced, .sessionEnded:
                nil
            case .timedOut:
                "Remote file transfer timed out."
            case .refused:
                "Remote file transfer failed."
            case .incomplete:
                "Remote file transfer was incomplete."
            case .totalByteLimitExceeded:
                "Remote files exceed 32 MiB."
            }
        case let error as RDPClipboardRemoteFileTransferPlanningError:
            planningMessage(for: error)
        case is CancellationError:
            nil
        default:
            "Remote file could not be saved."
        }
    }

    /// Removes the last pasted download once nothing can paste it any more.
    private func removePastedDownloadUnlessOnPasteboard() {
        guard let pastedDownload else {
            return
        }
        let path = pastedDownload.directory.resolvingSymlinksInPath().path
        guard Self.fileDirectoryPaths(on: pasteboard).contains(path) == false else {
            // Looked for again only once the pasteboard changes.
            self.pastedDownload?.pasteboardChangeCount = pasteboard.changeCount
            return
        }
        try? FileManager.default.removeItem(at: pastedDownload.directory)
        self.pastedDownload = nil
    }

    /// A folder of its own for a new transfer. The last pasted download stays until a
    /// finished transfer replaces it on the pasteboard, so a failed one leaves it pasteable.
    private func makeDownloadDirectory() throws -> URL {
        let directory = Self.downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Holds one folder, named by a UUID, per remote file transfer.
    nonisolated static let downloadsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RDPClientRemoteClipboard", isDirectory: true)

    /// Removes, off the main thread, download folders earlier runs left behind whose files
    /// are not on the pasteboard.
    static func removeStaleDownloadDirectories(pasteboard: NSPasteboard = .general) {
        let keptDirectoryPaths = fileDirectoryPaths(on: pasteboard)
        let cutoff = Date().addingTimeInterval(-staleDownloadDirectoryAge)
        Task.detached(priority: .utility) {
            removeStaleDownloadDirectories(in: downloadsDirectory, keeping: keptDirectoryPaths, changedBefore: cutoff)
        }
    }

    /// Removes the UUID-named folders in `directory` last changed before `cutoff`, except
    /// those at `keptDirectoryPaths`. Anything else there, and links, are left alone.
    nonisolated static func removeStaleDownloadDirectories(
        in directory: URL,
        keeping keptDirectoryPaths: Set<String>,
        changedBefore cutoff: Date
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

    private func planningMessage(for error: RDPClipboardRemoteFileTransferPlanningError) -> String {
        switch error {
        case .emptyFileList:
            "Remote file clipboard is empty."
        case .containsOnlyDirectories:
            "Remote clipboard has folders; file copy is not ready."
        case .invalidFileIndex:
            "Remote file index is not valid."
        case .totalByteLimitExceeded:
            "Remote files exceed 32 MiB."
        case .fileCountLimitExceeded:
            "Remote clipboard has more than \(remoteFileDownloadLimits.maximumFileCount) files."
        }
    }
}

private enum LocalPayload: Equatable, Sendable {
    case text(String)
    case empty
    case unsupported(String)
}

/// The folder of a download put on the pasteboard.
private struct PastedDownload {
    var directory: URL
    /// The pasteboard's change count when its files were last seen on it.
    var pasteboardChangeCount: Int
}

/// A remote copy of files RDPKit is downloading into `directory`.
private struct FileDownload {
    let id: UUID
    let task: Task<Void, Never>
    let directory: URL
    /// The pasteboard's change count when the download began; any other means a newer copy.
    let pasteboardChangeCount: Int
}
