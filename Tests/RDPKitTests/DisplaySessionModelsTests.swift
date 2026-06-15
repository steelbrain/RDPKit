import Foundation
@testable import RDPKit
import Testing

@Test func displayScaleFactorsMapBackingScaleToRDPScaleFactors() {
    #expect(RDPDisplayScaleFactors(backingScaleFactor: 1).desktopScaleFactor == 100)
    #expect(RDPDisplayScaleFactors(backingScaleFactor: 1).deviceScaleFactor == 100)

    #expect(RDPDisplayScaleFactors(backingScaleFactor: 1.5).desktopScaleFactor == 150)
    #expect(RDPDisplayScaleFactors(backingScaleFactor: 1.5).deviceScaleFactor == 140)

    #expect(RDPDisplayScaleFactors(backingScaleFactor: 2).desktopScaleFactor == 200)
    #expect(RDPDisplayScaleFactors(backingScaleFactor: 2).deviceScaleFactor == 180)
}

@Test func displayRequestNormalizesProtocolLayout() {
    let request = RDPDisplayRequest(
        width: 641,
        height: 199,
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 99, deviceScaleFactor: 999)
    )

    #expect(request.width == 640)
    #expect(request.height == 200)
    #expect(request.scaleFactors.desktopScaleFactor == 100)
    #expect(request.scaleFactors.deviceScaleFactor == 180)
    #expect(request.monitorLayoutPDU.monitors.first?.width == 640)
    #expect(request.monitorLayoutPDU.monitors.first?.height == 200)
}

@Test func displayRequestMapsViewportPointSizeToProtocolPixels() {
    let request = RDPDisplayRequest(
        pointSize: CGSize(width: 960.5, height: 540),
        backingScaleFactor: 2
    )

    #expect(request.width == 1920)
    #expect(request.height == 1080)
    #expect(request.scaleFactors.desktopScaleFactor == 200)
    #expect(request.scaleFactors.deviceScaleFactor == 180)
}

@Test func displayRequestClampsViewportPixelSizeToProtocolRange() {
    let minimumRequest = RDPDisplayRequest(
        pointSize: CGSize(width: 10, height: 10),
        backingScaleFactor: 1
    )
    let maximumRequest = RDPDisplayRequest(
        pointSize: CGSize(width: 10000, height: 10000),
        backingScaleFactor: 2
    )

    #expect(minimumRequest.width == 640)
    #expect(minimumRequest.height == 480)
    #expect(maximumRequest.width == 8192)
    #expect(maximumRequest.height == 8192)
}

@Test func displayRequestDefaultsInvalidViewportScaleToOne() {
    let request = RDPDisplayRequest(
        pointSize: CGSize(width: 800, height: 600),
        backingScaleFactor: -1
    )

    #expect(request.width == 800)
    #expect(request.height == 600)
    #expect(request.scaleFactors.desktopScaleFactor == 100)
    #expect(request.scaleFactors.deviceScaleFactor == 100)
}

@Test func viewerPixelSizeCarriesDisplayRequestAndLabels() {
    let size = RDPViewerPixelSize(
        pointSize: CGSize(width: 960.5, height: 540),
        backingScaleFactor: 2
    )

    #expect(size.width == 1920)
    #expect(size.height == 1080)
    #expect(size.backingScaleFactor == 2)
    #expect(size.desktopWidthText == "1920")
    #expect(size.desktopHeightText == "1080")
    #expect(size.displayScaleFactors.desktopScaleFactor == 200)
    #expect(size.displayScaleFactors.deviceScaleFactor == 180)
    #expect(size.displayRequest == RDPDisplayRequest(
        width: 1920,
        height: 1080,
        scaleFactors: RDPDisplayScaleFactors(desktopScaleFactor: 200, deviceScaleFactor: 180)
    ))
    #expect(size.label == "1920x1080 view @2.0x, RDP scale 200%/180%")
}

@Test func framePacingStateNormalizesDisplayLinkTiming() {
    let state = RDPFramePacingState(
        screenName: "Studio Display",
        backingScaleFactor: 2,
        maximumFramesPerSecond: nil,
        minimumRefreshInterval: 1.0 / 120.0,
        maximumRefreshInterval: 1.0 / 48.0,
        displayUpdateGranularity: 0,
        displayLinkDuration: 0.0167,
        hasDisplayLink: true,
        isDisplayLinkPaused: false
    )

    #expect(state.displayLinkDuration == 1.0 / 60.0)
    #expect(state.displayLinkFramesPerSecond == 60)
    #expect(state.maximumRefreshRate == 120)
    #expect(state.clockState == "window display link")
}

@Test func framePacingStateMarksUpdatedDisplayLinkActive() {
    let state = RDPFramePacingState().updatingDisplayLinkDuration(1.0 / 120.0)

    #expect(state.hasDisplayLink)
    #expect(state.isDisplayLinkPaused == false)
    #expect(state.displayLinkFramesPerSecond == 120)
    #expect(state.clockState == "window display link")
}

@Test func frameMetadataCopiesReusableFrameSummary() {
    let frame = RDPGraphicsFrameSnapshot(
        frameID: 9,
        surfaceID: 3,
        codecID: RDPGFXCodecID.avc420,
        codecName: "avc420",
        pixelFormat: 32,
        destinationRect: RDPFrameRect(left: 0, top: 0, right: 1920, bottom: 1080),
        regionRects: [
            RDPFrameRect(left: 0, top: 0, right: 960, bottom: 1080),
            RDPFrameRect(left: 960, top: 0, right: 1920, bottom: 1080),
        ],
        encodedVideoData: Data([0x00, 0x00, 0x01, 0x65])
    )

    let metadata = RDPFrameMetadata(frame)

    #expect(metadata.frameID == 9)
    #expect(metadata.surfaceID == 3)
    #expect(metadata.codecName == "avc420")
    #expect(metadata.videoCodec == .h264)
    #expect(metadata.width == 1920)
    #expect(metadata.height == 1080)
    #expect(metadata.videoByteCount == 4)
    #expect(metadata.payloadByteCount == 4)
    #expect(metadata.regionCount == 2)
}
