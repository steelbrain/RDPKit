import AppKit
@testable import RDPClient
import RDPKit
import Testing

private final class RecordedClipboard: RDPClipboardSending {
    var fetchesRemoteCopies = true
    var publishedTexts: [String?] = []
    var publishedFiles: [[RDPClipboardLocalFile]] = []

    func publishLocalUnicodeText(_ text: String?) {
        publishedTexts.append(text)
    }

    func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        publishedFiles.append(files)
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
    clipboard.poll()
    clipboard.receiveText("remote")
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: 1, fileName: "remote.txt"),
    ]))
    #expect(pasteboard.string(forType: .string) == "local")
    #expect(session.publishedTexts == [nil])
    #expect(session.publishedFiles.isEmpty)
    #expect(session.sizeRequests.isEmpty)

    clipboard.setSharingEnabled(true)
    #expect(session.fetchesRemoteCopies)
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

/// Offers one remote file of `contents` and answers the size request.
@MainActor
private func startRemoteFileDownload(
    _ contents: Data,
    to clipboard: RDPRemoteSessionClipboard,
    from session: RecordedClipboard
) throws {
    clipboard.receiveFileList(RDPClipboardFileGroupDescriptorW(descriptors: [
        RDPClipboardFileDescriptorW(flags: 0, fileAttributes: 0, fileSize: UInt64(contents.count), fileName: "big.bin"),
    ]))
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
        #expect(request.requestedByteCount <= 1024 * 1024)
        // Windows caps how much one answer carries.
        let end = received + min(Int(request.requestedByteCount), 700_000)
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
    clipboard.receiveText("remote text")
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
@Test func aDownloadTheServerStopsAnsweringTimesOut() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let session = RecordedClipboard()
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true, pasteboard: pasteboard)
    clipboard.attach(session)
    let contents = Data("remote".utf8)
    let changeCount = pasteboard.changeCount

    try startRemoteFileDownload(contents, to: clipboard, from: session)
    clipboard.poll(now: Date().addingTimeInterval(25))
    #expect(clipboard.statusMessage == "Downloading remote file: big.bin.")
    clipboard.poll(now: Date().addingTimeInterval(31))
    #expect(clipboard.statusMessage == "Remote file transfer timed out.")

    // The answer that comes too late changes nothing.
    try answerRangeRequest(with: contents, to: clipboard, from: session)
    #expect(pasteboard.changeCount == changeCount)
    #expect(clipboard.statusMessage == "Remote file transfer timed out.")
}
