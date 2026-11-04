import AppKit
import RDPKit
import RDPKitAppKit

/// Age at which a download folder an earlier run left is removed at launch. A newer one
/// may belong to another copy of the app that is still downloading.
private let staleDownloadDirectoryAge: TimeInterval = 60 * 60

/// The session window's clipboard: RDPKitAppKit's `RDPPasteboardClipboard`, which bridges the
/// pasteboard and the session's clipboard channel, and the status line its events leave.
@MainActor
final class RDPRemoteSessionClipboard {
    let bridge: RDPPasteboardClipboard
    private var message: String?

    init(isSharingEnabled: Bool, pasteboard: NSPasteboard = .general, downloadRoot: URL = downloadsDirectory) {
        bridge = RDPPasteboardClipboard(
            isSharingEnabled: isSharingEnabled,
            pasteboard: pasteboard,
            downloadRoot: downloadRoot,
            quarantineAgentName: "RDPClient"
        )
        let limits = bridge.downloadLimits
        let maximumLocalFileByteCount = bridge.maximumLocalFileByteCount
        bridge.onEvent = { [weak self] event in
            self?.message = Self.message(
                for: event,
                limits: limits,
                maximumLocalFileByteCount: maximumLocalFileByteCount
            )
        }
    }

    var session: (any RDPPasteboardClipboardSession)? {
        bridge.session
    }

    var isSharingEnabled: Bool {
        bridge.isSharingEnabled
    }

    var canSync: Bool {
        bridge.canSync
    }

    var canStartTemporarySharing: Bool {
        bridge.canStartTemporarySharing
    }

    var statusMessage: String {
        guard bridge.isSharingEnabled else {
            return "Disabled."
        }
        return message ?? (bridge.session == nil ? "Not ready." : "Ready.")
    }

    var temporarySharingButtonTitle: String {
        bridge.temporarySharingSecondsRemaining.map { "Sharing \($0)s" }
            ?? "Share for \(Int(bridge.temporarySharingDuration))s"
    }

    func attach(_ session: any RDPPasteboardClipboardSession) {
        message = nil
        bridge.attach(session)
    }

    func detach() {
        message = nil
        bridge.detach()
    }

    func setSharingEnabled(_ enabled: Bool) {
        message = nil
        bridge.setSharingEnabled(enabled)
    }

    func syncNow() {
        bridge.syncNow()
    }

    func startTemporarySharing() {
        guard bridge.canStartTemporarySharing else {
            if bridge.session == nil {
                message = "Not ready."
            }
            return
        }
        bridge.startTemporarySharing()
    }

    /// Called once a second.
    func poll() {
        bridge.poll()
    }

    func receiveText(_ text: String, copyNumber: Int) {
        bridge.receiveText(text, copyNumber: copyNumber)
    }

    func receiveRemoteCopyUnavailable(isEmpty: Bool, copyNumber: Int) {
        bridge.receiveRemoteCopyUnavailable(isEmpty: isEmpty, copyNumber: copyNumber)
    }

    func receiveFileList(_ descriptorList: RDPClipboardFileGroupDescriptorW, copyNumber: Int) {
        bridge.receiveFileList(descriptorList, copyNumber: copyNumber)
    }

    /// The status line for `event`, of a bridge with `limits` and `maximumLocalFileByteCount`.
    static func message(
        for event: RDPPasteboardClipboard.Event,
        limits: RDPClipboardDownloadLimits = RDPClipboardDownloadLimits(),
        maximumLocalFileByteCount: Int = .max
    ) -> String {
        switch event {
        case .localTextShared:
            "Local text synced."
        case .localClipboardEmpty:
            "Local clipboard has no text."
        case .localTextTooLarge:
            "Local text is too large to sync; remote clipboard cleared."
        case let .localFilesShared(count):
            count == 1 ? "Local file synced." : "\(count) local files synced."
        case let .localFilesNotShared(error):
            switch error {
            case .notARegularFile:
                "Local clipboard has non-file items; remote clipboard cleared."
            case .invalidFileName:
                "Local file clipboard was not shared."
            case .unreadable:
                "Local file clipboard could not be read; remote clipboard cleared."
            case .totalByteLimitExceeded:
                "Local clipboard files exceed \(mebibytes(maximumLocalFileByteCount)) MiB; remote clipboard cleared."
            case .fileTooLarge:
                "Local file is larger than the remote computer takes; remote clipboard cleared."
            case .filesNotSupported:
                "The remote computer takes no files; remote clipboard cleared."
            }
        case .pasteboardAccessDenied:
            "Clipboard access is off for RDPClient in System Settings."
        case .upToDate:
            "Clipboard is up to date."
        case .remoteTextCopied:
            "Remote text copied."
        case .remoteCopyUnavailable:
            "No text or files arrived from the remote copy."
        case let .remoteClipboardEmptied(clearedHere):
            clearedHere ? "Remote clipboard emptied; cleared here too." : "Remote clipboard emptied."
        case let .remoteFilesRefused(error):
            switch error {
            case .emptyFileList:
                "Remote file clipboard is empty."
            case .containsOnlyDirectories:
                "Remote clipboard has folders; file copy is not ready."
            case .invalidFileIndex:
                "Remote file index is not valid."
            case .totalByteLimitExceeded:
                "Remote files exceed \(mebibytes(limits.maximumTotalByteCount)) MiB."
            case .fileCountLimitExceeded:
                "Remote clipboard has more than \(limits.maximumFileCount) files."
            }
        case let .downloadProgress(progress):
            progress.fileCount == 1
                ? "Downloading remote file: \(progress.fileName)."
                : "Downloading remote files: \(progress.fileOffset + 1) of \(progress.fileCount)."
        case let .remoteFilesCopied(download):
            if download.fileURLs.count == 1, let fileURL = download.fileURLs.first {
                "Remote file copied: \(fileURL.lastPathComponent)."
            } else {
                "\(download.fileURLs.count) remote files copied."
            }
        case let .downloadFailed(failure):
            switch failure {
            case .timedOut:
                "Remote file transfer timed out."
            case .refused:
                "Remote file transfer failed."
            case .incomplete:
                "Remote file transfer was incomplete."
            case .totalByteLimitExceeded:
                "Remote files exceed \(mebibytes(limits.maximumTotalByteCount)) MiB."
            case .folderNotCreated:
                "Remote files could not be prepared."
            case .notSaved:
                "Remote file could not be saved."
            case .clipboardChanged:
                "Clipboard changed; remote files were not copied."
            case .pasteboardRefused:
                "Remote files could not be copied."
            }
        case .temporarySharingStarted:
            "Temporary sharing enabled."
        case .temporarySharingEnded:
            "Temporary sharing ended."
        }
    }

    private static func mebibytes(_ byteCount: UInt64) -> UInt64 {
        byteCount / (1024 * 1024)
    }

    private static func mebibytes(_ byteCount: Int) -> Int {
        byteCount / (1024 * 1024)
    }

    /// Holds one folder, named by a UUID, per remote file transfer.
    nonisolated static let downloadsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RDPClientRemoteClipboard", isDirectory: true)

    /// Removes, off the main thread, download folders earlier runs left behind whose files
    /// are not on the pasteboard.
    static func removeStaleDownloadDirectories(pasteboard: NSPasteboard = .general) {
        let keptDirectoryPaths = RDPPasteboardClipboard.fileDirectoryPaths(on: pasteboard)
        let cutoff = Date().addingTimeInterval(-staleDownloadDirectoryAge)
        Task.detached(priority: .utility) {
            RDPPasteboardClipboard.removeStaleDownloadDirectories(
                in: downloadsDirectory,
                changedBefore: cutoff,
                keeping: keptDirectoryPaths
            )
        }
    }
}
