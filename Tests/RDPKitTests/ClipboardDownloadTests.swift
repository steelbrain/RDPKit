import Foundation
import NIOCore
import NIOEmbedded
@testable import RDPKit
import Testing

/// A server's clipboard holding `contents`, file by file, that answers the file requests a
/// session sends from another thread, as `answer` says: by default as MS-RDPECLIP 2.2.5.4 has
/// it, at most `maximumRangeByteCount` bytes of a range; nil leaves a request unanswered.
private final class ClipboardFileServer: @unchecked Sendable {
    typealias Answer = @Sendable (RDPClipboardFileContentsRequestPDU, ClipboardFileServer) -> RDPClipboardFileContentsResponse?

    let contents: [Data]
    let maximumRangeByteCount: Int
    private let lock = NSLock()
    private var recorded: [RDPClipboardFileContentsRequestPDU] = []
    private let answer: Answer
    private weak var storedSession: RDPClipboardSession?

    init(contents: [Data], maximumRangeByteCount: Int = .max, answer: @escaping Answer = { $1.answer($0) }) {
        self.contents = contents
        self.maximumRangeByteCount = maximumRangeByteCount
        self.answer = answer
    }

    var session: RDPClipboardSession? {
        get { lock.withLock { storedSession } }
        set { lock.withLock { storedSession = newValue } }
    }

    var requests: [RDPClipboardFileContentsRequestPDU] {
        lock.withLock { recorded }
    }

    func answer(_ request: RDPClipboardFileContentsRequestPDU) -> RDPClipboardFileContentsResponse {
        let file = contents[Int(request.fileIndex)]
        if request.flags & RDPClipboardFileContentsFlags.size != 0 {
            return .fileSize(streamID: request.streamID, byteCount: UInt64(file.count))
        }
        let lowerBound = min(Int(request.position), file.count)
        let byteCount = min(Int(request.requestedByteCount), maximumRangeByteCount, file.count - lowerBound)
        return .range(streamID: request.streamID, data: file.subdata(in: lowerBound ..< lowerBound + byteCount))
    }

    @Sendable func record(_: RDPClipboardMessageSummary, _ packets: Data) {
        guard let request = try? RDPClipboardFileContentsRequestPDU.parseIfPresent(
            from: RDPClipboardPDU.parse(from: clipboardPayload(fromPackets: packets))
        ) else {
            return
        }
        lock.withLock { recorded.append(request) }
        guard let response = answer(request, self), let session else {
            return
        }
        Thread.detachNewThread {
            _ = try? session.receive(RDPClipboardPDU.parse(from: response.encoded()))
        }
    }
}

private let fileCopyFormatList = RDPClipboardFormatListPDU(entries: [
    RDPClipboardFormatListEntry(formatID: 0xC0A3, formatName: "FileGroupDescriptorW"),
]).encoded()

private let textCopyFormatList = RDPClipboardFormatListPDU(entries: [
    RDPClipboardFormatListEntry(formatID: RDPClipboardFormatID.unicodeText),
]).encoded()

/// A session whose server has copied `list`, and the number of that copy, as an
/// `onClipboardFileGroupDescriptor` handler reads it.
private func makeSession(
    holding list: RDPClipboardFileGroupDescriptorW,
    on server: ClipboardFileServer,
    channel: NIOAsyncTestingChannel
) async throws -> (session: RDPClipboardSession, copyNumber: Int) {
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3389))
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel, sentMessageHandler: server.record)
    server.session = session
    _ = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardCapabilitiesPDU().encoded()))
    _ = try session.receive(RDPClipboardPDU(messageType: RDPClipboardMessageType.monitorReady))
    _ = try session.receive(RDPClipboardPDU.parse(from: fileCopyFormatList))
    let event = try session.receive(RDPClipboardPDU.parse(from: RDPClipboardFormatDataResponsePDU.fileGroupDescriptorW(list).encoded()))
    #expect(event == .fileGroupDescriptor(list))
    return (session, session.deliveredRemoteCopyNumber)
}

private func fileList(_ files: [(String, Data)], folders: [String] = []) -> RDPClipboardFileGroupDescriptorW {
    RDPClipboardFileGroupDescriptorW(descriptors: folders.map {
        RDPClipboardFileDescriptorW(
            flags: RDPClipboardFileDescriptorFlags.attributes | RDPClipboardFileDescriptorFlags.unicode,
            fileAttributes: RDPClipboardFileAttributes.directory,
            fileSize: 0,
            fileName: $0
        )
    } + files.map { RDPClipboardLocalFile(fileName: $0.0, contents: $0.1).descriptor })
}

/// The download's outcome once it ends, or nil when it has not within `seconds`; it is
/// cancelled then.
private func outcome<Success: Sendable>(
    of task: Task<Success, Error>,
    within seconds: Double = 10
) async -> Result<Success, Error>? {
    await withTaskGroup(of: Result<Success, Error>?.self) { group in
        group.addTask { await task.result }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        task.cancel()
        group.cancelAll()
        return first
    }
}

/// Waits, at most 10 s, until `condition` holds.
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private let writeNothing: @Sendable (Data, URL) throws -> Void = { _, _ in }

/// Each file gets a stream, a size request and as many range requests as the server's short
/// answers take; folders are left out and each file is written under the name planning gave it.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadAsksForTheRestOfShortRangesAndWritesEachFile() async throws {
    let large = Data((0 ..< 1_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
    let list = fileList([("a.txt", large), ("empty.txt", Data()), ("a.txt", Data([1, 2, 3, 4, 5]))], folders: ["photos"])
    let server = ClipboardFileServer(contents: [Data(), large, Data(), Data([1, 2, 3, 4, 5])], maximumRangeByteCount: 300)
    let channel = NIOAsyncTestingChannel()
    let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reports = Locked<[RDPClipboardDownloadProgress]>([])

    let download = try await session.downloadRemoteFiles(
        list,
        copyNumber: copyNumber,
        into: directory,
        limits: RDPClipboardDownloadLimits(rangeByteCount: 512),
        progress: { report in reports.withLock { $0.append(report) } }
    )

    let names = try list.remoteFileTransferFiles().map(\.fileName)
    #expect(names.count == 3 && Set(names).count == 3)
    #expect(download == RDPClipboardDownload(
        fileURLs: names.map { directory.appendingPathComponent($0, isDirectory: false) },
        leavesOutFolders: true
    ))
    #expect(try download.fileURLs.map { try Data(contentsOf: $0) } == [large, Data(), Data([1, 2, 3, 4, 5])])

    let first = RDPClipboardSession.firstDownloadStreamID
    #expect(server.requests == [
        .size(streamID: first, fileIndex: 1),
        .range(streamID: first, fileIndex: 1, position: 0, requestedByteCount: 512),
        .range(streamID: first, fileIndex: 1, position: 300, requestedByteCount: 512),
        .range(streamID: first, fileIndex: 1, position: 600, requestedByteCount: 400),
        .range(streamID: first, fileIndex: 1, position: 900, requestedByteCount: 100),
        .size(streamID: first + 1, fileIndex: 2),
        .size(streamID: first + 2, fileIndex: 3),
        .range(streamID: first + 2, fileIndex: 3, position: 0, requestedByteCount: 5),
    ])
    #expect(reports.value.filter { $0.fileOffset == 0 }.map { [$0.receivedByteCount, $0.fileByteCount ?? 0] }
        == [[0, 0], [0, 1_000], [300, 1_000], [600, 1_000], [900, 1_000]])
    #expect(reports.value.allSatisfy { $0.fileCount == 3 && $0.fileName == names[$0.fileOffset] })
    try await channel.close()
}

/// A failure answer, a size that does not parse, an empty range before the file's end and one
/// larger than asked for each end the download.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadEndsOnAnAnswerItCannotUse() async throws {
    let isSize: @Sendable (RDPClipboardFileContentsRequestPDU) -> Bool = {
        $0.flags & RDPClipboardFileContentsFlags.size != 0
    }
    let cases: [(ClipboardFileServer.Answer, RDPClipboardDownloadError)] = [
        ({ request, _ in .failure(streamID: request.streamID) }, .refused),
        ({ request, server in isSize(request) ? server.answer(request) : .failure(streamID: request.streamID) }, .refused),
        ({ request, _ in RDPClipboardFileContentsResponse(streamID: request.streamID, ok: true, data: Data([1, 2])) }, .incomplete),
        ({ request, server in isSize(request) ? server.answer(request) : .range(streamID: request.streamID, data: Data()) }, .incomplete),
        ({ request, server in
            isSize(request)
                ? server.answer(request)
                : .range(streamID: request.streamID, data: Data(count: Int(request.requestedByteCount) + 1))
        }, .incomplete),
    ]
    for (answer, error) in cases {
        let list = fileList([("a.txt", Data(count: 10))])
        let server = ClipboardFileServer(contents: [Data(count: 10)], answer: answer)
        let channel = NIOAsyncTestingChannel()
        let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)
        let wrote = Locked(false)
        await #expect(throws: error) {
            try await session.downloadRemoteFiles(
                list,
                copyNumber: copyNumber,
                into: URL(fileURLWithPath: "/nonexistent"),
                writeFile: { _, _ in wrote.withLock { $0 = true } }
            )
        }
        #expect(!wrote.value)
        try await channel.close()
    }
}

/// The sizes the server answers count against the byte limit, whatever the list declared, and
/// one past it ends the download before any of that file's bytes are asked for.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadStopsWhereTheAnsweredSizesPassTheByteLimit() async throws {
    let list = fileList([("a.txt", Data(count: 1)), ("b.txt", Data(count: 1))])
    let server = ClipboardFileServer(contents: [Data(count: 600), Data(count: 600)])
    let channel = NIOAsyncTestingChannel()
    let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)
    let written = Locked<[String]>([])

    await #expect(throws: RDPClipboardDownloadError.totalByteLimitExceeded) {
        try await session.downloadRemoteFiles(
            list,
            copyNumber: copyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            limits: RDPClipboardDownloadLimits(maximumTotalByteCount: 1_000),
            writeFile: { _, url in written.withLock { $0.append(url.lastPathComponent) } }
        )
    }
    #expect(written.value == ["a.txt"])
    #expect(server.requests.last == .size(streamID: RDPClipboardSession.firstDownloadStreamID + 1, fileIndex: 1))
    try await channel.close()

    // One file alone past the limit.
    let largeServer = ClipboardFileServer(contents: [Data(count: 1_001)])
    let largeChannel = NIOAsyncTestingChannel()
    let largeList = fileList([("large.bin", Data(count: 1))])
    let (largeSession, largeCopyNumber) = try await makeSession(holding: largeList, on: largeServer, channel: largeChannel)
    await #expect(throws: RDPClipboardDownloadError.totalByteLimitExceeded) {
        try await largeSession.downloadRemoteFiles(
            largeList,
            copyNumber: largeCopyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            limits: RDPClipboardDownloadLimits(maximumTotalByteCount: 1_000),
            writeFile: writeNothing
        )
    }
    #expect(largeServer.requests.count == 1)
    try await largeChannel.close()
}

/// More files than the limit, folders not counted, fail planning, before anything is asked
/// for; an error the application's writer throws ends the download.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadLimitsTheFileCountAndEndsOnAWriteError() async throws {
    let list = fileList([("a.txt", Data([1])), ("b.txt", Data([2])), ("c.txt", Data([3]))], folders: ["photos"])
    #expect(try list.remoteFileTransferFiles(maximumFileCount: 3).count == 3)
    #expect(throws: RDPClipboardRemoteFileTransferPlanningError.fileCountLimitExceeded) {
        try list.remoteFileTransferFiles(maximumFileCount: 2)
    }
    let server = ClipboardFileServer(contents: [Data(), Data([1]), Data([2]), Data([3])])
    let channel = NIOAsyncTestingChannel()
    let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)

    await #expect(throws: RDPClipboardRemoteFileTransferPlanningError.fileCountLimitExceeded) {
        try await session.downloadRemoteFiles(
            list,
            copyNumber: copyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            limits: RDPClipboardDownloadLimits(maximumFileCount: 2),
            writeFile: writeNothing
        )
    }
    #expect(server.requests.isEmpty)

    struct DiskFull: Error {}
    await #expect(throws: DiskFull.self) {
        try await session.downloadRemoteFiles(
            list,
            copyNumber: copyNumber,
            into: URL(fileURLWithPath: "/downloads"),
            writeFile: { _, _ in throw DiskFull() }
        )
    }
    #expect(server.requests.count == 2)
    try await channel.close()
}

/// A request the server leaves unanswered fails once the timeout passes, and its late answer
/// is dropped.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadGivesUpOnARequestLeftUnanswered() async throws {
    let list = fileList([("a.txt", Data([1]))])
    let server = ClipboardFileServer(contents: [Data([1])]) { _, _ in nil }
    let channel = NIOAsyncTestingChannel()
    let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)

    let download = Task {
        try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
    }
    try await waitUntil { server.requests.count == 1 }
    await channel.testingEventLoop.advanceTime(by: .seconds(119))
    #expect(await outcome(of: download, within: 0.2) == nil)

    let retried = Task {
        try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
    }
    try await waitUntil { server.requests.count == 2 }
    await channel.testingEventLoop.advanceTime(by: .seconds(120))
    let result = try #require(await outcome(of: retried))
    #expect(throws: RDPClipboardDownloadError.timedOut) { try result.get() }

    let lateAnswer = RDPClipboardFileContentsResponse.fileSize(streamID: server.requests[1].streamID, byteCount: 1)
    #expect(try session.receive(RDPClipboardPDU.parse(from: lateAnswer.encoded())) == nil)
    try await channel.close()
}

/// A newer copy, the server's or a publish, or turning fetching off, ends a download waiting
/// for an answer, and one of an older copy never starts.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadEndsOnceANewerCopyReplacesItsOwn() async throws {
    let replacements: [@Sendable (RDPClipboardSession) throws -> Void] = [
        { _ = try $0.receive(RDPClipboardPDU.parse(from: textCopyFormatList)) },
        { $0.publishLocalUnicodeText("local") },
        { $0.fetchesRemoteCopies = false },
    ]
    for replace in replacements {
        let list = fileList([("a.txt", Data([1]))])
        let server = ClipboardFileServer(contents: [Data([1])]) { _, _ in nil }
        let channel = NIOAsyncTestingChannel()
        let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)
        let download = Task {
            try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
        }
        try await waitUntil { server.requests.count == 1 }
        try replace(session)
        let result = try #require(await outcome(of: download))
        #expect(throws: RDPClipboardDownloadError.replaced) { try result.get() }

        await #expect(throws: RDPClipboardDownloadError.replaced) {
            try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
        }
        #expect(server.requests.count == 1)
        try await channel.close()
    }
}

/// The connection closing ends a download waiting for an answer, and any download after it;
/// cancelling its task ends one too.
@Test(.timeLimit(.minutes(1)))
func clipboardDownloadEndsWithTheConnectionOrItsTask() async throws {
    let list = fileList([("a.txt", Data([1]))])
    let server = ClipboardFileServer(contents: [Data([1])]) { _, _ in nil }
    let channel = NIOAsyncTestingChannel()
    let (session, copyNumber) = try await makeSession(holding: list, on: server, channel: channel)

    let cancelled = Task {
        try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
    }
    try await waitUntil { server.requests.count == 1 }
    cancelled.cancel()
    let cancellation = try #require(await outcome(of: cancelled))
    #expect(throws: CancellationError.self) { try cancellation.get() }

    let closed = Task {
        try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
    }
    try await waitUntil { server.requests.count == 2 }
    try await channel.close()
    let result = try #require(await outcome(of: closed))
    #expect(throws: RDPClipboardDownloadError.sessionEnded) { try result.get() }
    await #expect(throws: RDPClipboardDownloadError.sessionEnded) {
        try await session.downloadRemoteFiles(list, copyNumber: copyNumber, into: URL(fileURLWithPath: "/downloads"), writeFile: writeNothing)
    }
    #expect(server.requests.count == 2)
}

/// Answers to an application's own streams reach `onClipboardFileContents`; those to a
/// download's streams never do, even with no download waiting.
@Test func clipboardSessionKeepsDownloadAnswersFromTheApplication() throws {
    let channel = EmbeddedChannel()
    let session = RDPClipboardSession(userChannelID: 1006, staticChannelID: 1007, channel: channel)
    let own = RDPClipboardFileContentsResponse.fileSize(streamID: RDPClipboardSession.firstDownloadStreamID - 1, byteCount: 4)
    let download = RDPClipboardFileContentsResponse.fileSize(streamID: RDPClipboardSession.firstDownloadStreamID, byteCount: 4)

    #expect(try session.receive(RDPClipboardPDU.parse(from: own.encoded())) == .fileContents(own))
    #expect(try session.receive(RDPClipboardPDU.parse(from: download.encoded())) == nil)
    _ = try channel.finish()
}
