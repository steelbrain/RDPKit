import AppKit
import RDPKit

private let maximumClipboardFileBytes = 32 * 1024 * 1024
/// The most asked for in one FILECONTENTS_RANGE request; servers may send less anyway.
/// Half a MiB arrives within the timeout down to about 4 KB/s, and costs a round trip per
/// range: 64 for the 32 MiB limit.
private let maximumFileRangeByteCount: UInt64 = 512 * 1024
/// How long a file contents request may go unanswered before the transfer fails: long
/// enough for a range on a slow link, or a server that fetches a cloud file first.
private let fileContentsRequestTimeout: TimeInterval = 120
/// Age at which a download folder an earlier run left is removed at launch. A newer one
/// may belong to another copy of the app that is still downloading.
private let staleDownloadDirectoryAge: TimeInterval = 60 * 60

/// Where the clipboard bridge sends: the session's `RDPClipboardSession`.
protocol RDPClipboardSending: AnyObject {
    /// Off while sharing is off, so the server's copies are not even fetched.
    var fetchesRemoteCopies: Bool { get set }
    func publishLocalUnicodeText(_ text: String?)
    func publishLocalFiles(_ files: [RDPClipboardLocalFile])
    func requestRemoteFileSize(streamID: UInt32, fileIndex: Int32) throws
    func requestRemoteFileRange(streamID: UInt32, fileIndex: Int32, position: UInt64, requestedByteCount: UInt32) throws
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
    private var localFileRead: Task<Void, Never>?
    private var temporarySharingExpiresAt: Date?
    private var timerTick = Date()
    private var fileTransfer: RemoteFileTransfer?
    private var downloadDirectory: URL?
    private var nextStreamID: UInt32 = 1

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
        publishPasteboardIfChanged(force: true)
    }

    func detach() {
        session = nil
        message = nil
        discardFileTransfer()
        cancelLocalFileRead()
        removeDownloadDirectoryUnlessOnPasteboard()
        pasteboardChangeCount = pasteboard.changeCount
    }

    /// The user's choice, which also ends a temporary share.
    func setSharingEnabled(_ enabled: Bool) {
        isSharingEnabled = enabled
        temporarySharingExpiresAt = nil
        session?.fetchesRemoteCopies = enabled
        guard enabled else {
            discardFileTransfer()
            cancelLocalFileRead()
            session?.publishLocalUnicodeText(nil)
            message = "Disabled."
            pasteboardChangeCount = pasteboard.changeCount
            return
        }
        message = session == nil ? nil : "Ready."
        publishPasteboardIfChanged(force: true)
    }

    func syncNow() {
        publishPasteboardIfChanged(force: true)
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

    /// Called once a second: fails a file transfer the server stopped answering, ends
    /// temporary sharing and publishes local pasteboard changes.
    func poll(now: Date = Date()) {
        if let fileTransfer, now.timeIntervalSince(fileTransfer.requestedAt) >= fileContentsRequestTimeout {
            // A late answer no longer matches a transfer, so it is dropped.
            failFileTransfer(fileTransfer, message: "Remote file transfer timed out.")
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

    func receiveText(_ text: String) {
        guard isSharingEnabled else {
            return
        }
        cancelLocalFileRead()
        discardFileTransfer()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChangeCount = pasteboard.changeCount
        message = "Remote text copied."
    }

    func receiveFileList(_ descriptorList: RDPClipboardFileGroupDescriptorW) {
        guard isSharingEnabled else {
            return
        }
        discardFileTransfer()
        do {
            let files = try descriptorList.remoteFileTransferFiles(
                maximumTotalByteCount: UInt64(maximumClipboardFileBytes)
            )
            requestFileSize(RemoteFileTransfer(
                files: files,
                streamID: makeStreamID(),
                downloadDirectory: try makeDownloadDirectory(),
                pasteboardChangeCount: pasteboard.changeCount
            ))
        } catch let error as RDPClipboardRemoteFileTransferPlanningError {
            message = planningMessage(for: error)
        } catch {
            message = "Remote files could not be prepared."
        }
    }

    func receiveFileContents(_ response: RDPClipboardFileContentsResponse) {
        guard isSharingEnabled,
              var transfer = fileTransfer,
              transfer.streamID == response.streamID
        else {
            return
        }
        // Taken out so the received bytes are appended in place.
        fileTransfer = nil
        guard response.ok else {
            failFileTransfer(transfer, message: "Remote file transfer failed.")
            return
        }

        guard transfer.expectedByteCount != nil else {
            do {
                let byteCount = try response.decodedFileSize()
                guard byteCount <= UInt64(maximumClipboardFileBytes),
                      transfer.totalExpectedByteCount <= UInt64(maximumClipboardFileBytes) - byteCount
                else {
                    failFileTransfer(transfer, message: "Remote files exceed 32 MiB.")
                    return
                }
                transfer.expectedByteCount = byteCount
                transfer.totalExpectedByteCount += byteCount
                continueFileTransfer(transfer)
            } catch {
                failFileTransfer(transfer, message: "Remote file size request failed.")
            }
            return
        }

        // [MS-RDPECLIP] 2.2.5.4 does not promise all of a range in one answer, and servers send
        // less, so the rest is asked for again. Nothing before the end, or more than asked, fails.
        guard response.data.isEmpty == false,
              response.data.count <= Int(transfer.requestedByteCount)
        else {
            failFileTransfer(transfer, message: "Remote file transfer was incomplete.")
            return
        }
        transfer.receivedData.append(response.data)
        continueFileTransfer(transfer)
    }

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
        // The local copy is newer than remote files still downloading.
        discardFileTransfer()
        cancelLocalFileRead()
        let fileURLs = Self.fileURLs(on: pasteboard)
        guard fileURLs.isEmpty else {
            // Reading up to 32 MiB, or a file iCloud has to download first, would stall the UI.
            localFileRead = Task { [weak self] in
                let payload = await Task.detached(priority: .userInitiated) {
                    Self.localFiles(from: fileURLs)
                }.value
                guard Task.isCancelled == false else {
                    return
                }
                self?.publish(payload)
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
            message = "Local text synced."
        case let .files(files):
            session.publishLocalFiles(files)
            message = files.count == 1 ? "Local file synced." : "\(files.count) local files synced."
        case .empty:
            session.publishLocalUnicodeText(nil)
            message = "Local clipboard has no text."
        case let .unsupported(reason):
            session.publishLocalUnicodeText(nil)
            message = reason
        case let .ignored(reason):
            message = reason
        }
    }

    private func cancelLocalFileRead() {
        localFileRead?.cancel()
        localFileRead = nil
    }

    private func localTextPayload() -> LocalPayload {
        if let text = pasteboard.string(forType: .string) {
            guard RDPClipboardLimits.canPublishUnicodeText(text) else {
                return .ignored("Local text is too large to sync.")
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

    nonisolated private static func localFiles(from urls: [URL]) -> LocalPayload {
        var files: [RDPClipboardLocalFile] = []
        var totalByteCount = 0

        for url in urls {
            let fileURL = url.standardizedFileURL
            let fileName = fileURL.lastPathComponent
            guard fileName.isEmpty == false else {
                return .unsupported("Local file clipboard was not shared.")
            }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resourceValues.isRegularFile == true else {
                    return .unsupported("Local clipboard has non-file items; remote clipboard cleared.")
                }
                guard let byteCount = resourceValues.fileSize,
                      byteCount >= 0
                else {
                    return .unsupported("Local file clipboard could not be read; remote clipboard cleared.")
                }
                guard byteCount <= maximumClipboardFileBytes,
                      totalByteCount <= maximumClipboardFileBytes - byteCount
                else {
                    return .unsupported("Local clipboard files exceed 32 MiB; remote clipboard cleared.")
                }

                let contents = try Data(contentsOf: fileURL)
                guard contents.count <= maximumClipboardFileBytes,
                      totalByteCount <= maximumClipboardFileBytes - contents.count
                else {
                    return .unsupported("Local clipboard files exceed 32 MiB; remote clipboard cleared.")
                }
                totalByteCount += contents.count
                files.append(RDPClipboardLocalFile(fileName: fileName, contents: contents))
            } catch {
                return .unsupported("Local file clipboard could not be read; remote clipboard cleared.")
            }
        }

        return files.isEmpty ? .empty : .files(files)
    }

    /// Asks for the next range of the current file, or saves it once all of it has arrived.
    private func continueFileTransfer(_ transfer: RemoteFileTransfer) {
        guard let currentFile = transfer.currentFile,
              let expectedByteCount = transfer.expectedByteCount
        else {
            failFileTransfer(transfer, message: "Remote file transfer failed.")
            return
        }
        let receivedByteCount = UInt64(transfer.receivedData.count)
        guard receivedByteCount < expectedByteCount else {
            saveCurrentFile(currentFile, of: transfer)
            return
        }
        guard let session else {
            failFileTransfer(transfer, message: "Clipboard is not ready.")
            return
        }

        var transfer = transfer
        transfer.requestedByteCount = UInt32(min(maximumFileRangeByteCount, expectedByteCount - receivedByteCount))
        transfer.requestedAt = Date()
        fileTransfer = transfer
        do {
            try session.requestRemoteFileRange(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex,
                position: receivedByteCount,
                requestedByteCount: transfer.requestedByteCount
            )
        } catch {
            failFileTransfer(transfer, message: "Remote file request failed.")
        }
    }

    private func saveCurrentFile(_ currentFile: RDPClipboardRemoteFileTransferFile, of transfer: RemoteFileTransfer) {
        do {
            var nextTransfer = transfer
            let fileURL = transfer.downloadDirectory.appendingPathComponent(currentFile.fileName, isDirectory: false)
            try transfer.receivedData.write(to: fileURL, options: .atomic)
            try Self.quarantine(fileURL)
            nextTransfer.downloadedFileURLs.append(fileURL)

            guard nextTransfer.currentFileOffset + 1 < nextTransfer.files.count else {
                finishFileTransfer(nextTransfer)
                return
            }

            nextTransfer.currentFileOffset += 1
            nextTransfer.streamID = makeStreamID()
            nextTransfer.expectedByteCount = nil
            nextTransfer.receivedData = Data()
            requestFileSize(nextTransfer)
        } catch {
            failFileTransfer(transfer, message: "Remote file could not be saved.")
        }
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

    private func requestFileSize(_ transfer: RemoteFileTransfer) {
        guard let session,
              let currentFile = transfer.currentFile
        else {
            failFileTransfer(transfer, message: "Clipboard is not ready.")
            return
        }

        var transfer = transfer
        transfer.requestedAt = Date()
        fileTransfer = transfer
        do {
            try session.requestRemoteFileSize(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex
            )
            message = transfer.files.count == 1
                ? "Downloading remote file: \(currentFile.fileName)."
                : "Downloading remote files: \(transfer.currentFileOffset + 1) of \(transfer.files.count)."
        } catch {
            failFileTransfer(transfer, message: "Remote file request failed.")
        }
    }

    private func finishFileTransfer(_ transfer: RemoteFileTransfer) {
        // Something copied since the download began is newer than these files.
        guard pasteboard.changeCount == transfer.pasteboardChangeCount else {
            failFileTransfer(transfer, message: "Clipboard changed; remote files were not copied.")
            return
        }
        cancelLocalFileRead()
        pasteboard.clearContents()
        guard pasteboard.writeObjects(transfer.downloadedFileURLs.map { $0 as NSURL }) else {
            failFileTransfer(transfer, message: "Remote files could not be copied.")
            return
        }

        pasteboardChangeCount = pasteboard.changeCount
        fileTransfer = nil
        if transfer.downloadedFileURLs.count == 1,
           let fileName = transfer.files.first?.fileName
        {
            message = "Remote file copied: \(fileName)."
        } else {
            message = "\(transfer.downloadedFileURLs.count) remote files copied."
        }
    }

    private func failFileTransfer(_ transfer: RemoteFileTransfer, message: String) {
        removeDownloadDirectory(transfer.downloadDirectory)
        fileTransfer = nil
        self.message = message
    }

    private func discardFileTransfer() {
        guard let fileTransfer else {
            return
        }
        removeDownloadDirectory(fileTransfer.downloadDirectory)
        self.fileTransfer = nil
    }

    private func removeDownloadDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        if downloadDirectory == directory {
            downloadDirectory = nil
        }
    }

    /// Removes the last completed download once nothing can paste it any more.
    private func removeDownloadDirectoryUnlessOnPasteboard() {
        guard let downloadDirectory,
              Self.fileDirectoryPaths(on: pasteboard).contains(downloadDirectory.resolvingSymlinksInPath().path) == false
        else {
            return
        }
        removeDownloadDirectory(downloadDirectory)
    }

    /// Replaces the previous download directory; files from the last completed transfer stay on
    /// the pasteboard until the next transfer starts.
    private func makeDownloadDirectory() throws -> URL {
        let fileManager = FileManager.default
        if let downloadDirectory {
            try? fileManager.removeItem(at: downloadDirectory)
        }

        let directory = Self.downloadsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        downloadDirectory = directory
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

    private func makeStreamID() -> UInt32 {
        let streamID = nextStreamID
        nextStreamID = streamID == UInt32.max ? 1 : streamID + 1
        return streamID
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
        }
    }
}

private enum LocalPayload: Equatable, Sendable {
    case text(String)
    case files([RDPClipboardLocalFile])
    case empty
    case unsupported(String)
    case ignored(String)
}

private struct RemoteFileTransfer: Equatable {
    var files: [RDPClipboardRemoteFileTransferFile]
    var currentFileOffset = 0
    var streamID: UInt32
    /// Nil until the server answers the size request.
    var expectedByteCount: UInt64?
    var receivedData = Data()
    var requestedByteCount: UInt32 = 0
    var totalExpectedByteCount: UInt64 = 0
    var downloadedFileURLs: [URL] = []
    var downloadDirectory: URL
    /// The pasteboard's change count when the transfer began; any other means a newer copy.
    var pasteboardChangeCount: Int
    /// When the request now unanswered went out.
    var requestedAt = Date()

    init(
        files: [RDPClipboardRemoteFileTransferFile],
        streamID: UInt32,
        downloadDirectory: URL,
        pasteboardChangeCount: Int
    ) {
        self.files = files
        self.streamID = streamID
        self.downloadDirectory = downloadDirectory
        self.pasteboardChangeCount = pasteboardChangeCount
    }

    var currentFile: RDPClipboardRemoteFileTransferFile? {
        files.indices.contains(currentFileOffset) ? files[currentFileOffset] : nil
    }
}
