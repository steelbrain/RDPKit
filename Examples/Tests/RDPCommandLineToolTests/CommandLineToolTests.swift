import Foundation
import RDPCommandLineSupport
@testable import RDPFirstFrameCapture
@testable import RDPFrameBenchmark
import RDPKit
@testable import RDPPreflight
import Testing

@Test func connectionOptionsParseSharedFlagsAndLeaveToolFlags() throws {
    var cursor = RDPCommandLineArguments([
        "tool", "--host", "server", "--port", "3390", "--graphics-profile", "avc420", "--json",
    ])
    var options = RDPCommandLineConnectionOptions()
    var toolOptions: [String] = []
    while let option = cursor.nextOption() {
        if try options.parse(option, from: &cursor) == false {
            toolOptions.append(option)
        }
    }

    #expect(try options.requiredHost() == "server")
    #expect(options.port == 3390)
    #expect(options.graphicsCapabilityProfile == .avc420)
    #expect(toolOptions == ["--json"])
}

@Test func connectionOptionsReadPasswordFromEnvironment() throws {
    var options = RDPCommandLineConnectionOptions()
    #expect(try options.credentials(environment: [:]) == nil)

    options.username = "user"
    #expect(throws: RDPCommandLineError.missingCredential("--password-env is required when credentials are provided")) {
        try options.credentials(environment: [:])
    }

    options.passwordEnv = "RDP_PASSWORD"
    #expect(throws: RDPCommandLineError.missingPasswordEnv("RDP_PASSWORD")) {
        try options.credentials(environment: [:])
    }
    #expect(try options.credentials(environment: ["RDP_PASSWORD": "secret"])?.username == "user")
}

@Test func firstFrameCaptureWaitsThirtySecondsByDefault() throws {
    let options = try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture"])

    #expect(options.settleSeconds == 30)
    #expect(options.connection.timeoutSeconds == 30)
}

@Test func firstFrameCaptureRunsUntilTheSettleWindowEnds() throws {
    let options = try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--host", "server"])

    // A frame limit would end the session before the settle window on a busy desktop.
    #expect(try options.configuration(environment: [:]).graphicsFrameCaptureLimit == nil)
}

@Test func firstFrameCaptureExplainsASettleWindowWithoutADecodedFrame() {
    // The settle window cancels the session, so the report's error is only "cancelled".
    var report = RDPSessionClient().dryRun(configuration: RDPConnectionConfiguration(host: "server"))
    report.status = "failure"
    report.stage = "rdp-graphics-dynamic-channel"
    report.error = "cancelled"

    let error = FirstFrameCaptureError.noDecodedFrame(report: report, lastDecodeFailure: "bad frame", settleSeconds: 30)

    #expect(error.description == "no frame decoded within --settle-seconds 30 "
        + "(stopped at rdp-graphics-dynamic-channel); last decode failure: bad frame")
}

@Test func firstFrameCaptureCanOverrideSettleWindow() throws {
    let options = try FirstFrameCaptureOptions.parse([
        "RDPFirstFrameCapture",
        "--settle-seconds", "45",
    ])

    #expect(options.settleSeconds == 45)
}

@Test func firstFrameCaptureCanRequestExplicitDesktopGeometry() throws {
    let options = try FirstFrameCaptureOptions.parse([
        "RDPFirstFrameCapture",
        "--desktop-width", "3456",
        "--desktop-height", "1908",
    ])

    #expect(options.connection.desktopWidth == 3456)
    #expect(options.connection.desktopHeight == 1908)
}

@Test func firstFrameCaptureRejectsDesktopGeometryOutsideProtocolLimits() {
    #expect(throws: RDPCommandLineError.invalidValue(option: "--desktop-width", value: "639", expected: "640...8192")) {
        try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--desktop-width", "639"])
    }
    #expect(throws: RDPCommandLineError.invalidValue(option: "--desktop-height", value: "8193", expected: "480...8192")) {
        try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--desktop-height", "8193"])
    }
}

@Test func frameBenchmarkParsesSizes() throws {
    let args = try RDPFrameBenchmark.parseArguments([
        "RDPFrameBenchmark", "--desktop-size", "1920x1080", "--display-resize", "2768X1492",
    ])

    #expect(args.connection.desktopWidth == 1920)
    #expect(args.connection.desktopHeight == 1080)
    #expect(args.displayResize?.width == 2768)
    #expect(args.displayResize?.height == 1492)
}

@Test func frameBenchmarkRejectsSizesOutsideProtocolLimits() {
    // RDPConnectionConfiguration would otherwise clamp 320x200 to 640x480 without a word.
    #expect(throws: RDPCommandLineError.invalidValue(
        option: "--desktop-size",
        value: "320x200",
        expected: "<width>x<height> within 640...8192 x 480...8192"
    )) {
        try RDPFrameBenchmark.parseArguments(["RDPFrameBenchmark", "--desktop-size", "320x200"])
    }
    #expect(throws: RDPCommandLineError.invalidValue(
        option: "--display-resize",
        value: "100x100",
        expected: "<width>x<height> within 200...8192 x 200...8192"
    )) {
        try RDPFrameBenchmark.parseArguments(["RDPFrameBenchmark", "--display-resize", "100x100"])
    }
}

@Test func frameBenchmarkReportsWhyAProfileFailed() {
    var report = RDPSessionClient().dryRun(configuration: RDPConnectionConfiguration(host: "server"))
    report.status = "failure"
    report.error = "connection refused"

    let failed = RDPFrameBenchmark.captureOutcome(capturedFrameCount: 0, requestedFrameCount: 10, report: report)

    #expect(failed.status == "failure")
    #expect(failed.error == "captured 0 of 10 requested frames: connection refused")

    report.error = "cancelled"
    let stoppedAfterCapture = RDPFrameBenchmark.captureOutcome(
        capturedFrameCount: 10,
        requestedFrameCount: 10,
        report: report
    )
    #expect(stoppedAfterCapture.status == "success")
    #expect(stoppedAfterCapture.error == nil)

    report.status = "success"
    report.error = nil
    let ended = RDPFrameBenchmark.captureOutcome(capturedFrameCount: 3, requestedFrameCount: 10, report: report)
    #expect(ended.status == "incomplete")
    #expect(ended.error == "captured 3 of 10 requested frames")
}

@Test func frameBenchmarkPeakMemoryIsNeverBelowItsSamples() {
    let start = ProcessSample(wallTime: Date(timeIntervalSince1970: 0), cpuTimeSeconds: 0, residentMemoryBytes: 1000)
    let end = ProcessSample(wallTime: Date(timeIntervalSince1970: 1), cpuTimeSeconds: 0, residentMemoryBytes: 3000)

    // The running peak began before `start` and saw nothing in between, as for a refused connection.
    let delta = measurementDelta(start: start, end: end, peakResidentMemoryBytes: 800)

    #expect(delta.residentMemoryDeltaBytes == 2000)
    #expect(delta.residentMemoryPeakDeltaBytes == 2000)
}

@Test func frameBenchmarkReportsDecodeStagesOnlyForTheStrategyThatTimesThem() {
    let rect = RDPFrameRect(left: 0, top: 0, right: 2, bottom: 2)
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 1,
        surfaceID: 0,
        codecID: 0,
        codecName: "surface-bgra",
        pixelFormat: 32,
        destinationRect: rect,
        regionRects: [rect],
        encodedVideoData: Data(),
        contentKind: .bitmap,
        decodedBitmapData: Data(repeating: 0xFF, count: 16),
        decodedBitmapBytesPerRow: 8
    )

    let pixelBuffer = RDPFrameBenchmark.benchmarkStrategy(.pixelBuffer, frames: [frame])
    let cgImage = RDPFrameBenchmark.benchmarkStrategy(.cgImage, frames: [frame])

    #expect(pixelBuffer.decodedFrameCount == 1)
    #expect(pixelBuffer.samplePreparationAverageMilliseconds != nil)
    #expect(cgImage.decodedFrameCount == 1)
    // decode(_:) does not time its stages, so 0 ms would be a made-up measurement.
    #expect(cgImage.samplePreparationAverageMilliseconds == nil)
    #expect(cgImage.videoToolboxAverageMilliseconds == nil)
    #expect(cgImage.imageConversionAverageMilliseconds == nil)
}

@Test func frameCountsStayWithinWhatASessionCaptures() throws {
    #expect(try parseArguments(["RDPPreflight", "--graphics-frames", "120"]).graphicsFrames == 120)
    #expect(try RDPFrameBenchmark.parseArguments(["RDPFrameBenchmark", "--frames", "120"]).frames == 120)

    // RDPConnectionConfiguration would otherwise clamp the session's frame limit to 120 without a word.
    #expect(throws: RDPCommandLineError.invalidValue(option: "--graphics-frames", value: "121", expected: "1...120")) {
        try parseArguments(["RDPPreflight", "--graphics-frames", "121"])
    }
    #expect(throws: RDPCommandLineError.invalidValue(option: "--frames", value: "500", expected: "1...120")) {
        try RDPFrameBenchmark.parseArguments(["RDPFrameBenchmark", "--frames", "500"])
    }
}

@Test func connectionOptionsRejectPortZero() {
    #expect(throws: RDPCommandLineError.invalidValue(option: "--port", value: "0", expected: "1...65535")) {
        try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--port", "0"])
    }
}

@Test func firstFrameCaptureRejectsNonPositiveSettleWindow() {
    #expect(throws: RDPCommandLineError.invalidValue(
        option: "--settle-seconds",
        value: "0",
        expected: "a positive integer"
    )) {
        try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--settle-seconds", "0"])
    }
}

@Test func firstFrameCaptureRejectsUnknownAndValuelessOptions() {
    #expect(throws: RDPCommandLineError.unknownOption("--frames")) {
        try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--frames", "60"])
    }
    #expect(throws: RDPCommandLineError.missingValue("--output")) {
        try FirstFrameCaptureOptions.parse(["RDPFirstFrameCapture", "--output"])
    }
}

@Test func firstFrameCaptureRecordsLatestDecodedFrameAcrossThreads() async {
    let recorder = LatestDecodedFrameRecorder<Int>()

    await withTaskGroup(of: Void.self) { group in
        for value in 1 ... 60 {
            group.addTask { recorder.recordDecoded(value) }
        }
    }
    recorder.recordFailure("bad frame")

    #expect(recorder.snapshot.decodedFrameCount == 60)
    #expect(recorder.snapshot.latest != nil)
    #expect(recorder.snapshot.lastFailure == "bad frame")
}
