import Foundation
import NIOCore

/// What ``RDPClipboardSession/downloadRemoteFiles(_:copyNumber:into:progress:finishFile:)``
/// takes on at most.
public struct RDPClipboardDownloadLimits: Equatable, Sendable {
    /// The files' bytes together, as their size answers say; no limit by default, as each range
    /// goes to disk as it comes.
    public var maximumTotalByteCount: UInt64
    /// Each file costs a round trip and a write, and all of them are pasted side by side.
    public var maximumFileCount: Int
    /// The most the first range request of a session asks for, and the least any does; servers
    /// may send less, and the rest is asked for again. Half a MiB arrives within the default
    /// timeout down to about 4 KB/s.
    public var rangeByteCount: UInt32
    /// The most a range request asks for once answers come quickly: a range answered in full
    /// within a second doubles the next, up to this, and one that takes over 4 seconds halves
    /// it, down to `rangeByteCount`. The session keeps the size for its next download. Each
    /// range is held in memory until it is written. Windows 11 and GNOME Remote Desktop 51
    /// answer 8 MiB ranges in full.
    public var maximumRangeByteCount: UInt32
    /// How long a request may go unanswered: long enough for a range on a slow link, or for a
    /// server that fetches a cloud file first.
    public var requestTimeout: TimeInterval

    public init(
        maximumTotalByteCount: UInt64 = .max,
        maximumFileCount: Int = 1_000,
        rangeByteCount: UInt32 = 512 * 1_024,
        requestTimeout: TimeInterval = 120,
        maximumRangeByteCount: UInt32 = 8 * 1_024 * 1_024
    ) {
        self.maximumTotalByteCount = maximumTotalByteCount
        self.maximumFileCount = maximumFileCount
        self.rangeByteCount = max(1, rangeByteCount)
        self.requestTimeout = requestTimeout
        self.maximumRangeByteCount = maximumRangeByteCount
    }

    /// The range sizes a download asks for: from `rangeByteCount` to `maximumRangeByteCount`,
    /// which a channel message must hold.
    var rangeByteCounts: ClosedRange<UInt32> {
        let lowerBound = max(1, rangeByteCount)
        let ceiling = UInt32(RDPClipboardLimits.maximumFormatDataByteCount - 4)
        return min(lowerBound, ceiling) ... min(max(lowerBound, maximumRangeByteCount), ceiling)
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
/// ``RDPClipboardSession/downloadRemoteFiles(_:copyNumber:into:progress:finishFile:)`` follows it.
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
    /// A range answered in full within this grows the next.
    static let fastRangeAnswerDuration = TimeAmount.seconds(1)
    /// A range answered after this shrinks the next.
    static let slowRangeAnswerDuration = TimeAmount.seconds(4)

    /// Downloads the files `plan` holds into `directory`, which must exist, one after another:
    /// asks for each file's size, then for its bytes a range at a time, asking again for the
    /// rest of a range the server answers short ([MS-RDPECLIP] 2.2.5.3, 2.2.5.4), and writes
    /// each range as it comes to a hidden file in `directory`, which takes the name the plan
    /// gives the file once it is whole. No file is held in memory: one range is. The ranges
    /// grow while the server answers them quickly, as ``RDPClipboardDownloadLimits`` describes.
    /// `finishFile` gets each file's URL once it has its name, before the next file starts,
    /// for the application to set a quarantine mark or place folders. The download awaits
    /// `progress` for each report, so the reports arrive in order, and the last before the
    /// download returns, also when `progress` hops to another actor, such as the main one.
    ///
    /// `copyNumber` is the one the `onClipboardFileGroupDescriptor` handler got with the list.
    /// A newer copy, the server's or a publish, or turning
    /// ``fetchesRemoteCopies`` off ends the download with ``RDPClipboardDownloadError/replaced``
    /// while a request waits or before the next, also before the first; one after the last
    /// answer does not, so the application checks, once the download returns, that the copy is
    /// still the one to paste, as it would for any copy it handles on another thread. The
    /// connection closing ends it with ``RDPClipboardDownloadError/sessionEnded``, and
    /// cancelling the task with `CancellationError`, also before a file takes its name. A
    /// `finishFile` call under way when the task is cancelled still finishes, but the download
    /// returns only after it has and starts no other: an application that removes what a
    /// cancelled download wrote does so once the download has returned, not as it cancels.
    /// The answers to its requests do not reach `onClipboardFileContents`.
    /// An error writing a file, or one `finishFile` throws, ends the download too. The file
    /// being downloaded when it ends is removed; files that had their names stay in `directory`.
    public func downloadRemoteFiles(
        _ plan: RDPClipboardDownloadPlan,
        copyNumber: Int,
        into directory: URL,
        progress: (@Sendable (RDPClipboardDownloadProgress) async -> Void)? = nil,
        finishFile: @Sendable (URL) throws -> Void = { _ in }
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

            let fileURL = directory.appendingPathComponent(file.fileName, isDirectory: false)
            let partialFile = try RDPClipboardPartialDownload(in: directory)
            do {
                while report.receivedByteCount < byteCount {
                    let rangeByteCount = downloadRangeByteCount(within: limits.rangeByteCounts)
                    let requestedByteCount = UInt32(min(UInt64(rangeByteCount), byteCount - report.receivedByteCount))
                    // The event loop's clock, which times the request out too.
                    let requestedAt = eventLoopNow
                    let rangeAnswer = try await fileContents(
                        of: .range(
                            streamID: streamID,
                            fileIndex: file.fileIndex,
                            position: report.receivedByteCount,
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
                    adaptDownloadRangeByteCount(
                        rangeByteCount,
                        within: limits.rangeByteCounts,
                        answeredInFull: requestedByteCount == rangeByteCount && rangeAnswer.data.count == Int(rangeByteCount),
                        after: eventLoopNow - requestedAt
                    )
                    try partialFile.append(rangeAnswer.data)
                    report.receivedByteCount += UInt64(rangeAnswer.data.count)
                    await progress?(report)
                }
                try Task.checkCancellation()
                try partialFile.finish(at: fileURL)
            } catch {
                partialFile.discard()
                throw error
            }
            try finishFile(fileURL)
            fileURLs.append(fileURL)
        }
        try Task.checkCancellation()
        return RDPClipboardDownload(fileURLs: fileURLs, leavesOutFolders: plan.leavesOutFolders)
    }
}

/// A file a download writes, under a hidden name in the download's folder until it is whole.
final class RDPClipboardPartialDownload {
    private let url: URL
    private let fileHandle: FileHandle
    private var isClosed = false

    init(in directory: URL) throws {
        url = directory.appendingPathComponent(".\(UUID().uuidString).download", isDirectory: false)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ data: Data) throws {
        try fileHandle.write(contentsOf: data)
    }

    /// Closes the file and gives it `fileURL`'s name, in place of any file there.
    func finish(at fileURL: URL) throws {
        isClosed = true
        try fileHandle.close()
        guard rename(url.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Removes the file, unless it has its name.
    func discard() {
        if !isClosed {
            try? fileHandle.close()
        }
        unlink(url.path)
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
