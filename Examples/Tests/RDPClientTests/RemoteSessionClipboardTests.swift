import AppKit
@testable import RDPClient
import RDPKit
import RDPKitAppKit
import RDPKitTesting
import Testing

// RDPKitAppKit's tests cover what the bridge does; these, the status line RDPClient shows.

/// A pasteboard and download folder of the test's own, so it never touches the user's.
@MainActor
private func makeClipboard(isSharingEnabled: Bool) -> (RDPRemoteSessionClipboard, NSPasteboard, URL) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("RDPClientTests.\(UUID().uuidString)"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RDPClientTests.\(UUID().uuidString)")
    return (RDPRemoteSessionClipboard(isSharingEnabled: isSharingEnabled, pasteboard: pasteboard, downloadRoot: root), pasteboard, root)
}

/// Waits until the server has handled what it was sent, and the main queue what its handlers
/// handed it.
private func settle(_ server: RDPClipboardTestServer) async {
    for _ in 0 ..< 3 {
        await server.settle()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

/// The status line says whether sharing is on and the session ready, then what happened last;
/// attaching or turning sharing off and on starts it over.
@MainActor
@Test func theClipboardStatusLineSaysWhatHappenedLast() async throws {
    let (clipboard, pasteboard, root) = makeClipboard(isSharingEnabled: true)
    defer {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
    #expect(clipboard.statusMessage == "Not ready.")
    #expect(clipboard.temporarySharingButtonTitle == "Share for 30s")
    clipboard.startTemporarySharing()
    #expect(clipboard.statusMessage == "Not ready.")

    let server = try await RDPClipboardTestServer(fetchesRemoteCopies: false, onClipboardText: { text, copyNumber in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                clipboard.receiveText(text, copyNumber: copyNumber)
            }
        }
    })
    clipboard.attach(server.session)
    #expect(clipboard.statusMessage == "Ready.")
    server.copyText("remote")
    await settle(server)
    #expect(pasteboard.string(forType: .string) == "remote")
    #expect(clipboard.statusMessage == "Remote text copied.")
    clipboard.syncNow()
    #expect(clipboard.statusMessage == "Clipboard is up to date.")

    clipboard.setSharingEnabled(false)
    #expect(clipboard.statusMessage == "Disabled.")
    clipboard.startTemporarySharing()
    #expect(clipboard.statusMessage == "Temporary sharing enabled.")
    #expect(clipboard.temporarySharingButtonTitle == "Sharing 30s")
    clipboard.setSharingEnabled(true)
    #expect(clipboard.statusMessage == "Ready.")
    await server.endSession()
}

/// Each event reads as a status line of its own.
@MainActor
@Test func eachClipboardEventHasAStatusLine() {
    let events: [RDPPasteboardClipboard.Event] = [
        .localTextShared,
        .localClipboardEmpty,
        .localTextTooLarge,
        .localFilesShared(count: 1),
        .localFilesShared(count: 3),
        .localFilesNotShared(.unreadable(URL(fileURLWithPath: "/tmp/a.txt"))),
        .localFilesNotShared(.totalByteLimitExceeded),
        .pasteboardAccessDenied,
        .upToDate,
        .remoteTextCopied,
        .remoteCopyUnavailable,
        .remoteClipboardEmptied(clearedHere: true),
        .remoteClipboardEmptied(clearedHere: false),
        .remoteFilesRefused(.fileCountLimitExceeded),
        .downloadProgress(RDPClipboardDownloadProgress(fileOffset: 0, fileCount: 1, fileName: "a.txt", receivedByteCount: 0, fileByteCount: nil)),
        .downloadProgress(RDPClipboardDownloadProgress(fileOffset: 1, fileCount: 4, fileName: "b.txt", receivedByteCount: 0, fileByteCount: nil)),
        .remoteFilesCopied(RDPClipboardDownload(fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")], leavesOutFolders: false)),
        .downloadFailed(.timedOut),
        .downloadFailed(.totalByteLimitExceeded),
        .downloadFailed(.clipboardChanged),
        .temporarySharingEnded,
    ]
    let messages = events.map { RDPRemoteSessionClipboard.message(for: $0) }
    #expect(messages == [
        "Local text synced.",
        "Local clipboard has no text.",
        "Local text is too large to sync; remote clipboard cleared.",
        "Local file synced.",
        "3 local files synced.",
        "Local file clipboard could not be read; remote clipboard cleared.",
        "Local clipboard files exceed 32 MiB; remote clipboard cleared.",
        "Clipboard access is off for RDPClient in System Settings.",
        "Clipboard is up to date.",
        "Remote text copied.",
        "No text or files arrived from the remote copy.",
        "Remote clipboard emptied; cleared here too.",
        "Remote clipboard emptied.",
        "Remote clipboard has more than 1000 files.",
        "Downloading remote file: a.txt.",
        "Downloading remote files: 2 of 4.",
        "Remote file copied: a.txt.",
        "Remote file transfer timed out.",
        "Remote files exceed 32 MiB.",
        "Clipboard changed; remote files were not copied.",
        "Temporary sharing ended.",
    ])
}

/// The limits a copy went over are the bridge's own.
@MainActor
@Test func theClipboardStatusLineNamesTheBridgesLimits() {
    let limits = RDPClipboardDownloadLimits(maximumTotalByteCount: 8 * 1024 * 1024, maximumFileCount: 20)
    #expect(RDPRemoteSessionClipboard.message(for: .remoteFilesRefused(.fileCountLimitExceeded), limits: limits)
        == "Remote clipboard has more than 20 files.")
    #expect(RDPRemoteSessionClipboard.message(for: .downloadFailed(.totalByteLimitExceeded), limits: limits)
        == "Remote files exceed 8 MiB.")
    let local = RDPRemoteSessionClipboard.message(
        for: .localFilesNotShared(.totalByteLimitExceeded),
        maximumLocalFileByteCount: 4 * 1024 * 1024
    )
    #expect(local == "Local clipboard files exceed 4 MiB; remote clipboard cleared.")
}
