import RDPFirstFrameCaptureSupport
import RDPKit
import Testing

@Test func firstFrameCaptureWaitsThirtySecondsByDefault() throws {
    let args = try RDPFirstFrameCaptureArgumentParser.parse(["RDPFirstFrameCapture"])

    #expect(args.settleSeconds == 30)
}

@Test func firstFrameCaptureCanOverrideSettleWindowWithoutFrameOrdinal() throws {
    let args = try RDPFirstFrameCaptureArgumentParser.parse([
        "RDPFirstFrameCapture",
        "--settle-seconds", "45",
    ])

    #expect(args.settleSeconds == 45)
}

@Test func firstFrameCaptureCanRequestExplicitDesktopGeometry() throws {
    let args = try RDPFirstFrameCaptureArgumentParser.parse([
        "RDPFirstFrameCapture",
        "--desktop-width", "3456",
        "--desktop-height", "1908",
    ])

    #expect(args.desktopWidth == 3456)
    #expect(args.desktopHeight == 1908)
}

@Test func firstFrameCaptureRejectsDesktopGeometryOutsideProtocolLimits() {
    #expect(throws: RDPFirstFrameCaptureError.invalidDesktopWidth("639")) {
        try RDPFirstFrameCaptureArgumentParser.parse([
            "RDPFirstFrameCapture",
            "--desktop-width", "639",
        ])
    }
    #expect(throws: RDPFirstFrameCaptureError.invalidDesktopHeight("8193")) {
        try RDPFirstFrameCaptureArgumentParser.parse([
            "RDPFirstFrameCapture",
            "--desktop-height", "8193",
        ])
    }
}

@Test func firstFrameCaptureRejectsNonPositiveSettleWindow() {
    #expect(throws: RDPFirstFrameCaptureError.invalidSettle("0")) {
        try RDPFirstFrameCaptureArgumentParser.parse([
            "RDPFirstFrameCapture",
            "--settle-seconds", "0",
        ])
    }
}

@Test func firstFrameCaptureRejectsFrameOrdinalCaptureOptions() {
    #expect(throws: RDPFirstFrameCaptureError.missingValue("unknown option --start-frame")) {
        try RDPFirstFrameCaptureArgumentParser.parse([
            "RDPFirstFrameCapture",
            "--start-frame", "60",
        ])
    }

    #expect(throws: RDPFirstFrameCaptureError.missingValue("unknown option --frames")) {
        try RDPFirstFrameCaptureArgumentParser.parse([
            "RDPFirstFrameCapture",
            "--frames", "60",
        ])
    }
}

@Test func firstFrameCaptureAllowsFramesBeyondFormerOrdinalCapturePoint() {
    #expect(RDPFirstFrameCaptureError.maximumFrameCaptureLimit == 120)
}

@Test func firstFrameCaptureSelectsLatestDecodedFrameAfterSettleWindow() {
    var capture = RDPLatestCapture<Int>()

    capture.record(1)
    capture.record(30)
    capture.record(60)

    #expect(capture.decodedFrameCount == 3)
    #expect(capture.latest == 60)
}
