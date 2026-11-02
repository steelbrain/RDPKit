import Foundation
import RDPKit
import RDPKitTesting
import Testing

/// A remote copy of text reaches its handler with its number, and the server's clipboard
/// emptied reaches `onClipboardRemoteCopyUnavailable`.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerHandsRemoteCopiesToTheHandlers() async throws {
    let texts = Locked<[(String, Int)]>([])
    let unavailable = Locked<[(Bool, Int)]>([])
    let server = try await RDPClipboardTestServer(
        onClipboardText: { text, copyNumber in texts.withLock { $0.append((text, copyNumber)) } },
        onClipboardRemoteCopyUnavailable: { isEmpty, copyNumber in unavailable.withLock { $0.append((isEmpty, copyNumber)) } }
    )

    server.copyText("hello")
    await server.settle()
    let copyNumber = try #require(texts.value.last?.1)
    #expect(texts.value.map(\.0) == ["hello"])
    #expect(copyNumber == server.session.deliveredRemoteCopyNumber)

    server.emptyClipboard()
    await server.settle()
    #expect(unavailable.value.map(\.0) == [true])
    #expect(unavailable.value.map(\.1) == [copyNumber + 1])
}

/// A remote copy of files downloads through the session from the server's files, and a server
/// that leaves the requests unanswered times the download out.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerAnswersDownloads() async throws {
    let lists = Locked<[(RDPClipboardFileGroupDescriptorW, Int)]>([])
    let server = try await RDPClipboardTestServer(
        onClipboardFileGroupDescriptor: { list, copyNumber in lists.withLock { $0.append((list, copyNumber)) } }
    )
    let large = Data((0 ..< 2_000).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / 512) })
    let files = [
        RDPClipboardLocalFile(fileName: "a.txt", contents: Data("first".utf8)),
        RDPClipboardLocalFile(fileName: "b.bin", contents: large),
    ]
    server.copyFiles(files)
    await server.settle()
    let (list, copyNumber) = try #require(lists.value.last)
    let written = Locked<[String: Data]>([:])

    let download = try await server.session.downloadRemoteFiles(
        list.downloadPlan(limits: RDPClipboardDownloadLimits(rangeByteCount: 512)),
        copyNumber: copyNumber,
        into: URL(fileURLWithPath: "/downloads"),
        writeFile: { data, url in written.withLock { $0[url.lastPathComponent] = data } }
    )

    #expect(download.fileURLs.map(\.lastPathComponent) == ["a.txt", "b.bin"])
    #expect(written.value == ["a.txt": Data("first".utf8), "b.bin": large])
    // A size and a range for the first file, a size and four ranges for the second.
    #expect(server.fileRequestCount == 7)

    server.fileRequestAnswer = { _ in .hold }
    let stalled = Task {
        try await server.session.downloadRemoteFiles(
            list.downloadPlan(),
            copyNumber: copyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            writeFile: { _, _ in }
        )
    }
    while server.fileRequestCount == 7 {
        try await Task.sleep(for: .milliseconds(5))
    }
    await server.advanceTime(by: 120)
    await #expect(throws: RDPClipboardDownloadError.timedOut) { try await stalled.value }

    server.fileRequestAnswer = { _ in .answer }
    await server.endSession()
    await #expect(throws: RDPClipboardDownloadError.sessionEnded) {
        try await server.session.downloadRemoteFiles(
            list.downloadPlan(),
            copyNumber: copyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            writeFile: { _, _ in }
        )
    }
}

/// The server pastes the text the client published, and nothing once it withdrew it.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerPastesTheClientsText() async throws {
    let server = try await RDPClipboardTestServer()
    #expect(await server.pasteText() == nil)

    server.session.publishLocalUnicodeText("from the client")
    #expect(await server.pasteText() == "from the client")

    server.session.withdrawLocalCopy()
    #expect(await server.pasteText() == nil)
}

/// A restart of the server's clipboard hands the session to `onClipboardReady` again, with
/// fetching back to what it started as, so a copy the restarted server announces waits for the
/// application's choice.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerRestartsTheClipboard() async throws {
    let ready = Locked(0)
    let texts = Locked<[String]>([])
    let server = try await RDPClipboardTestServer(
        fetchesRemoteCopies: false,
        onClipboardReady: { _ in ready.withLock { $0 += 1 } },
        onClipboardText: { text, _ in texts.withLock { $0.append(text) } }
    )
    #expect(ready.value == 1)
    server.session.fetchesRemoteCopies = true

    server.restartClipboard()
    server.copyText("after the restart")
    await server.settle()
    #expect(ready.value == 2)
    #expect(texts.value.isEmpty)

    server.session.fetchesRemoteCopies = true
    await server.settle()
    #expect(texts.value == ["after the restart"])
}

/// A copy the server announced while fetching was off, with nothing the session fetches, is
/// reported once fetching is turned on, on the session's thread.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerDeliversTheEventTurningFetchingOnQueued() async throws {
    let unavailable = Locked<[Bool]>([])
    // No file list handler, so a copy of files offers nothing the session fetches.
    let server = try await RDPClipboardTestServer(
        fetchesRemoteCopies: false,
        onClipboardRemoteCopyUnavailable: { isEmpty, _ in unavailable.withLock { $0.append(isEmpty) } }
    )
    server.copyFiles([RDPClipboardLocalFile(fileName: "a.txt", contents: Data([1]))])
    await server.settle()
    #expect(unavailable.value.isEmpty)

    server.session.fetchesRemoteCopies = true
    await server.settle()
    #expect(unavailable.value == [false])
}

/// The server answers each file request as the test says: with a failure, a range cut short or
/// empty, or later, once the download timed out or while it still waits.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerAnswersFileRequestsAsTold() async throws {
    let lists = Locked<[(RDPClipboardFileGroupDescriptorW, Int)]>([])
    let server = try await RDPClipboardTestServer(
        onClipboardFileGroupDescriptor: { list, copyNumber in lists.withLock { $0.append((list, copyNumber)) } }
    )
    let contents = Data((0 ..< 100).map { UInt8($0) })
    server.copyFiles([RDPClipboardLocalFile(fileName: "a.bin", contents: contents)])
    await server.settle()
    let (list, copyNumber) = try #require(lists.value.last)
    @Sendable func download() async throws -> Data? {
        let written = Locked<Data?>(nil)
        _ = try await server.session.downloadRemoteFiles(
            list.downloadPlan(),
            copyNumber: copyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            writeFile: { data, _ in written.withLock { $0 = data } }
        )
        return written.value
    }

    let requests = Locked<[RDPClipboardTestServer.FileRequest]>([])
    server.fileRequestAnswer = { request in
        requests.withLock { $0.append(request) }
        return request.isSizeRequest ? .answer : .fail
    }
    await #expect(throws: RDPClipboardDownloadError.refused) { try await download() }
    #expect(requests.value.map(\.isSizeRequest) == [true, false])
    #expect(requests.value.last?.fileIndex == 0)
    #expect(requests.value.last?.position == 0)
    #expect(requests.value.last?.byteCount == 100)

    // Short ranges are asked again from where they stopped; an empty one ends the download.
    server.fileRequestAnswer = { $0.isSizeRequest ? .answer : .truncate(to: 40) }
    #expect(try await download() == contents)
    server.fileRequestAnswer = { $0.isSizeRequest ? .answer : .truncate(to: 0) }
    await #expect(throws: RDPClipboardDownloadError.incomplete) { try await download() }

    // Answered after the download timed out, the request changes nothing.
    server.fileRequestAnswer = { _ in .hold }
    let timedOut = Task { try await download() }
    while server.heldFileRequestCount == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    await server.advanceTime(by: 120)
    await #expect(throws: RDPClipboardDownloadError.timedOut) { try await timedOut.value }
    server.answerHeldFileRequests(.hold)
    #expect(server.heldFileRequestCount == 1)
    server.answerHeldFileRequests()
    #expect(server.heldFileRequestCount == 0)

    // Answered while the download still waits, it goes on.
    let waiting = Task { try await download() }
    while server.heldFileRequestCount == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    server.fileRequestAnswer = { _ in .answer }
    server.answerHeldFileRequests()
    #expect(try await waiting.value == contents)
}

/// The server records each copy the client publishes, and pastes the client's files through
/// the session's own file contents answers.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerRecordsTheClientsCopiesAndPastesItsFiles() async throws {
    let server = try await RDPClipboardTestServer()
    #expect(server.clientCopies == [.empty])
    #expect(await server.pasteFiles() == nil)

    let large = Data((0 ..< 10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    server.session.publishLocalFiles([
        RDPClipboardLocalFile(fileName: "Folder", contents: Data(), fileAttributes: RDPClipboardFileAttributes.directory),
        RDPClipboardLocalFile(fileName: "Folder\\notes.txt", contents: Data("notes".utf8)),
        RDPClipboardLocalFile(fileName: "empty.txt", contents: Data()),
        RDPClipboardLocalFile(fileName: "large.bin", contents: large),
    ])
    let pasted = try #require(await server.pasteFiles())
    #expect(pasted.map(\.descriptor.fileName) == ["Folder", "Folder\\notes.txt", "empty.txt", "large.bin"])
    #expect(pasted.map(\.contents) == [Data(), Data("notes".utf8), Data(), large])

    server.session.publishLocalUnicodeText("text")
    server.session.publishLocalContent(RDPClipboardContent(html: "<b>bold</b>"))
    server.session.withdrawLocalCopy()
    await server.settle()
    #expect(server.clientCopies == [.empty, .files, .text, .other, .empty])
    #expect(await server.pasteFiles() == nil)

    // A file shorter than its descriptor says runs out of bytes, and the paste fails.
    let hello = Data("hello".utf8)
    var descriptor = RDPClipboardLocalFile(fileName: "short.txt", contents: hello).descriptor
    descriptor.fileSize = 10
    server.session.publishLocalFiles([RDPClipboardLocalFile(descriptor: descriptor, contents: hello)])
    #expect(await server.pasteFiles() == nil)
}

/// A paste of files the client's copy does not offer answers nil without asking the session
/// for anything: with stepping on, no message waits to be handed over.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerAsksNothingForFilesTheClientDidNotOffer() async throws {
    let server = try await RDPClipboardTestServer()
    server.session.publishLocalUnicodeText("text")
    await server.settle()
    server.isStepping = true
    let finished = Locked(false)
    let paste = Task {
        let files = await server.pasteFiles()
        finished.withLock { $0 = true }
        return files
    }
    while !finished.withLock({ $0 }), server.heldMessageCount == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(server.heldMessageCount == 0)
    server.isStepping = false
    #expect(await paste.value == nil)
}

/// A server copy offers any formats, which the session fetches by name, and a server that
/// fails format data requests leaves its copy unavailable.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerCopiesOtherFormatsAndFailsRequestsWhenTold() async throws {
    let contents = Locked<[RDPClipboardContent]>([])
    let unavailable = Locked<[Bool]>([])
    let server = try await RDPClipboardTestServer(
        onClipboardContent: { content, _ in contents.withLock { $0.append(content) } },
        onClipboardRemoteCopyUnavailable: { isEmpty, _ in unavailable.withLock { $0.append(isEmpty) } }
    )
    let richText = Data("{\\rtf1 bold}".utf8)

    server.copyFormats([
        .init(id: 8, data: Data([1, 2, 3])),
        .init(id: 0xC0B1, name: "Rich Text Format", data: richText),
    ])
    await server.settle()
    #expect(contents.value == [RDPClipboardContent(richText: richText, bitmap: Data([1, 2, 3]))])

    server.failsFormatDataRequests = true
    server.copyText("refused")
    await server.settle()
    #expect(unavailable.value == [false])
    #expect(contents.value.count == 1)
}

/// While stepping, the server's messages wait for the test, so the client can publish between
/// a Format List and its data, which the session then drops, and a paste can find its copy
/// replaced.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerStepsThroughItsMessages() async throws {
    let texts = Locked<[String]>([])
    let server = try await RDPClipboardTestServer(
        onClipboardText: { text, _ in texts.withLock { $0.append(text) } }
    )

    server.isStepping = true
    server.copyText("remote")
    #expect(server.heldMessageCount == 1)
    #expect(server.step())
    await server.settle()
    #expect(server.session.isAwaitingRemoteCopy)
    // The text, which waits.
    #expect(server.heldMessageCount == 1)
    server.session.publishLocalUnicodeText("local")
    while server.step() {
        await server.settle()
    }
    #expect(!server.step())
    #expect(texts.value.isEmpty)
    #expect(server.clientCopies == [.empty, .text])

    server.copyText("released")
    #expect(server.heldMessageCount == 1)
    server.isStepping = false
    await server.settle()
    #expect(texts.value == ["released"])

    server.session.publishLocalFiles([RDPClipboardLocalFile(fileName: "a.txt", contents: Data([1]))])
    await server.settle()
    server.isStepping = true
    let paste = Task { await server.pasteFiles() }
    while server.heldMessageCount == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    server.session.publishLocalUnicodeText("replaced")
    server.isStepping = false
    #expect(await paste.value == nil)
}

/// What a handler hands the main queue, here a server action, is settled too by settling both
/// until neither has work left, as `settle()` shows.
@Test(.timeLimit(.minutes(1)))
func clipboardTestServerSettlesWithTheMainQueue() async throws {
    let box = Locked<RDPClipboardTestServer?>(nil)
    let recorded = Locked<[String]>([])
    let server = try await RDPClipboardTestServer(
        onClipboardText: { text, _ in
            DispatchQueue.main.async {
                recorded.withLock { $0.append(text) }
                if text == "first" {
                    box.value?.copyText("second")
                }
            }
        }
    )
    box.withLock { $0 = server }
    defer { box.withLock { $0 = nil } }

    server.copyText("first")
    await settleWithMainQueue(server)
    #expect(recorded.value == ["first", "second"])
    #expect(server.isSettled)
}

private func settleWithMainQueue(_ server: RDPClipboardTestServer) async {
    repeat {
        await server.settle()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    } while !server.isSettled
}

