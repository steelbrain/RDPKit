import AppKit
import RDPKit

private let maximumClipboardFileBytes = 32 * 1024 * 1024

/// Bridges the macOS pasteboard and a session's CLIPRDR channel: publishes local text and
/// files, applies remote text, and downloads remote files into a temporary directory.
@MainActor
final class RDPRemoteSessionClipboard {
    private(set) var session: RDPClipboardSession?
    private(set) var isSharingEnabled: Bool
    private var message: String?
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var temporarySharingExpiresAt: Date?
    private var timerTick = Date()
    private var fileTransfer: RemoteFileTransfer?
    private var downloadDirectory: URL?
    private var nextStreamID: UInt32 = 1

    init(isSharingEnabled: Bool) {
        self.isSharingEnabled = isSharingEnabled
    }

    var canSync: Bool {
        isSharingEnabled && session != nil
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

    func attach(_ session: RDPClipboardSession) {
        self.session = session
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
        pasteboardChangeCount = NSPasteboard.general.changeCount
    }

    func setSharingEnabled(_ enabled: Bool) {
        isSharingEnabled = enabled
        guard enabled else {
            temporarySharingExpiresAt = nil
            discardFileTransfer()
            session?.publishLocalUnicodeText(nil)
            message = "Disabled."
            pasteboardChangeCount = NSPasteboard.general.changeCount
            return
        }
        message = session == nil ? nil : "Ready."
        publishPasteboardIfChanged(force: true)
    }

    func syncNow() {
        publishPasteboardIfChanged(force: true)
    }

    func startTemporarySharing() {
        guard session != nil else {
            message = "Not ready."
            return
        }

        let now = Date()
        timerTick = now
        temporarySharingExpiresAt = now.addingTimeInterval(30)
        setSharingEnabled(true)
        message = "Temporary sharing enabled."
    }

    /// Called once a second: ends temporary sharing and publishes local pasteboard changes.
    func poll(now: Date = Date()) {
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
        let pasteboard = NSPasteboard.general
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
                downloadDirectory: try makeDownloadDirectory()
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
        guard response.ok else {
            failFileTransfer(transfer, message: "Remote file transfer failed.")
            return
        }

        if transfer.requestedRange {
            receiveFileData(response.data, transfer: transfer)
            return
        }

        do {
            let byteCount = try response.decodedFileSize()
            guard byteCount <= UInt64(maximumClipboardFileBytes),
                  transfer.totalExpectedByteCount <= UInt64(maximumClipboardFileBytes) - byteCount,
                  let requestedByteCount = UInt32(exactly: byteCount)
            else {
                failFileTransfer(transfer, message: "Remote files exceed 32 MiB.")
                return
            }

            guard let session else {
                failFileTransfer(transfer, message: "Clipboard is not ready.")
                return
            }

            transfer.expectedByteCount = byteCount
            transfer.totalExpectedByteCount += byteCount
            if byteCount == 0 {
                fileTransfer = transfer
                receiveFileData(Data(), transfer: transfer)
                return
            }

            transfer.requestedRange = true
            fileTransfer = transfer
            guard let currentFile = transfer.currentFile else {
                failFileTransfer(transfer, message: "Remote file transfer failed.")
                return
            }
            try session.requestRemoteFileRange(
                streamID: transfer.streamID,
                fileIndex: currentFile.fileIndex,
                position: 0,
                requestedByteCount: requestedByteCount
            )
        } catch {
            failFileTransfer(transfer, message: "Remote file size request failed.")
        }
    }

    private func publishPasteboardIfChanged(force: Bool = false) {
        let pasteboard = NSPasteboard.general
        guard isSharingEnabled, let session else {
            pasteboardChangeCount = pasteboard.changeCount
            return
        }

        let nextChangeCount = pasteboard.changeCount
        guard force || nextChangeCount != pasteboardChangeCount else {
            return
        }

        pasteboardChangeCount = nextChangeCount
        switch localPayload(from: pasteboard) {
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

    private func localPayload(from pasteboard: NSPasteboard) -> LocalPayload {
        let fileURLs = pasteboardFileURLs(from: pasteboard)
        if fileURLs.isEmpty == false {
            return localFiles(from: fileURLs)
        }
        if let text = pasteboard.string(forType: .string) {
            guard RDPClipboardLimits.canPublishUnicodeText(text) else {
                return .ignored("Local text is too large to sync.")
            }
            return .text(text)
        }
        return .empty
    }

    private func pasteboardFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            appendFileURL(item.string(forType: .fileURL), to: &urls)
        }
        if urls.isEmpty, pasteboard.types?.contains(.fileURL) == true {
            appendFileURL(pasteboard.string(forType: .fileURL), to: &urls)
        }
        return urls
    }

    private func appendFileURL(_ value: String?, to urls: inout [URL]) {
        guard let value,
              let url = URL(string: value),
              url.isFileURL,
              urls.contains(url) == false
        else {
            return
        }
        urls.append(url)
    }

    private func localFiles(from urls: [URL]) -> LocalPayload {
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

    private func receiveFileData(_ data: Data, transfer: RemoteFileTransfer) {
        guard let currentFile = transfer.currentFile,
              transfer.expectedByteCount == UInt64(data.count),
              data.count <= maximumClipboardFileBytes
        else {
            failFileTransfer(transfer, message: "Remote file transfer was incomplete.")
            return
        }

        do {
            var nextTransfer = transfer
            let fileURL = transfer.downloadDirectory.appendingPathComponent(currentFile.fileName, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
            nextTransfer.downloadedFileURLs.append(fileURL)

            guard nextTransfer.currentFileOffset + 1 < nextTransfer.files.count else {
                finishFileTransfer(nextTransfer)
                return
            }

            nextTransfer.currentFileOffset += 1
            nextTransfer.streamID = makeStreamID()
            nextTransfer.expectedByteCount = nil
            nextTransfer.requestedRange = false
            requestFileSize(nextTransfer)
        } catch {
            failFileTransfer(transfer, message: "Remote file could not be saved.")
        }
    }

    private func requestFileSize(_ transfer: RemoteFileTransfer) {
        guard let session,
              let currentFile = transfer.currentFile
        else {
            failFileTransfer(transfer, message: "Clipboard is not ready.")
            return
        }

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
        let pasteboard = NSPasteboard.general
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

    /// Replaces the previous download directory; files from the last completed transfer stay on
    /// the pasteboard until the next transfer starts.
    private func makeDownloadDirectory() throws -> URL {
        let fileManager = FileManager.default
        if let downloadDirectory {
            try? fileManager.removeItem(at: downloadDirectory)
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RDPClientRemoteClipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        downloadDirectory = directory
        return directory
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

private enum LocalPayload: Equatable {
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
    var expectedByteCount: UInt64?
    var requestedRange = false
    var totalExpectedByteCount: UInt64 = 0
    var downloadedFileURLs: [URL] = []
    var downloadDirectory: URL

    init(files: [RDPClipboardRemoteFileTransferFile], streamID: UInt32, downloadDirectory: URL) {
        self.files = files
        self.streamID = streamID
        self.downloadDirectory = downloadDirectory
    }

    var currentFile: RDPClipboardRemoteFileTransferFile? {
        files.indices.contains(currentFileOffset) ? files[currentFileOffset] : nil
    }
}
