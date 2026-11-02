import Foundation

/// What ``RDPClipboardSession/downloadRemoteFiles(_:copyNumber:into:progress:writeFile:)``
/// takes on at most.
public struct RDPClipboardDownloadLimits: Equatable, Sendable {
    /// The files' bytes together, as their size answers say.
    public var maximumTotalByteCount: UInt64
    /// Each file costs a round trip and a write, and all of them are pasted side by side.
    public var maximumFileCount: Int
    /// The most one range request asks for; servers may send less, and the rest is asked for
    /// again. Half a MiB arrives within the default timeout down to about 4 KB/s, and costs a
    /// round trip per range: 64 for 32 MiB.
    public var rangeByteCount: UInt32
    /// How long a request may go unanswered: long enough for a range on a slow link, or for a
    /// server that fetches a cloud file first.
    public var requestTimeout: TimeInterval

    public init(
        maximumTotalByteCount: UInt64 = 32 * 1_024 * 1_024,
        maximumFileCount: Int = 1_000,
        rangeByteCount: UInt32 = 512 * 1_024,
        requestTimeout: TimeInterval = 120
    ) {
        self.maximumTotalByteCount = maximumTotalByteCount
        self.maximumFileCount = maximumFileCount
        self.rangeByteCount = max(1, rangeByteCount)
        self.requestTimeout = requestTimeout
    }
}

/// How far a download has come: the file being fetched, the `fileOffset`th of `fileCount`, and
/// how much of it has arrived, of `fileByteCount` once the server has said its size. A download
/// reports each file as it starts, once the server has said its size, and as each range
/// arrives.
public struct RDPClipboardDownloadProgress: Equatable, Sendable {
    public var fileOffset: Int
    public var fileCount: Int
    public var fileName: String
    public var receivedByteCount: UInt64
    public var fileByteCount: UInt64?

    public init(fileOffset: Int, fileCount: Int, fileName: String, receivedByteCount: UInt64, fileByteCount: UInt64?) {
        self.fileOffset = fileOffset
        self.fileCount = fileCount
        self.fileName = fileName
        self.receivedByteCount = receivedByteCount
        self.fileByteCount = fileByteCount
    }
}

/// A download of a remote copy's files, planned before it starts, so an application can refuse
/// the copy or show its first file before it makes a folder for it:
/// ``RDPClipboardFileGroupDescriptorW/downloadPlan(limits:)`` makes one, and
/// ``RDPClipboardSession/downloadRemoteFiles(_:copyNumber:into:progress:writeFile:)`` follows it.
public struct RDPClipboardDownloadPlan: Equatable, Sendable {
    /// The files to download, folders left out, in the list's order, each under a name unique
    /// in the download that the Mac accepts.
    public let files: [RDPClipboardRemoteFileTransferFile]
    /// Whether the list had folders, which the download leaves out: entries for folders, or
    /// file names that carry their own, such as `Docs\a.txt`, written as their last component.
    public let leavesOutFolders: Bool
    /// The files' sizes as the list declares them, together; a file that declares none counts
    /// as 0. The download checks the sizes the server answers against the limit as it goes.
    public let declaredByteCount: UInt64
    public let limits: RDPClipboardDownloadLimits
}

extension RDPClipboardFileGroupDescriptorW {
    /// Plans the download of the list's files within `limits`. Throws an
    /// ``RDPClipboardRemoteFileTransferPlanningError`` when the list holds no file, more files
    /// than ``RDPClipboardDownloadLimits/maximumFileCount``, or declares sizes past
    /// ``RDPClipboardDownloadLimits/maximumTotalByteCount``.
    public func downloadPlan(limits: RDPClipboardDownloadLimits = RDPClipboardDownloadLimits()) throws -> RDPClipboardDownloadPlan {
        let files = try remoteFileTransferFiles(
            maximumTotalByteCount: limits.maximumTotalByteCount,
            maximumFileCount: limits.maximumFileCount
        )
        let namesFolders = descriptors.contains {
            $0.isDirectory || $0.fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).count > 1
        }
        return RDPClipboardDownloadPlan(
            files: files,
            leavesOutFolders: namesFolders,
            declaredByteCount: files.reduce(0) { $0 + ($1.declaredByteCount ?? 0) },
            limits: limits
        )
    }
}

/// The files a download wrote, in the list's order, and whether the list had folders, which
/// it leaves out.
public struct RDPClipboardDownload: Equatable, Sendable {
    public var fileURLs: [URL]
    public var leavesOutFolders: Bool

    public init(fileURLs: [URL], leavesOutFolders: Bool) {
        self.fileURLs = fileURLs
        self.leavesOutFolders = leavesOutFolders
    }
}

public enum RDPClipboardDownloadError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A newer copy, the server's or a publish, replaced the one being downloaded, or fetching
    /// was turned off.
    case replaced
    /// The connection closed.
    case sessionEnded
    /// The server left a request unanswered for ``RDPClipboardDownloadLimits/requestTimeout``.
    case timedOut
    /// The server answered a request with a failure.
    case refused
    /// The server answered with no bytes before a file's end, more than asked for, or a size
    /// that does not parse.
    case incomplete
    /// A file's size, as the server answered it, takes the download past
    /// ``RDPClipboardDownloadLimits/maximumTotalByteCount``.
    case totalByteLimitExceeded

    public var description: String {
        switch self {
        case .replaced:
            "A newer copy replaced the remote files."
        case .sessionEnded:
            "The connection closed during the download."
        case .timedOut:
            "The server did not answer a file request in time."
        case .refused:
            "The server refused a file request."
        case .incomplete:
            "The server sent an incomplete file."
        case .totalByteLimitExceeded:
            "Remote files exceed the configured byte limit."
        }
    }
}

extension RDPClipboardSession {
    /// Downloads the files `plan` holds into `directory`, which must exist, one after another:
    /// asks for each file's size, then for its bytes in ranges of
    /// ``RDPClipboardDownloadLimits/rangeByteCount``, asking again for the rest of a range the
    /// server answers short ([MS-RDPECLIP] 2.2.5.3, 2.2.5.4), and hands each file to
    /// `writeFile` with its URL in `directory`, under the name the plan gives it. The default
    /// writes it atomically; an application passes its own to set a quarantine mark or place
    /// folders. The download awaits `progress` for each report, so the reports arrive in order,
    /// and the last before the download returns, also when `progress` hops to another actor,
    /// such as the main one.
    ///
    /// `copyNumber` is the one the `onClipboardFileGroupDescriptor` handler got with the list.
    /// A newer copy, the server's or a publish, or turning
    /// ``fetchesRemoteCopies`` off ends the download with ``RDPClipboardDownloadError/replaced``
    /// while a request waits or before the next, also before the first; one after the last
    /// answer does not, so the application checks, once the download returns, that the copy is
    /// still the one to paste, as it would for any copy it handles on another thread. The
    /// connection closing ends it with ``RDPClipboardDownloadError/sessionEnded``, and
    /// cancelling the task with `CancellationError`, also before a file is written: a cancelled
    /// download writes nothing more. The answers to its requests do not reach
    /// `onClipboardFileContents`.
    /// An error `writeFile` throws ends the download too. Files written before a failure stay
    /// in `directory`.
    public func downloadRemoteFiles(
        _ plan: RDPClipboardDownloadPlan,
        copyNumber: Int,
        into directory: URL,
        progress: (@Sendable (RDPClipboardDownloadProgress) async -> Void)? = nil,
        writeFile: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) async throws -> RDPClipboardDownload {
        let limits = plan.limits
        var fileURLs: [URL] = []
        var totalByteCount: UInt64 = 0
        for (offset, file) in plan.files.enumerated() {
            let streamID = nextDownloadStreamID()
            var report = RDPClipboardDownloadProgress(
                fileOffset: offset,
                fileCount: plan.files.count,
                fileName: file.fileName,
                receivedByteCount: 0,
                fileByteCount: nil
            )
            await progress?(report)
            let sizeAnswer = try await fileContents(
                of: .size(streamID: streamID, fileIndex: file.fileIndex),
                copyNumber: copyNumber,
                timeout: limits.requestTimeout
            )
            guard sizeAnswer.ok else {
                throw RDPClipboardDownloadError.refused
            }
            guard let byteCount = try? sizeAnswer.decodedFileSize() else {
                throw RDPClipboardDownloadError.incomplete
            }
            guard byteCount <= limits.maximumTotalByteCount,
                  totalByteCount <= limits.maximumTotalByteCount - byteCount
            else {
                throw RDPClipboardDownloadError.totalByteLimitExceeded
            }
            totalByteCount += byteCount
            report.fileByteCount = byteCount
            await progress?(report)

            var data = Data()
            while UInt64(data.count) < byteCount {
                let requestedByteCount = UInt32(min(UInt64(limits.rangeByteCount), byteCount - UInt64(data.count)))
                let rangeAnswer = try await fileContents(
                    of: .range(
                        streamID: streamID,
                        fileIndex: file.fileIndex,
                        position: UInt64(data.count),
                        requestedByteCount: requestedByteCount
                    ),
                    copyNumber: copyNumber,
                    timeout: limits.requestTimeout
                )
                guard rangeAnswer.ok else {
                    throw RDPClipboardDownloadError.refused
                }
                guard !rangeAnswer.data.isEmpty, rangeAnswer.data.count <= Int(requestedByteCount) else {
                    throw RDPClipboardDownloadError.incomplete
                }
                data.append(rangeAnswer.data)
                report.receivedByteCount = UInt64(data.count)
                await progress?(report)
            }
            let fileURL = directory.appendingPathComponent(file.fileName, isDirectory: false)
            try Task.checkCancellation()
            try writeFile(data, fileURL)
            fileURLs.append(fileURL)
        }
        try Task.checkCancellation()
        return RDPClipboardDownload(fileURLs: fileURLs, leavesOutFolders: plan.leavesOutFolders)
    }
}

/// One request's answer, handed over once: by the session's thread when it arrives, or as a
/// failure by a timeout, a newer copy, the connection closing or the task being cancelled,
/// whichever comes first, also before anything waits for it.
final class RDPClipboardFileContentsWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RDPClipboardFileContentsResponse, Error>?
    private var outcome: Result<RDPClipboardFileContentsResponse, Error>?

    func result() async throws -> RDPClipboardFileContentsResponse {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = lock.withLock {
                if self.outcome == nil {
                    self.continuation = continuation
                }
                return self.outcome
            }
            if let outcome {
                continuation.resume(with: outcome)
            }
        }
    }

    func finish(_ outcome: Result<RDPClipboardFileContentsResponse, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<RDPClipboardFileContentsResponse, Error>? in
            guard self.outcome == nil else {
                return nil
            }
            self.outcome = outcome
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: outcome)
    }
}
