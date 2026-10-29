import AppKit
@testable import RDPClient
import RDPKit
import Testing

private final class RecordedClipboard: RDPClipboardSending {
    var publishedTexts: [String?] = []
    var publishedFiles: [[RDPClipboardLocalFile]] = []

    func publishLocalUnicodeText(_ text: String?) {
        publishedTexts.append(text)
    }

    func publishLocalFiles(_ files: [RDPClipboardLocalFile]) {
        publishedFiles.append(files)
    }

    func requestRemoteFileSize(streamID _: UInt32, fileIndex _: Int32) throws {}

    func requestRemoteFileRange(streamID _: UInt32, fileIndex _: Int32, position _: UInt64, requestedByteCount _: UInt32) throws {}
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
