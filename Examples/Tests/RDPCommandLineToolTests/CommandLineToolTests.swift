import RDPCommandLineSupport
@testable import RDPFirstFrameCapture
import RDPKit
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
