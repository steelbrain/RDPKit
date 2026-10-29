import Foundation
@testable import RDPClient
import RDPKit
import Testing

private final class RecordedClipboard: RDPClipboardSending {
    var publishedTexts: [String?] = []

    func publishLocalUnicodeText(_ text: String?) {
        publishedTexts.append(text)
    }

    func publishLocalFiles(_: [RDPClipboardLocalFile]) {}

    func requestRemoteFileSize(streamID _: UInt32, fileIndex _: Int32) throws {}

    func requestRemoteFileRange(streamID _: UInt32, fileIndex _: Int32, position _: UInt64, requestedByteCount _: UInt32) throws {}
}

@MainActor
@Test func aTemporaryShareEndsOnlySharingItTurnedOn() {
    let clipboard = RDPRemoteSessionClipboard(isSharingEnabled: true)
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
