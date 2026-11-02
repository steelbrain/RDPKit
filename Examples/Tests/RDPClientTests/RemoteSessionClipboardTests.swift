import AppKit
@testable import RDPClient
import RDPKit
import Testing

/// A download the bridge started, which the test finishes or fails.
private final class RecordedDownload: @unchecked Sendable {
    let copyNumber: Int
    let directory: URL
    let progress: (@Sendable (RDPClipboardDownloadProgress) -> Void)?
    /// The bridge's task that waits for it, once the test has looked it up.
    @MainActor var bridgeTask: Task<Void, Never>?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Data], Error>?
    private var outcome: Result<[Data], Error>?
    private var cancelled = false

    init(copyNumber: Int, directory: URL, progress: (@Sendable (RDPClipboardDownloadProgress) -> Void)?) {
        self.copyNumber = copyNumber
        self.directory = directory
        self.progress = progress
    }

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// The files' contents, once the test finishes the download.
    func contents() async throws -> [Data] {
        try await withTaskCancellationHandler {
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
        } onCancel: {
            lock.withLock { cancelled = true }
            resume(.failure(CancellationError()))
        }
    }

    func finish(with contents: [Data]) {
        resume(.success(contents))
    }

    func fail(_ error: Error) {
        resume(.failure(error))
    }

    private func resume(_ outcome: Result<[Data], Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<[Data], Error>? in
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

/// Used on the main actor, but for `downloadRemoteFiles`, which records under a lock.
private final class RecordedClipboard: RDPClipboardSending, @unchecked Sendable {
    /// Turned on, fetches `unfetchedRemoteCopy` as RDPClipboardSession does.
    var fetchesRemoteCopies = true {
        didSet {
            if fetchesRemoteCopies, !oldValue, unfetchedRemoteCopy {
                isAwaitingRemoteCopy = true
                unfetchedRemoteCopy = false
            }
        }
    }

    /// Whether the server announced a copy while fetching was off that no publish has replaced.
    var unfetchedRemoteCopy = false
    var isAwaitingRemoteCopy = false
    var publishedTexts: [String?] = []
    var publishedFiles: [[RDPClipboardLocalFile]] = []
    /// Copies, remote and published, are numbered in the order they come, as RDPClipboardSession
    /// numbers them.
    private var lastCopyNumber = 0
    private var publishedCopyNumber = 0

    /// Whether the server's clipboard holds the last publish, which was not empty.
    private(set) var serverHoldsLocalCopy = false

    /// A copy the server announces, and the number its handler gets. It replaces the local
    /// copy on the server.
    func announceRemoteCopy() -> Int {
        lastCopyNumber += 1
        serverHoldsLocalCopy = false
        return lastCopyNumber
    }

    func withdrawLocalCopy() -> Bool {
        guard serverHoldsLocalCopy else {
            return false
        }
        publishLocalUnicodeText(nil)
        return true
    }

    func hasPublished(since remoteCopyNumber: Int) -> Bool {
        publishedCopyNumber > remoteCopyNumber
    }

    func publishLocalUnicodeText(_ text: String?) {
        recordPublish()
        serverHoldsLocalCopy = text != nil
        publishedTexts.append(text)
    }

    func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        recordPublish()
        serverHoldsLocalCopy = !files.isEmpty
        publishedFiles.append(files)
    }

    private func recordPublish() {
        unfetchedRemoteCopy = false
        lastCopyNumber += 1
        publishedCopyNumber = lastCopyNumber
    }

    private let lock = NSLock()
    private var recordedDownloads: [RecordedDownload] = []

    var downloads: [RecordedDownload] {
        lock.withLock { recordedDownloads }
    }

    /// Writes the files with `writeFile`, as RDPClipboardSession does, once the test finishes
    /// the download with their contents.
    func downloadRemoteFiles(
        _ list: RDPClipboardFileGroupDescriptorW,
        copyNumber: Int,
        into directory: URL,
        limits: RDPClipboardDownloadLimits,
        progress: (@Sendable (RDPClipboardDownloadProgress) -> Void)?,
        writeFile: @Sendable (Data, URL) throws -> Void
    ) async throws -> RDPClipboardDownload {
        let download = RecordedDownload(copyNumber: copyNumber, directory: directory, progress: progress)
        lock.withLock { recordedDownloads.append(download) }
        let contents = try await download.contents()
        let files = try list.remoteFileTransferFiles(
            maximumTotalByteCount: limits.maximumTotalByteCount,
            maximumFileCount: limits.maximumFileCount
        )
        var fileURLs: [URL] = []
        for (file, data) in zip(files, contents) {
            let fileURL = directory.appendingPathComponent(file.fileName, isDirectory: false)
            try writeFile(data, fileURL)
            fileURLs.append(fileURL)
        }
        return RDPClipboardDownload(fileURLs: fileURLs, leavesOutFolders: list.descriptors.contains(where: \.isDirectory))
    }
}

/// A pasteboard of the test's own, so tests never read or replace the user's clipboard.
@MainActor
private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("RDPClientTests.\(UUID().uuidString)"))
}

@MainActor
@Test func aTemporaryShareEndsOnlySharingItTurnedOn() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(RecordedClipboard())
    #expect(clipboard.canStartTemporarySharing == false)
    clipboard.startTemporarySharing()
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(clipboard.isSharingEnabled)

    clipboard.setSharingEnabled(false)
    #expect(clipboard.canStartTemporarySharing)
    clipboard.startTemporarySharing()
    #expect(clipboard.isSharingEnabled)
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(clipboard.isSharingEnabled == false)

    // Turning sharing on during a temporary share keeps it on.
    clipboard.startTemporarySharing()
    clipboard.setSharingEnabled(true)
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(clipboard.isSharingEnabled)
}

/// A session that starts with sharing off still has the clipboard channel, so sharing can be
/// turned on mid-session; until then nothing crosses either way.
@MainActor
@Test func sharingTurnedOnMidSessionStartsSharing() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: false, pasteboard: pasteboard)
    clipboard.attach(session)
    #expect(session.fetchesRemoteCopies == false)
    #expect(clipboard.statusMessage == "Disabled.")
    #expect(clipboard.canStartTemporarySharing)

    pasteboard.clearContents()
    pasteboard.setString("local", forType: .string)
    session.unfetchedRemoteCopy = true
    clipboard.poll()
    clipboard.receiveText("remote", copyNumber: session.announceRemoteCopy())
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: "remote.txt"),
    ]), copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == "local")
    #expect(session.publishedTexts == [nil])
    #expect(session.publishedFiles.isEmpty)
    #expect(clipboard.fileDownloadTask == nil)

    // The pasteboard replaces the copy the server announced while sharing was off.
    clipboard.setSharingEnabled(true)
    #expect(session.fetchesRemoteCopies)
    #expect(session.isAwaitingRemoteCopy == false)
    #expect(session.publishedTexts == [nil, "local"])
    #expect(clipboard.statusMessage == "Local text synced.")
    #expect(clipboard.canSync)
    #expect(clipboard.canStartTemporarySharing == false)

    clipboard.setSharingEnabled(false)
    clipboard.startTemporarySharing()
    #expect(session.fetchesRemoteCopies)
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(session.fetchesRemoteCopies == false)
    #expect(session.publishedTexts.last == .some(nil))
}

/// Ending sharing takes back only a copy of this Mac's. A copy the server's user made since is
/// theirs, and Windows empties its clipboard for an empty Format List, so it is left alone.
@MainActor
@Test func endingSharingLeavesTheServersOwnCopy() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: false, pasteboard: pasteboard)
    clipboard.attach(session)
    pasteboard.clearContents()
    pasteboard.setString("local", forType: .string)

    // Copied on the server 25 s into a temporary share.
    clipboard.startTemporarySharing()
    clipboard.receiveText("remote", copyNumber: session.announceRemoteCopy())
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(clipboard.isSharingEnabled == false)
    #expect(session.publishedTexts == [nil, "local"])

    // Files, and a copy of nothing this bridge takes, are the server's own too.
    clipboard.startTemporarySharing()
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: "remote.txt"),
    ]), copyNumber: session.announceRemoteCopy())
    clipboard.setSharingEnabled(false)
    clipboard.startTemporarySharing()
    clipboard.receiveRemoteCopyUnavailable(isEmpty: false, copyNumber: session.announceRemoteCopy())
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(session.publishedTexts == [nil, "local", "remote", "remote"])

    // The Mac's copy is taken back, once.
    clipboard.startTemporarySharing()
    clipboard.setSharingEnabled(false)
    clipboard.setSharingEnabled(false)
    #expect(session.publishedTexts == [nil, "local", "remote", "remote", "remote", nil])
    // An empty pasteboard sent leaves nothing to take back.
    pasteboard.clearContents()
    clipboard.startTemporarySharing()
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(session.publishedTexts == [nil, "local", "remote", "remote", "remote", nil, nil])
}

/// The session turns fetching off until the bridge attaches on the main thread. The server's
/// first copy, announced in between, reaches the pasteboard, and the pasteboard the Mac had
/// does not replace it on the server.
@MainActor
@Test func theServersFirstCopyReachesThePasteboardWhenItComesBeforeTheBridgeAttaches() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("local", forType: .string)
    let session = RecordedClipboard()
    session.fetchesRemoteCopies = false
    session.unfetchedRemoteCopy = true
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)

    clipboard.attach(session)
    #expect(session.isAwaitingRemoteCopy)
    #expect(session.publishedTexts.isEmpty)
    #expect(clipboard.statusMessage == "Ready.")

    clipboard.receiveText("remote", copyNumber: session.announceRemoteCopy())
    clipboard.poll()
    #expect(pasteboard.string(forType: .string) == "remote")
    #expect(session.publishedTexts.isEmpty)
}

/// Should the server's first copy never arrive, Sync Now sends the pasteboard instead.
@MainActor
@Test func syncNowSendsThePasteboardWhenTheServersFirstCopyNeverArrives() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("local", forType: .string)
    let session = RecordedClipboard()
    session.fetchesRemoteCopies = false
    session.unfetchedRemoteCopy = true
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)

    clipboard.attach(session)
    clipboard.poll()
    #expect(session.publishedTexts.isEmpty)
    clipboard.syncNow()
    #expect(session.publishedTexts == ["local"])
}

/// A remote copy can reach the main thread after the bridge published there, though the server
/// announced it before: that publish replaced it on the server, so it is dropped. Here the
/// server's clipboard, emptied before the bridge attached, is reported once attaching turns
/// fetching on, and ending sharing still takes back the Mac's copy. A remote copy announced
/// after the publish is newer and arrives.
@MainActor
@Test func aRemoteCopyAPublishReplacedOnTheWayIsDropped() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("local", forType: .string)
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)

    let emptied = session.announceRemoteCopy()
    clipboard.attach(session)
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: emptied)
    #expect(clipboard.statusMessage == "Local text synced.")

    let remoteText = session.announceRemoteCopy()
    let remoteFiles = session.announceRemoteCopy()
    pasteboard.clearContents()
    pasteboard.setString("newer local", forType: .string)
    clipboard.poll()
    clipboard.receiveText("older remote", copyNumber: remoteText)
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: "remote.txt"),
    ]), copyNumber: remoteFiles)
    #expect(pasteboard.string(forType: .string) == "newer local")
    #expect(clipboard.fileDownloadTask == nil)
    clipboard.setSharingEnabled(false)
    #expect(session.publishedTexts == ["local", "newer local", nil])

    clipboard.setSharingEnabled(true)
    clipboard.receiveText("newer remote", copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == "newer remote")
}

/// Copies `contents` to the pasteboard as a file in `directory`.
@MainActor
private func copyFile(_ contents: Data, in directory: URL, to pasteboard: NSPasteboard) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("notes.txt")
    try contents.write(to: fileURL)
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])
}

/// Text too large to send replaces the server's copy with an empty clipboard, as files too
/// large do. So with it on the pasteboard, turning sharing back on neither fetches the copy the
/// server announced while sharing was off, nor applies one handed over before sharing went off
/// that reaches the main thread late.
@MainActor
@Test func textTooLargeToSendEmptiesTheServersClipboard() {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let largeText = String(repeating: "a", count: RDPClipboardLimits.maximumUnicodeTextUTF16CodeUnitCount + 1)

    let olderRemoteText = session.announceRemoteCopy()
    pasteboard.clearContents()
    pasteboard.setString(largeText, forType: .string)
    clipboard.setSharingEnabled(false)
    session.unfetchedRemoteCopy = true
    clipboard.setSharingEnabled(true)
    #expect(session.isAwaitingRemoteCopy == false)
    clipboard.receiveText("older remote", copyNumber: olderRemoteText)
    #expect(pasteboard.string(forType: .string)?.utf16.count == largeText.utf16.count)
    #expect(session.publishedTexts == [nil, nil])
    #expect(clipboard.statusMessage == "Local text is too large to sync; remote clipboard cleared.")
}

/// Turning sharing on sends copied files as it sends text, though they take a while to read:
/// the copy the server announced while sharing was off is not fetched in their place.
@MainActor
@Test func sharingTurnedOnMidSessionSendsCopiedFiles() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try copyFile(Data("local".utf8), in: directory, to: pasteboard)
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: false, pasteboard: pasteboard)
    clipboard.attach(session)
    session.unfetchedRemoteCopy = true

    clipboard.setSharingEnabled(true)
    #expect(session.fetchesRemoteCopies)
    #expect(session.isAwaitingRemoteCopy == false)
    try await waitUntil { session.publishedFiles.isEmpty == false }
    #expect(session.publishedFiles.map { $0.map(\.contents) } == [[Data("local".utf8)]])
}

/// The server's clipboard, emptied before the bridge attached, is reported once attaching turns
/// fetching on, and can reach the main thread while the pasteboard's files are being read. The
/// files are the newer copy, so they still go.
@MainActor
@Test func copiedFilesGoThoughAnOlderRemoteCopyArrivesDuringTheirRead() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try copyFile(Data("local".utf8), in: directory, to: pasteboard)
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)

    let emptied = session.announceRemoteCopy()
    clipboard.attach(session)
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: emptied)
    try await waitUntil { session.publishedFiles.isEmpty == false }
    #expect(session.publishedFiles.map { $0.map(\.contents) } == [[Data("local".utf8)]])
}

@MainActor
@Test func copiedLocalFilesAreReadOffTheMainThread() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: fileURL)
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])

    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    #expect(session.publishedFiles.isEmpty)

    for _ in 0 ..< 200 where session.publishedFiles.isEmpty {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(session.publishedFiles.map { $0.map(\.contents) } == [[Data("hello".utf8)]])

    // A newer copy wins over a file read still in flight.
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])
    clipboard.syncNow()
    pasteboard.clearContents()
    pasteboard.setString("newer", forType: .string)
    clipboard.syncNow()
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(session.publishedFiles.count == 1)
    #expect(session.publishedTexts.last == "newer")
}

/// RDPKit sends "\" as a folder separator, so "a\b.txt" would paste on Windows as "b.txt"
/// in a folder "a".
@MainActor
@Test func aBackslashInACopiedFileNameIsNotAFolder() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("a\\b.txt")
    try Data("hello".utf8).write(to: fileURL)
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])

    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    for _ in 0 ..< 200 where session.publishedFiles.isEmpty {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(session.publishedFiles.map { $0.map(\.descriptor.fileName) } == [["a_b.txt"]])
}

/// Offers one remote file of `contents`, named big.bin, and waits until the bridge has
/// started downloading it.
@MainActor
private func startRemoteFileDownload(
    _ contents: Data,
    to clipboard: RDPRemoteSessionClipboard,
    from session: RecordedClipboard
) async throws {
    let copyNumber = session.announceRemoteCopy()
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: UInt64(contents.count), fileName: "big.bin"),
    ]), copyNumber: copyNumber)
    let task = try #require(clipboard.fileDownloadTask)
    try await waitUntil { session.downloads.last?.copyNumber == copyNumber }
    let download = try #require(session.downloads.last)
    #expect(download.copyNumber == copyNumber)
    download.bridgeTask = task
}

/// Finishes the last download with `contents`, and waits until the bridge has handled it.
@MainActor
private func finishRemoteFileDownload(with contents: Data, from session: RecordedClipboard) async throws {
    let download = try #require(session.downloads.last)
    download.finish(with: [contents])
    await download.bridgeTask?.value
}

/// Fails the last download with `error`, and waits until the bridge has handled it.
@MainActor
private func failRemoteFileDownload(with error: Error, from session: RecordedClipboard) async throws {
    let download = try #require(session.downloads.last)
    download.fail(error)
    await download.bridgeTask?.value
}

/// Each way a download fails says why, but one a newer copy or the session's end replaced,
/// which says so itself. Either way, its folder goes.
@MainActor
@Test func aFailedDownloadSaysWhy() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    struct DiskFull: Error {}
    let failures: [(Error, String)] = [
        (RDPClipboardDownloadError.timedOut, "Remote file transfer timed out."),
        (RDPClipboardDownloadError.refused, "Remote file transfer failed."),
        (RDPClipboardDownloadError.incomplete, "Remote file transfer was incomplete."),
        (RDPClipboardDownloadError.totalByteLimitExceeded, "Remote files exceed 32 MiB."),
        (RDPClipboardRemoteFileTransferPlanningError.fileCountLimitExceeded, "Remote clipboard has more than 1000 files."),
        (DiskFull(), "Remote file could not be saved."),
        (RDPClipboardDownloadError.replaced, "Downloading remote file: big.bin."),
        (RDPClipboardDownloadError.sessionEnded, "Downloading remote file: big.bin."),
    ]
    for (error, message) in failures {
        try await startRemoteFileDownload(Data("remote".utf8), to: clipboard, from: session)
        #expect(clipboard.statusMessage == "Downloading remote file: big.bin.")
        let directory = try #require(session.downloads.last).directory
        try await failRemoteFileDownload(with: error, from: session)
        #expect(clipboard.statusMessage == message)
        #expect(clipboard.fileDownloadTask == nil)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    }
    #expect(pasteboardFileURLs(pasteboard).isEmpty)

    // More files than a download takes are turned down before one starts.
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: (0 ... 1_000).map {
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: "\($0).txt")
    }), copyNumber: session.announceRemoteCopy())
    #expect(clipboard.fileDownloadTask == nil)
    #expect(clipboard.statusMessage == "Remote clipboard has more than 1000 files.")
}

/// A newer remote copy of files replaces the download before it, which, ending late, leaves
/// the newer one be.
@MainActor
@Test func aNewerRemoteFileCopyReplacesTheDownloadBeforeIt() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)

    try await startRemoteFileDownload(Data("older".utf8), to: clipboard, from: session)
    let older = try #require(session.downloads.last)
    try await startRemoteFileDownload(Data("newer".utf8), to: clipboard, from: session)
    await older.bridgeTask?.value
    #expect(older.wasCancelled)
    #expect(FileManager.default.fileExists(atPath: older.directory.path) == false)
    #expect(clipboard.statusMessage == "Downloading remote file: big.bin.")

    try await finishRemoteFileDownload(with: Data("newer".utf8), from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: fileURL) == Data("newer".utf8))
}

/// The message follows the files of a download as they come, and the files land on the
/// pasteboard quarantined, under the names the server gave them.
@MainActor
@Test func aDownloadOfSeveralFilesSaysWhichIsComing() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let copyNumber = session.announceRemoteCopy()
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: ["a.txt", "b.txt", "c.txt"].map {
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: $0)
    }), copyNumber: copyNumber)
    #expect(clipboard.statusMessage == "Downloading remote files: 1 of 3.")
    let task = try #require(clipboard.fileDownloadTask)
    try await waitUntil { session.downloads.count == 1 }
    let download = try #require(session.downloads.last)

    download.progress?(RDPClipboardDownloadProgress(
        fileOffset: 1,
        fileCount: 3,
        fileName: "b.txt",
        receivedByteCount: 0,
        fileByteCount: nil
    ))
    try await waitUntil { clipboard.statusMessage == "Downloading remote files: 2 of 3." }
    #expect(clipboard.statusMessage == "Downloading remote files: 2 of 3.")
    download.finish(with: [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
    await task.value
    #expect(clipboard.statusMessage == "3 remote files copied.")
    let fileURLs = pasteboardFileURLs(pasteboard)
    defer { try? FileManager.default.removeItem(at: download.directory) }
    #expect(fileURLs.map(\.lastPathComponent) == ["a.txt", "b.txt", "c.txt"])
    #expect(try fileURLs.map { try Data(contentsOf: $0) } == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
    // Progress of a finished download, late on the main thread, changes nothing.
    download.progress?(RDPClipboardDownloadProgress(fileOffset: 2, fileCount: 3, fileName: "c.txt", receivedByteCount: 0, fileByteCount: nil))
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(clipboard.statusMessage == "3 remote files copied.")
}

@MainActor
private func pasteboardFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

@MainActor
@Test func aFinishedDownloadNeverReplacesANewerCopy() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    // Remote text copied during the download.
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    try await finishRemoteFileDownload(with: contents, from: session)
    #expect(pasteboard.string(forType: .string) == "remote text")
    #expect(clipboard.statusMessage == "Remote text copied.")

    // A local copy the next poll has not seen yet.
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    try await finishRemoteFileDownload(with: contents, from: session)
    #expect(pasteboard.string(forType: .string) == "local text")
    #expect(pasteboardFileURLs(pasteboard).isEmpty)
    #expect(clipboard.statusMessage == "Clipboard changed; remote files were not copied.")

    // A local copy the poll has published.
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    pasteboard.clearContents()
    pasteboard.setString("newer local text", forType: .string)
    clipboard.poll()
    try await finishRemoteFileDownload(with: contents, from: session)
    #expect(session.publishedTexts.last == "newer local text")
    #expect(pasteboard.string(forType: .string) == "newer local text")
    #expect(clipboard.statusMessage == "Local text synced.")
}

@MainActor
@Test func aRemoteFileCopyWinsOverALocalFileStillBeingRead() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let localFileURL = directory.appendingPathComponent("local.txt")
    try Data("local".utf8).write(to: localFileURL)
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    pasteboard.clearContents()
    pasteboard.writeObjects([localFileURL as NSURL])
    clipboard.poll()
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(session.publishedFiles.isEmpty)

    try await finishRemoteFileDownload(with: contents, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: fileURL) == contents)
}

@MainActor
@Test func aLocalCopyJustBeforeARemoteFileCopyLosesToIt() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    // Copied within the second before the server's copy, so no poll has seen it.
    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.poll()
    #expect(session.publishedTexts == [nil])

    try await finishRemoteFileDownload(with: contents, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: fileURL) == contents)
    #expect(clipboard.statusMessage == "Remote file copied: big.bin.")
}

/// Waits up to two seconds, for a local file read off the main thread.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 where condition() == false {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Sync Now and another "Share for 30s" send again a local copy that did not reach the
/// server, such as a file iCloud had not downloaded yet, but not one that did.
@MainActor
@Test func syncingSendsAgainALocalCopyThatFailed() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: false, pasteboard: pasteboard)
    clipboard.attach(session)
    let failure = "Local file clipboard could not be read; remote clipboard cleared."
    /// Copies a file that is not there to read yet.
    func copyMissingFile(named name: String) -> URL {
        let fileURL = directory.appendingPathComponent(name)
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        return fileURL
    }

    var fileURL = copyMissingFile(named: "first.txt")
    clipboard.startTemporarySharing()
    try await waitUntil { clipboard.statusMessage == failure }
    #expect(clipboard.statusMessage == failure)
    try Data("first".utf8).write(to: fileURL)
    clipboard.startTemporarySharing()
    try await waitUntil { session.publishedFiles.count == 1 }

    fileURL = copyMissingFile(named: "second.txt")
    clipboard.poll()
    try await waitUntil { clipboard.statusMessage == failure }
    #expect(clipboard.statusMessage == failure)
    try Data("second".utf8).write(to: fileURL)
    clipboard.syncNow()
    try await waitUntil { session.publishedFiles.count == 2 }

    // Sent, so neither sends it again.
    clipboard.syncNow()
    clipboard.startTemporarySharing()
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(session.publishedFiles.map { $0.map(\.contents) } == [[Data("first".utf8)], [Data("second".utf8)]])

    // A remote copy after a failed one is newer, so its download is kept.
    fileURL = copyMissingFile(named: "third.txt")
    clipboard.poll()
    try await waitUntil { clipboard.statusMessage == failure }
    try Data("third".utf8).write(to: fileURL)
    let contents = Data("remote".utf8)
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.syncNow()
    clipboard.startTemporarySharing()
    try await finishRemoteFileDownload(with: contents, from: session)
    let downloadedURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: downloadedURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: downloadedURL) == contents)
    #expect(session.publishedFiles.count == 2)
}

/// Sync Now and another "Share for 30s" send only a change, so the server's newer copy and
/// its download are kept.
@MainActor
@Test func syncingAnUnchangedPasteboardKeepsARemoteDownload() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: false, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    // A share that starts sends the pasteboard as it is.
    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    clipboard.startTemporarySharing()
    #expect(session.publishedTexts == [nil, "local text"])

    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.syncNow()
    clipboard.startTemporarySharing()
    #expect(clipboard.isSharingEnabled)
    try await finishRemoteFileDownload(with: contents, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: fileURL) == contents)
    #expect(session.publishedTexts == [nil, "local text"])
    #expect(session.publishedFiles.isEmpty)

    // A change is sent at once.
    pasteboard.clearContents()
    pasteboard.setString("newer local text", forType: .string)
    clipboard.syncNow()
    #expect(session.publishedTexts.last == "newer local text")
}

/// A server whose clipboard is emptied, as a password manager clears a copied password, takes
/// the copy it sent off the pasteboard too; a local copy since stays.
@MainActor
@Test func anEmptiedRemoteClipboardClearsOnlyTheCopyItSent() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    clipboard.receiveText("password", copyNumber: session.announceRemoteCopy())
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(clipboard.statusMessage == "Remote clipboard emptied; cleared here too.")
    // The emptied pasteboard is not sent back.
    clipboard.poll()
    #expect(session.publishedTexts == [nil])

    // Downloaded files go too, at the next poll.
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await finishRemoteFileDownload(with: contents, from: session)
    let directory = try #require(pasteboardFileURLs(pasteboard).first).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: session.announceRemoteCopy())
    clipboard.poll()
    #expect(pasteboardFileURLs(pasteboard).isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)

    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == "local text")
    #expect(clipboard.statusMessage == "Remote clipboard emptied.")
    #expect(session.publishedTexts == [nil])
}

/// A remote copy this bridge takes nothing of, such as an image, is newer than the remote
/// files still downloading, which are dropped; the pasteboard keeps what it has.
@MainActor
@Test func aRemoteCopyWithNoTextOrFilesEndsTheDownloadBeforeIt() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.receiveRemoteCopyUnavailable(isEmpty: false, copyNumber: session.announceRemoteCopy())
    #expect(clipboard.statusMessage == "No text or files arrived from the remote copy.")
    // RDPKit stops downloading it.
    await session.downloads.last?.bridgeTask?.value
    #expect(session.downloads.last?.wasCancelled == true)
    try await finishRemoteFileDownload(with: contents, from: session)
    #expect(pasteboardFileURLs(pasteboard).isEmpty)
    #expect(pasteboard.string(forType: .string) == "remote text")

    // The pasteboard still holds text that came from the server, so emptying the server's
    // clipboard takes it too.
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == nil)
}

@MainActor
@Test func downloadedFilesAreQuarantined() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await finishRemoteFileDownload(with: contents, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let quarantine = try #require(try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)

    #expect(quarantine[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeOtherDownload as String)
    #expect(quarantine[kLSQuarantineAgentNameKey as String] as? String == "RDPClient")
}

@MainActor
@Test func pastedFilesStayUntilANewDownloadReplacesThem() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)
    let fileManager = FileManager.default

    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await finishRemoteFileDownload(with: contents, from: session)
    let firstURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? fileManager.removeItem(at: firstURL.deletingLastPathComponent()) }

    // Downloads that fail leave the files on the pasteboard pasteable.
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await failRemoteFileDownload(with: RDPClipboardDownloadError.refused, from: session)
    #expect(clipboard.statusMessage == "Remote file transfer failed.")
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await failRemoteFileDownload(with: RDPClipboardDownloadError.timedOut, from: session)
    #expect(clipboard.statusMessage == "Remote file transfer timed out.")
    #expect(pasteboardFileURLs(pasteboard) == [firstURL])
    #expect(try Data(contentsOf: firstURL) == contents)

    // One that finishes replaces them.
    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await finishRemoteFileDownload(with: contents, from: session)
    let secondURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? fileManager.removeItem(at: secondURL.deletingLastPathComponent()) }
    #expect(secondURL != firstURL)
    #expect(fileManager.fileExists(atPath: firstURL.deletingLastPathComponent().path) == false)
}

/// Downloaded files go at the poll after a newer copy replaces them, not when the window closes.
@MainActor
@Test func pastedFilesAreRemovedOnceANewerCopyReplacesThem() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)
    let fileManager = FileManager.default
    var directories: [URL] = []
    defer { directories.forEach { try? fileManager.removeItem(at: $0) } }
    func downloadedDirectory() async throws -> URL {
        try await startRemoteFileDownload(contents, to: clipboard, from: session)
        try await finishRemoteFileDownload(with: contents, from: session)
        let directory = try #require(pasteboardFileURLs(pasteboard).first).deletingLastPathComponent()
        directories.append(directory)
        return directory
    }

    // Copying the downloaded file again keeps it.
    var directory = try await downloadedDirectory()
    let fileURL = directory.appendingPathComponent("big.bin")
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: fileURL.path))

    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: directory.path) == false)

    directory = try await downloadedDirectory()
    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: directory.path) == false)

    // Also with sharing turned off since.
    directory = try await downloadedDirectory()
    clipboard.setSharingEnabled(false)
    pasteboard.clearContents()
    pasteboard.setString("private text", forType: .string)
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: directory.path) == false)
}

@MainActor
@Test func closingRemovesDownloadedFilesOnceOffThePasteboard() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    try await startRemoteFileDownload(contents, to: clipboard, from: session)
    try await finishRemoteFileDownload(with: contents, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    clipboard.detach()
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    pasteboard.clearContents()
    pasteboard.setString("newer", forType: .string)
    clipboard.detach()
    #expect(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path) == false)
}

@Test func launchRemovesOnlyOldDownloadFoldersNotOnThePasteboard() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("RDPClientTests.\(UUID().uuidString)")
    let outside = fileManager.temporaryDirectory.appendingPathComponent("RDPClientTests.\(UUID().uuidString)")
    defer {
        try? fileManager.removeItem(at: root)
        try? fileManager.removeItem(at: outside)
    }
    let old = Date().addingTimeInterval(-2 * 60 * 60)
    func makeDirectory(_ url: URL, changedAt date: Date) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("file.bin"))
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    let stale = root.appendingPathComponent(UUID().uuidString)
    let recent = root.appendingPathComponent(UUID().uuidString)
    let onPasteboard = root.appendingPathComponent(UUID().uuidString)
    let notOurs = root.appendingPathComponent("Other")
    let link = root.appendingPathComponent(UUID().uuidString)
    try makeDirectory(stale, changedAt: old)
    try makeDirectory(recent, changedAt: Date())
    try makeDirectory(onPasteboard, changedAt: old)
    try makeDirectory(notOurs, changedAt: old)
    try makeDirectory(outside, changedAt: old)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

    RDPRemoteSessionClipboard.removeStaleDownloadDirectories(
        in: root,
        keeping: [onPasteboard.resolvingSymlinksInPath().path],
        changedBefore: Date().addingTimeInterval(-60 * 60)
    )

    #expect(fileManager.fileExists(atPath: stale.path) == false)
    for kept in [recent, onPasteboard, notOurs, link, outside.appendingPathComponent("file.bin")] {
        #expect(fileManager.fileExists(atPath: kept.path))
    }
}
