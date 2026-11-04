import Foundation
import NIOEmbedded
@testable import RDPKit
import Testing

/// A folder of its own with `files` in it, by name.
private func directory(with files: [String: Data]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, contents) in files {
        try contents.write(to: directory.appendingPathComponent(name))
    }
    return directory
}

/// Files are read under their own names, in no folder, and within the byte limit, which a
/// file over it alone or one that brings the total over it passes.
@Test func localFilesAreReadUnderFlatNamesWithinTheByteLimit() throws {
    let directory = try directory(with: ["a\\b.txt": Data("hello".utf8), "large.bin": Data(count: 600), "more.bin": Data(count: 500)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = { directory.appendingPathComponent($0) }

    let files = try RDPClipboardLocalFile.read(contentsOf: [url("a\\b.txt"), url("large.bin")], maximumTotalByteCount: 605)
    #expect(files.map(\.descriptor.fileName) == ["a_b.txt", "large.bin"])
    #expect(files.map(\.contents) == [Data("hello".utf8), Data(count: 600)])

    #expect(throws: RDPClipboardLocalFileReadError.totalByteLimitExceeded) {
        try RDPClipboardLocalFile.read(contentsOf: [url("large.bin")], maximumTotalByteCount: 599)
    }
    #expect(throws: RDPClipboardLocalFileReadError.totalByteLimitExceeded) {
        try RDPClipboardLocalFile.read(contentsOf: [url("large.bin"), url("more.bin")], maximumTotalByteCount: 1_099)
    }
    #expect(try RDPClipboardLocalFile.read(contentsOf: [url("large.bin"), url("more.bin")], maximumTotalByteCount: 1_100).count == 2)
}

/// A file's size is checked before it is read, so one over the limit is never read: here one
/// that could not be.
@Test func aLocalFileOverTheLimitIsNotRead() throws {
    let directory = try directory(with: ["large.bin": Data(count: 600)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let large = directory.appendingPathComponent("large.bin")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: large.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: large.path) }

    #expect(throws: RDPClipboardLocalFileReadError.unreadable(large)) {
        try RDPClipboardLocalFile.read(contentsOf: [large])
    }
    #expect(throws: RDPClipboardLocalFileReadError.totalByteLimitExceeded) {
        try RDPClipboardLocalFile.read(contentsOf: [large], maximumTotalByteCount: 599)
    }
}

/// A folder, a file that is not there and a URL that names no file each fail the read.
@Test func localFilesThatCannotBeReadFailTheRead() throws {
    let directory = try directory(with: ["notes.txt": Data("hello".utf8)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let notes = directory.appendingPathComponent("notes.txt")
    let missing = directory.appendingPathComponent("missing.txt")
    let web = try #require(URL(string: "https://example.com/notes.txt"))

    #expect(throws: RDPClipboardLocalFileReadError.notARegularFile(directory)) {
        try RDPClipboardLocalFile.read(contentsOf: [notes, directory])
    }
    #expect(throws: RDPClipboardLocalFileReadError.unreadable(missing)) {
        try RDPClipboardLocalFile.read(contentsOf: [notes, missing])
    }
    #expect(throws: RDPClipboardLocalFileReadError.invalidFileName(web)) {
        try RDPClipboardLocalFile.read(contentsOf: [web])
    }
}

/// A read in a cancelled task stops before the next file.
@Test func aLocalFileReadStopsOnceItsTaskIsCancelled() async throws {
    let directory = try directory(with: ["notes.txt": Data("hello".utf8)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let read = Task { () throws -> [RDPClipboardLocalFile] in
        withUnsafeCurrentTask { $0?.cancel() }
        return try RDPClipboardLocalFile.read(contentsOf: [directory.appendingPathComponent("notes.txt")])
    }
    await #expect(throws: CancellationError.self) {
        try await read.value
    }
}

/// A file that grew past what is left of the limit since its size was read is refused, read no
/// more than a byte past, a chunk at a time.
@Test func aLocalFileReadStopsAByteMoreThanTheLimit() throws {
    let directory = try directory(with: ["large.bin": Data(count: 100), "full.bin": Data(count: 10), "empty.bin": Data()])
    defer { try? FileManager.default.removeItem(at: directory) }
    func handle(_ name: String) throws -> FileHandle {
        try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
    }

    let large = try handle("large.bin")
    defer { try? large.close() }
    #expect(try RDPClipboardLocalFile.contents(of: large, upTo: 10, chunkByteCount: 4) == nil)
    #expect(try large.offset() == 11)
    let full = try handle("full.bin")
    defer { try? full.close() }
    #expect(try RDPClipboardLocalFile.contents(of: full, upTo: 10, chunkByteCount: 4) == Data(count: 10))
    let empty = try handle("empty.bin")
    defer { try? empty.close() }
    #expect(try RDPClipboardLocalFile.contents(of: empty, upTo: 0, chunkByteCount: 4) == Data())
}

/// Nor does a cancelled read finish a file it has begun: it stops at the next chunk. A pipe
/// stands in for the file, so the read waits for each chunk the test writes.
@Test(.timeLimit(.minutes(1)))
func aLocalFileReadStopsBetweenChunksOnceItsTaskIsCancelled() async throws {
    let pipe = Pipe()
    let chunk = Data("abcd".utf8)
    let reader = pipe.fileHandleForReading
    let read = Task.detached {
        Result { try RDPClipboardLocalFile.contents(of: reader, upTo: 100, chunkByteCount: chunk.count) }
    }
    try pipe.fileHandleForWriting.write(contentsOf: chunk)
    // Cancelled only once the first chunk has been read.
    while hasBytesToRead(reader) {
        await Task.yield()
    }
    read.cancel()
    try pipe.fileHandleForWriting.write(contentsOf: chunk)
    try pipe.fileHandleForWriting.close()
    let result = await read.value
    #expect(throws: CancellationError.self) { try result.get() }
}

private func hasBytesToRead(_ fileHandle: FileHandle) -> Bool {
    var descriptor = pollfd(fd: fileHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
    return poll(&descriptor, 1, 0) > 0
}

/// A copy begun with an empty publish gets its files unless a newer copy replaced it: a later
/// publish or a server copy announced since, fetched or not. A server copy that crossed it is
/// older, and turning fetching off and on is no copy.
@Test func aBegunLocalCopyGetsItsFilesUnlessANewerCopyReplacedIt() throws {
    let channel = EmbeddedChannel()
    let sent = ClipboardSentMessages()
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel, sentMessageHandler: sent.record)
    let textCopy = RDPClipboardFormatListPDU(entries: [
        RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
    ]).encoded()
    let files = [RDPClipboardLocalFile(fileName: "notes.txt", contents: Data("hello".utf8))]
    /// Whether each Format List sent offers anything.
    func formatLists() -> [Bool] {
        sent.summaries.filter { $0.typeName == "clipboard-format-list" }.map { $0.dataLength > 0 }
    }
    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    _ = try session.receive(serverFormatListResponse)

    // Begun, the copy is empty at once; a server copy that crossed it, and fetching turned off
    // and on, leave it its files.
    let copy = session.beginLocalCopy()
    #expect(formatLists() == [false, false])
    #expect(session.hasPublished(since: session.deliveredRemoteCopyNumber))
    _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
    session.fetchesRemoteCopies = false
    session.fetchesRemoteCopies = true
    #expect(session.publishLocalFiles(files, forCopy: copy))
    #expect(formatLists() == [false, false, true])
    #expect(session.serverHoldsLocalCopy)
    _ = try session.receive(serverFormatListResponse)
    _ = try session.receive(serverFormatListResponse)

    // A later publish replaces it.
    let replacedByPublish = session.beginLocalCopy()
    session.publishLocalUnicodeText("newer")
    #expect(!session.publishLocalFiles(files, forCopy: replacedByPublish))
    _ = try session.receive(serverFormatListResponse)
    _ = try session.receive(serverFormatListResponse)

    // So does a server copy announced after it, fetched or not.
    for fetches in [true, false] {
        session.fetchesRemoteCopies = fetches
        let replacedByServer = session.beginLocalCopy()
        _ = try session.receive(serverFormatListResponse)
        _ = try session.receive(RDPClipboardPDU.parse(from: textCopy))
        #expect(!session.publishLocalFiles(files, forCopy: replacedByServer))
    }
    #expect(formatLists() == [false, false, true, false, true, false, false])

    // No files leave the empty copy, and send nothing more.
    let empty = session.beginLocalCopy()
    #expect(session.publishLocalFiles([], forCopy: empty))
    #expect(formatLists().count == 8)
    #expect(!session.serverHoldsLocalCopy)
    _ = try channel.finish()
}

/// A file on disk is published under the name `read(contentsOf:)` gives it, with the size it
/// has, and none of its bytes; a folder, a file that is not there and a URL that names no file
/// each fail.
@Test func localFilesOnDiskKeepTheirNameAndSizeOnly() throws {
    let directory = try directory(with: ["a\\b.txt": Data("hello".utf8), "empty.bin": Data()])
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("a\\b.txt")
    let missing = directory.appendingPathComponent("missing.txt")
    let web = try #require(URL(string: "https://example.com/notes.txt"))

    let file = try RDPClipboardLocalFile(fileURL: url)
    #expect(file.descriptor.fileName == "a_b.txt")
    #expect(file.descriptor.fileSize == 5)
    #expect(file.contents.isEmpty)
    #expect(file.fileURL == url.standardizedFileURL)
    #expect(try RDPClipboardLocalFile(fileURL: url) == file)
    #expect(try RDPClipboardLocalFile(fileURL: directory.appendingPathComponent("empty.bin")).descriptor.fileSize == 0)
    #expect(RDPClipboardLocalFile(fileName: "a_b.txt", contents: Data("hello".utf8)).fileURL == nil)
    // A limit the size is checked against before any byte is read.
    #expect(try RDPClipboardLocalFile(fileURL: url, maximumByteCount: 5) == file)
    #expect(throws: RDPClipboardLocalFileReadError.fileTooLarge(url)) {
        try RDPClipboardLocalFile(fileURL: url, maximumByteCount: 4)
    }

    #expect(throws: RDPClipboardLocalFileReadError.notARegularFile(directory)) {
        try RDPClipboardLocalFile(fileURL: directory)
    }
    #expect(throws: RDPClipboardLocalFileReadError.unreadable(missing)) {
        try RDPClipboardLocalFile(fileURL: missing)
    }
    #expect(throws: RDPClipboardLocalFileReadError.invalidFileName(web)) {
        try RDPClipboardLocalFile(fileURL: web)
    }
}

/// What a session sent in answer to file contents requests, in order, of the whole messages
/// in `sent`.
private func fileContentsResponses(_ sent: Locked<[Data]>) throws -> [RDPClipboardFileContentsResponse] {
    try sent.value.compactMap { try RDPClipboardFileContentsResponse.parseIfPresent(from: RDPClipboardPDU.parse(from: $0)) }
}

/// The ranges of a file on disk are read where the session schedules them, in order, and
/// answered there, each with its progress queued for the session's thread, the newest of a file
/// only. A range past the file's end, a file shorter than it was published, and one put in its
/// place, are refused.
@Test func aSessionReadsTheRangesOfAFileOnDiskWhereItSchedulesThem() throws {
    let contents = Data((0 ..< 10_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
    let directory = try directory(with: ["large.bin": contents])
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("large.bin")
    let channel = EmbeddedChannel()
    let sent = Locked<[Data]>([])
    let reads = Locked<[@Sendable () -> Void]>([])
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentPayloadHandler: { payload in sent.withLock { $0.append(payload) } },
        scheduleFileRead: { read in reads.withLock { $0.append(read) } }
    )
    session.publishLocalFiles([try RDPClipboardLocalFile(fileURL: url)])
    func runReads() {
        for read in reads.withLock({ reads in defer { reads = [] }; return reads }) {
            read()
        }
    }
    func progress(_ sentByteCount: UInt64) -> RDPClipboardEvent {
        .localFilePasteProgress(RDPClipboardLocalFilePasteProgress(
            fileOffset: 0,
            fileCount: 1,
            fileName: "large.bin",
            sentByteCount: sentByteCount,
            fileByteCount: 10_000
        ))
    }

    // The size goes at once.
    #expect(session.respondToFileContentsRequest(.size(streamID: 1, fileIndex: 0)) == nil)
    #expect(try fileContentsResponses(sent) == [.fileSize(streamID: 1, byteCount: 10_000)])
    #expect(session.respondToFileContentsRequest(.range(streamID: 2, fileIndex: 0, position: 0, requestedByteCount: 4096)) == nil)
    #expect(session.respondToFileContentsRequest(.range(streamID: 3, fileIndex: 0, position: 8192, requestedByteCount: 0x10000)) == nil)
    #expect(session.respondToFileContentsRequest(.range(streamID: 4, fileIndex: 0, position: 10_001, requestedByteCount: 1)) == nil)
    #expect(try fileContentsResponses(sent).count == 1)
    runReads()
    #expect(try fileContentsResponses(sent).dropFirst() == [
        .range(streamID: 2, data: contents.prefix(4096)),
        .range(streamID: 3, data: contents.suffix(from: 8192)),
        .failure(streamID: 4),
    ])
    #expect(session.takePendingEvent() == progress(10_000))
    #expect(session.takePendingEvent() == nil)

    // Shorter than published.
    try contents.prefix(5_000).write(to: url)
    #expect(session.respondToFileContentsRequest(.range(streamID: 5, fileIndex: 0, position: 4096, requestedByteCount: 4096)) == nil)
    runReads()
    #expect(try fileContentsResponses(sent).last == .failure(streamID: 5))

    // Another file in its place, as long as it was.
    try FileManager.default.removeItem(at: url)
    try contents.write(to: url)
    #expect(session.respondToFileContentsRequest(.range(streamID: 6, fileIndex: 0, position: 0, requestedByteCount: 1)) == nil)
    runReads()
    #expect(try fileContentsResponses(sent).last == .failure(streamID: 6))
    #expect(session.takePendingEvent() == nil)
    _ = try channel.finish()
}

/// Range requests for files on disk wait to be read up to a limit, past which they are refused
/// at once.
@Test func aSessionRefusesRangesOfFilesOnDiskPastTheWaitingLimit() throws {
    let directory = try directory(with: ["notes.txt": Data("notes".utf8)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let channel = EmbeddedChannel()
    let sent = Locked<[Data]>([])
    let reads = Locked<[@Sendable () -> Void]>([])
    let session = RDPClipboardSession(
        userChannelID: 1006,
        staticChannelID: 1007,
        channel: channel,
        sentPayloadHandler: { payload in sent.withLock { $0.append(payload) } },
        scheduleFileRead: { read in reads.withLock { $0.append(read) } }
    )
    session.publishLocalFiles([try RDPClipboardLocalFile(fileURL: directory.appendingPathComponent("notes.txt"))])
    let limit = RDPClipboardSession.maximumWaitingFileReadCount
    for streamID in 0 ... UInt32(limit) {
        session.respondToFileContentsRequest(.range(streamID: streamID, fileIndex: 0, position: 0, requestedByteCount: 5))
    }
    #expect(reads.value.count == limit)
    #expect(try fileContentsResponses(sent) == [.failure(streamID: UInt32(limit))])

    // Each read done makes room for another.
    reads.withLock { $0.removeFirst() }()
    session.respondToFileContentsRequest(.range(streamID: 100, fileIndex: 0, position: 0, requestedByteCount: 5))
    #expect(reads.value.count == limit)
    #expect(try fileContentsResponses(sent).count == 2)
    _ = try channel.finish()
}

/// The largest file the server's clipboard takes follows the capabilities it sent before its
/// Monitor Ready: none without CB_STREAM_FILECLIP_ENABLED or capabilities, 4 GiB less a byte
/// without CB_HUGE_FILE_SUPPORT_ENABLED, any size with both.
@Test func clipboardSessionSaysTheLargestFileTheServerTakes() throws {
    let stream = RDPClipboardCapabilityFlags.streamFileClipEnabled
    let huge = RDPClipboardCapabilityFlags.hugeFileSupportEnabled
    let cases: [(UInt32?, UInt64?)] = [
        (nil, nil),
        (0, nil),
        (huge, nil),
        (stream | RDPClipboardCapabilityFlags.useLongFormatNames, UInt64(UInt32.max)),
        (stream | huge, .max),
    ]
    for (serverFlags, maximumFileByteCount) in cases {
        let channel = EmbeddedChannel()
        let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel)
        if let serverFlags {
            _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU(generalFlags: serverFlags).encoded()))
        }
        #expect(session.maximumFileByteCount == nil)
        _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
        #expect(session.maximumFileByteCount == maximumFileByteCount)
        _ = try channel.finish()
    }
}
