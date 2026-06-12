import Foundation
@testable import RDPKit
import Testing

@Test func preflightCapturesGraphicsFrameFromMockKRDPServer() throws {
    let server = try MockKRDPServer.start()
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        },
        onWireReceive: { sample in
            observed.record(sample)
        }
    )

    #expect(report.status == "success")
    #expect(report.selectedProtocols == ["tls"])
    #expect(report.mcsIOChannelID == 1003)
    #expect(report.mcsMessageChannelID == 1005)
    #expect(report.mcsStaticChannels == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
    ])
    #expect(report.rdpLicensingResponseType == "license-error-valid-client")
    #expect(report.rdpPostConfirmActiveResponseType == "server-synchronize")
    #expect(report.rdpGraphicsChannelName == RDPGFXChannel.name)
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsSelectedCapabilityVersion == RDPGFXCapabilityVersion.version81)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.rdpGraphicsFirstFrame?.videoCodec == .h264)
    #expect(report.rdpGraphicsFirstFrame?.width == 64)
    #expect(report.rdpGraphicsFirstFrame?.height == 32)
    #expect(report.rdpGraphicsFirstFrame?.videoNalUnitTypes == [7, 8, 5])
    #expect(report.rdpGraphicsFirstFrame?.h264NalUnitTypes == [7, 8, 5])
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(observed.wireBytes > 0)
    #expect(report.error == nil)
}

@Test func livePreflightTimesOutWhenGraphicsPipelineStallsBeforeFirstFrame() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .stallAfterCapsConfirm)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
            timeoutSeconds: 1,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsFrames == [])
    #expect(report.rdpGraphicsFrameAcknowledgeHexes == [])
    #expect(report.error == "receive failed: RDP Graphics Update timed out after 1 seconds")
}

@Test func livePreflightTimesOutWhenAcknowledgedGraphicsFrameHasNoImageData() throws {
    let server = try MockKRDPServer.start(graphicsBehavior: .sendEmptyFrameThenStall)
    defer { server.stop() }

    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
            timeoutSeconds: 1,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: nil,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: false
        )
    )

    #expect(report.status == "failure")
    #expect(report.stage == "rdp-graphics-dynamic-channel")
    #expect(report.rdpGraphicsResponseType == "rdpgfx-caps-confirm")
    #expect(report.rdpGraphicsUpdateMessages?.map(\.typeName) == [
        "rdpgfx-create-surface",
        "rdpgfx-start-frame",
        "rdpgfx-end-frame",
    ])
    #expect(report.rdpGraphicsFrames == [])
    #expect(report.rdpGraphicsFrameAcknowledgeHexes?.isEmpty == false)
    #expect(report.error == "receive failed: RDP Graphics Update timed out after 1 seconds")
}

@Test func preflightTransfersRemoteClipboardFileFromMockKRDPServer() throws {
    let remoteFile = RDPClipboardLocalFile(
        fileName: "notes.txt",
        contents: Data("hello from krdp".utf8)
    )
    let server = try MockKRDPServer.start(clipboardFiles: [remoteFile])
    defer { server.stop() }

    let observed = MockKRDPObservedEvents()
    let report = RDPPreflightClient().run(
        configuration: RDPConnectionConfiguration(
            host: "127.0.0.1",
            port: server.port,
            credentials: RDPCredentials(username: "aneesi", password: "secret"),
            timeoutSeconds: 5,
            hideCertificateWarnings: true,
            graphicsFrameCaptureLimit: 1,
            desktopWidth: 1280,
            desktopHeight: 720,
            clipboardEnabled: true
        ),
        onGraphicsFrame: { frame in
            observed.record(frame)
        },
        onClipboardReady: { session in
            observed.record(session)
        },
        onClipboardFileGroupDescriptor: { descriptor in
            observed.record(descriptor)
            guard let session = observed.clipboardSession else {
                observed.recordClipboardError("clipboard session was not ready")
                return
            }
            do {
                try session.requestRemoteFileSize(streamID: 1, fileIndex: 0)
            } catch {
                observed.recordClipboardError(String(describing: error))
            }
        },
        onClipboardFileContents: { response in
            if response.streamID == 1 {
                do {
                    let size = try response.decodedFileSize()
                    observed.recordRemoteFileSize(size)
                    guard let byteCount = UInt32(exactly: size) else {
                        observed.recordClipboardError("remote file size exceeded UInt32")
                        return
                    }
                    guard let session = observed.clipboardSession else {
                        observed.recordClipboardError("clipboard session was not ready")
                        return
                    }
                    try session.requestRemoteFileRange(
                        streamID: 2,
                        fileIndex: 0,
                        position: 0,
                        requestedByteCount: byteCount
                    )
                } catch {
                    observed.recordClipboardError(String(describing: error))
                }
            } else if response.streamID == 2 {
                observed.recordRemoteFileData(response.data)
            }
        },
        onWireReceive: { sample in
            observed.record(sample)
        }
    )

    #expect(report.status == "success")
    #expect(report.mcsStaticChannels == [
        RDPStaticVirtualChannelAssignment(name: "drdynvc", channelID: 1004),
        RDPStaticVirtualChannelAssignment(name: "cliprdr", channelID: 1007),
    ])
    #expect(report.rdpClipboardChannelID == 1007)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-monitor-ready") == true)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-format-list") == true)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-format-data-response") == true)
    #expect(report.rdpClipboardMessages?.map(\.typeName).contains("clipboard-file-contents-response") == true)
    #expect(observed.clipboardErrors.isEmpty)
    #expect(observed.fileDescriptor == RDPClipboardFileGroupDescriptorW(descriptors: [remoteFile.descriptor]))
    #expect(observed.remoteFileSize == UInt64(remoteFile.contents.count))
    #expect(observed.remoteFileData == remoteFile.contents)
    #expect(observed.frames == report.rdpGraphicsFrames)
    #expect(report.rdpGraphicsFirstFrame?.codecName == "avc420")
    #expect(report.error == nil)
}

private final class MockKRDPObservedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFrames: [RDPGraphicsFrameSnapshot] = []
    private var recordedWireBytes = 0
    private var recordedClipboardSession: RDPClipboardSession?
    private var recordedFileDescriptor: RDPClipboardFileGroupDescriptorW?
    private var recordedRemoteFileSize: UInt64?
    private var recordedRemoteFileData: Data?
    private var recordedClipboardErrors: [String] = []

    var frames: [RDPGraphicsFrameSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFrames
    }

    var wireBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedWireBytes
    }

    var clipboardSession: RDPClipboardSession? {
        lock.lock()
        defer { lock.unlock() }
        return recordedClipboardSession
    }

    var fileDescriptor: RDPClipboardFileGroupDescriptorW? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFileDescriptor
    }

    var remoteFileSize: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRemoteFileSize
    }

    var remoteFileData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRemoteFileData
    }

    var clipboardErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedClipboardErrors
    }

    func record(_ frame: RDPGraphicsFrameSnapshot) {
        lock.lock()
        recordedFrames.append(frame)
        lock.unlock()
    }

    func record(_ sample: RDPWireReceiveSample) {
        lock.lock()
        recordedWireBytes += sample.byteCount
        lock.unlock()
    }

    func record(_ session: RDPClipboardSession) {
        lock.lock()
        recordedClipboardSession = session
        lock.unlock()
    }

    func record(_ descriptor: RDPClipboardFileGroupDescriptorW) {
        lock.lock()
        recordedFileDescriptor = descriptor
        lock.unlock()
    }

    func recordRemoteFileSize(_ size: UInt64) {
        lock.lock()
        recordedRemoteFileSize = size
        lock.unlock()
    }

    func recordRemoteFileData(_ data: Data) {
        lock.lock()
        recordedRemoteFileData = data
        lock.unlock()
    }

    func recordClipboardError(_ error: String) {
        lock.lock()
        recordedClipboardErrors.append(error)
        lock.unlock()
    }
}
