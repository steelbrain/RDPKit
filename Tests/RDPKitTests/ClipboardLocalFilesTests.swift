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
