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

    server.answersFileRequests = false
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

    server.answersFileRequests = true
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
