import AppKit
@testable import RDPClient
import RDPKit
import Testing

private final class RecordedClipboard: RDPClipboardSending {
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

    /// A copy the server announces, and the number its handler gets.
    func announceRemoteCopy() -> Int {
        lastCopyNumber += 1
        return lastCopyNumber
    }

    func hasPublished(since remoteCopyNumber: Int) -> Bool {
        publishedCopyNumber > remoteCopyNumber
    }

    func publishLocalUnicodeText(_ text: String?) {
        recordPublish()
        publishedTexts.append(text)
    }

    func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        recordPublish()
        publishedFiles.append(files)
    }

    private func recordPublish() {
        unfetchedRemoteCopy = false
        lastCopyNumber += 1
        publishedCopyNumber = lastCopyNumber
    }

    var sizeRequests: [UInt32] = []
    var rangeRequests: [(streamID: UInt32, position: UInt64, requestedByteCount: UInt32)] = []

    func requestRemoteFileSize(streamID: UInt32, fileIndex _: Int32) throws {
        sizeRequests.append(streamID)
    }

    func requestRemoteFileRange(streamID: UInt32, fileIndex _: Int32, position: UInt64, requestedByteCount: UInt32) throws {
        rangeRequests.append((streamID, position, requestedByteCount))
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
    #expect(session.sizeRequests.isEmpty)

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
    #expect(session.sizeRequests.isEmpty)
    clipboard.setSharingEnabled(false)
    #expect(session.publishedTexts == ["local", "newer local", nil])

    clipboard.setSharingEnabled(true)
    clipboard.receiveText("newer remote", copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == "newer remote")
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

/// Offers one remote file of `contents` and answers the size request.
@MainActor
private func startRemoteFileDownload(
    _ contents: Data,
    to clipboard: RDPRemoteSessionClipboard,
    from session: RecordedClipboard
) throws {
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: UInt64(contents.count), fileName: "big.bin"),
    ]), copyNumber: session.announceRemoteCopy())
    let streamID = try #require(session.sizeRequests.last)
    let size = UInt64(contents.count).littleEndian
    clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
        streamID: streamID,
        ok: true,
        data: withUnsafeBytes(of: size) { Data($0) }
    ))
}

@MainActor
@Test func aRemoteFileArrivesOverRangesTheServerAnswersShort() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data((0 ..< 1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    var received = 0
    while received < contents.count {
        let request = try #require(session.rangeRequests.last)
        session.rangeRequests.removeAll()
        #expect(request.position == UInt64(received))
        #expect(request.requestedByteCount <= 512 * 1024)
        // Each range has two minutes to arrive over a slow link.
        clipboard.poll(now: Date().addingTimeInterval(115))
        // Windows caps how much one answer carries.
        let end = received + min(Int(request.requestedByteCount), 300_000)
        clipboard.receiveFileContents(RDPClipboardFileContentsResponse(
            streamID: request.streamID,
            ok: true,
            data: contents.subdata(in: received ..< end)
        ))
        received = end
    }

    #expect(session.rangeRequests.isEmpty)
    let fileURL = try #require((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: fileURL) == contents)
}

@MainActor
@Test func anEmptyRangeAnswerBeforeTheEndFailsTheDownload() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)

    try startRemoteFileDownload(Data(count: 10), to: clipboard, from: session)
    let request = try #require(session.rangeRequests.last)
    session.rangeRequests.removeAll()
    clipboard.receiveFileContents(RDPClipboardFileContentsResponse(streamID: request.streamID, ok: true, data: Data()))

    #expect(session.rangeRequests.isEmpty)
    #expect(clipboard.statusMessage == "Remote file transfer was incomplete.")
}

/// Answers the range request a download of `contents`, all asked for at once, is waiting on.
@MainActor
private func answerRangeRequest(
    with contents: Data,
    to clipboard: RDPRemoteSessionClipboard,
    from session: RecordedClipboard
) throws {
    let request = try #require(session.rangeRequests.last)
    session.rangeRequests.removeAll()
    clipboard.receiveFileContents(RDPClipboardFileContentsResponse(streamID: request.streamID, ok: true, data: contents))
}

@MainActor
private func pasteboardFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

@MainActor
@Test func aFinishedDownloadNeverReplacesANewerCopy() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    // Remote text copied during the download.
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    #expect(pasteboard.string(forType: .string) == "remote text")
    #expect(clipboard.statusMessage == "Remote text copied.")

    // A local copy the next poll has not seen yet.
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    #expect(pasteboard.string(forType: .string) == "local text")
    #expect(pasteboardFileURLs(pasteboard).isEmpty)
    #expect(clipboard.statusMessage == "Clipboard changed; remote files were not copied.")

    // A local copy the poll has published.
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    pasteboard.clearContents()
    pasteboard.setString("newer local text", forType: .string)
    clipboard.poll()
    try answerRangeRequest(with: contents, to: clipboard, from: session)
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
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(session.publishedFiles.isEmpty)

    try answerRangeRequest(with: contents, to: clipboard, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: fileURL) == contents)
}

@MainActor
@Test func aLocalCopyJustBeforeARemoteFileCopyLosesToIt() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    // Copied within the second before the server's copy, so no poll has seen it.
    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.poll()
    #expect(session.publishedTexts == [nil])

    try answerRangeRequest(with: contents, to: clipboard, from: session)
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
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.syncNow()
    clipboard.startTemporarySharing()
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    let downloadedURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: downloadedURL.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: downloadedURL) == contents)
    #expect(session.publishedFiles.count == 2)
}

/// Sync Now and another "Share for 30s" send only a change, so the server's newer copy and
/// its download are kept.
@MainActor
@Test func syncingAnUnchangedPasteboardKeepsARemoteDownload() throws {
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

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.syncNow()
    clipboard.startTemporarySharing()
    #expect(clipboard.isSharingEnabled)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
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
@Test func anEmptiedRemoteClipboardClearsOnlyTheCopyItSent() throws {
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
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
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
@Test func aRemoteCopyWithNoTextOrFilesEndsTheDownloadBeforeIt() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.receiveRemoteCopyUnavailable(isEmpty: false, copyNumber: session.announceRemoteCopy())
    #expect(clipboard.statusMessage == "No text or files arrived from the remote copy.")
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    #expect(pasteboardFileURLs(pasteboard).isEmpty)
    #expect(pasteboard.string(forType: .string) == "remote text")

    // The pasteboard still holds text that came from the server, so emptying the server's
    // clipboard takes it too.
    clipboard.receiveRemoteCopyUnavailable(isEmpty: true, copyNumber: session.announceRemoteCopy())
    #expect(pasteboard.string(forType: .string) == nil)
}

@MainActor
@Test func aDownloadTheServerStopsAnsweringTimesOut() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)
    let changeCount = pasteboard.changeCount

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    // A server that fetches a cloud file first can take minutes to answer.
    clipboard.poll(now: Date().addingTimeInterval(115))
    #expect(clipboard.statusMessage == "Downloading remote file: big.bin.")
    clipboard.poll(now: Date().addingTimeInterval(121))
    #expect(clipboard.statusMessage == "Remote file transfer timed out.")

    // The answer that comes too late changes nothing.
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    #expect(pasteboard.changeCount == changeCount)
    #expect(clipboard.statusMessage == "Remote file transfer timed out.")
}

@MainActor
@Test func downloadedFilesAreQuarantined() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    let fileURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let quarantine = try #require(try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)

    #expect(quarantine[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeOtherDownload as String)
    #expect(quarantine[kLSQuarantineAgentNameKey as String] as? String == "RDPClient")
}

@MainActor
@Test func pastedFilesStayUntilANewDownloadReplacesThem() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)
    let fileManager = FileManager.default

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    let firstURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? fileManager.removeItem(at: firstURL.deletingLastPathComponent()) }

    // Downloads that fail leave the files on the pasteboard pasteable.
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    let request = try #require(session.rangeRequests.last)
    clipboard.receiveFileContents(RDPClipboardFileContentsResponse(streamID: request.streamID, ok: false, data: Data()))
    #expect(clipboard.statusMessage == "Remote file transfer failed.")
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.poll(now: Date().addingTimeInterval(121))
    #expect(clipboard.statusMessage == "Remote file transfer timed out.")
    #expect(pasteboardFileURLs(pasteboard) == [firstURL])
    #expect(try Data(contentsOf: firstURL) == contents)

    // One that finishes replaces them.
    try startRemoteFileDownload(contents, to: clipboard, from: session)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    let secondURL = try #require(pasteboardFileURLs(pasteboard).first)
    defer { try? fileManager.removeItem(at: secondURL.deletingLastPathComponent()) }
    #expect(secondURL != firstURL)
    #expect(fileManager.fileExists(atPath: firstURL.deletingLastPathComponent().path) == false)
}

/// Downloaded files go at the poll after a newer copy replaces them, not when the window closes.
@MainActor
@Test func pastedFilesAreRemovedOnceANewerCopyReplacesThem() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)
    let fileManager = FileManager.default
    var directories: [URL] = []
    defer { directories.forEach { try? fileManager.removeItem(at: $0) } }
    func downloadedDirectory() throws -> URL {
        try startRemoteFileDownload(contents, to: clipboard, from: session)
        try answerRangeRequest(with: contents, to: clipboard, from: session)
        let directory = try #require(pasteboardFileURLs(pasteboard).first).deletingLastPathComponent()
        directories.append(directory)
        return directory
    }

    // Copying the downloaded file again keeps it.
    var directory = try downloadedDirectory()
    let fileURL = directory.appendingPathComponent("big.bin")
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: fileURL.path))

    pasteboard.clearContents()
    pasteboard.setString("local text", forType: .string)
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: directory.path) == false)

    directory = try downloadedDirectory()
    clipboard.receiveText("remote text", copyNumber: session.announceRemoteCopy())
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: directory.path) == false)

    // Also with sharing turned off since.
    directory = try downloadedDirectory()
    clipboard.setSharingEnabled(false)
    pasteboard.clearContents()
    pasteboard.setString("private text", forType: .string)
    clipboard.poll()
    #expect(fileManager.fileExists(atPath: directory.path) == false)
}

@MainActor
@Test func closingRemovesDownloadedFilesOnceOffThePasteboard() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    try answerRangeRequest(with: contents, to: clipboard, from: session)
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
