import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import RDPCommandLineSupport
import RDPKit

private struct BenchmarkArguments {
    var connection = RDPCommandLineConnectionOptions(timeoutSeconds: 60)
    var frames = 10
    var displayResize: BenchmarkDisplaySize?
    var json = false

    /// Every profile unless `--graphics-profile` selected a subset.
    var profiles: [RDPGraphicsCapabilityProfile] {
        connection.graphicsCapabilityProfiles.isEmpty
            ? RDPGraphicsCapabilityProfile.allCases
            : connection.graphicsCapabilityProfiles
    }
}

private struct BenchmarkDisplaySize: Equatable {
    var width: UInt16
    var height: UInt16

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let width = UInt16(parts[0]),
              let height = UInt16(parts[1]),
              width > 0,
              height > 0
        else {
            return nil
        }
        self.width = width
        self.height = height
    }
}

private enum BenchmarkStrategy: String, CaseIterable, Encodable {
    case pixelBuffer
    case cgImage
    case cgImageCrop
}

private struct BenchmarkReport: Encodable {
    var target: String
    var requestedFrames: Int
    var profiles: [ProfileBenchmarkReport]
}

private struct ProfileBenchmarkReport: Encodable {
    var profile: String
    var status: String
    var selectedCapabilityVersion: UInt32?
    var selectedCapabilityFlags: UInt32?
    var firstFrameCodecName: String?
    var firstFrameContentKind: RDPGraphicsFrameContentKind?
    var capturedFrameCount: Int
    var captureWallMilliseconds: Double
    var captureCPUMilliseconds: Double
    var captureResidentMemoryDeltaBytes: Int64
    var captureResidentMemoryPeakDeltaBytes: Int64
    var wireByteCount: Int
    var framePayloadByteCount: Int
    var codecNames: [String]
    var frameReports: [CapturedFrameReport]
    var strategyReports: [StrategyBenchmarkReport]
    var error: String?
}

private struct CapturedFrameReport: Encodable {
    var index: Int
    var frameID: UInt32?
    var codecName: String
    var contentKind: RDPGraphicsFrameContentKind
    var videoCodec: RDPVideoCodec
    var pixelFormat: UInt8
    var destinationRect: RDPFrameRect
    var regionRects: [RDPFrameRect]
    var width: UInt16
    var height: UInt16
    var destinationAreaPixels: Int
    var regionAreaPixels: Int
    var regionCoverage: Double?
    var payloadByteCount: Int
}

private struct StrategyBenchmarkReport: Encodable {
    var strategy: BenchmarkStrategy
    var decodedFrameCount: Int
    var failedFrameCount: Int
    var totalWallMilliseconds: Double
    var averageWallMilliseconds: Double?
    var maxWallMilliseconds: Double?
    var p50WallMilliseconds: Double?
    var p95WallMilliseconds: Double?
    var totalCPUMilliseconds: Double
    var averageCPUMilliseconds: Double?
    var residentMemoryDeltaBytes: Int64
    var residentMemoryPeakDeltaBytes: Int64
    var samplePreparationAverageMilliseconds: Double?
    var videoToolboxAverageMilliseconds: Double?
    var imageConversionAverageMilliseconds: Double?
    var cropAverageMilliseconds: Double?
    var decodedPixelFormats: [UInt32]
    var usesHardwareAcceleration: Bool?
    var outputPixelCount: Int
    var errors: [String]
}

private struct ProcessSample {
    var wallTime: Date
    var cpuTimeSeconds: Double
    var residentMemoryBytes: Int64
}

private struct LiveCapture {
    var report: RDPConnectionReport
    var frames: [RDPGraphicsFrameSnapshot]
    var wireByteCount: Int
    var measurement: MeasurementDelta
}

private final class LiveCaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let frameLimit: Int
    private var capturedFrames: [RDPGraphicsFrameSnapshot] = []
    private var receivedWireBytes = 0
    private var peakResidentMemoryBytes: Int64

    init(frameLimit: Int, initialResidentMemoryBytes: Int64) {
        self.frameLimit = frameLimit
        peakResidentMemoryBytes = initialResidentMemoryBytes
        capturedFrames.reserveCapacity(frameLimit)
    }

    func appendFrame(_ frame: RDPGraphicsFrameSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // A copy among the decoder's surfaces has nothing to decode on its own.
        guard frame.contentKind != .surfaceCopy else {
            return false
        }
        guard capturedFrames.count < frameLimit else {
            return capturedFrames.count >= frameLimit
        }
        capturedFrames.append(frame)
        peakResidentMemoryBytes = max(peakResidentMemoryBytes, currentResidentMemoryBytes())
        return capturedFrames.count >= frameLimit
    }

    func recordWireReceive(byteCount: Int) {
        lock.lock()
        receivedWireBytes += byteCount
        peakResidentMemoryBytes = max(peakResidentMemoryBytes, currentResidentMemoryBytes())
        lock.unlock()
    }

    func snapshot() -> (frames: [RDPGraphicsFrameSnapshot], wireByteCount: Int, peakResidentMemoryBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (capturedFrames, receivedWireBytes, peakResidentMemoryBytes)
    }
}

private struct MeasurementDelta {
    var wallMilliseconds: Double
    var cpuMilliseconds: Double
    var residentMemoryDeltaBytes: Int64
    var residentMemoryPeakDeltaBytes: Int64
}

private struct FrameTiming {
    var wallMilliseconds: Double
    var cpuMilliseconds: Double
}

private enum RDPFrameBenchmark {
    static func main() {
        if RDPCommandLineArguments.requestsHelp(CommandLine.arguments) {
            printUsage()
            exit(0)
        }
        do {
            let args = try parseArguments(CommandLine.arguments)
            let host = try args.connection.requiredHost()
            let credentials = try args.connection.credentials()
            let report = runBenchmark(host: host, credentials: credentials, args: args)

            if args.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                FileHandle.standardOutput.write(data)
                print()
            } else {
                printTextReport(report)
            }
        } catch {
            fputs("\(String(describing: error))\n", stderr)
            printUsage()
            exit(1)
        }
    }

    private static func runBenchmark(
        host: String,
        credentials: RDPCredentials?,
        args: BenchmarkArguments
    ) -> BenchmarkReport {
        let target = "\(host):\(args.connection.port)"
        let reports = args.profiles.map { profile in
            benchmarkProfile(profile, credentials: credentials, args: args)
        }
        return BenchmarkReport(
            target: target,
            requestedFrames: args.frames,
            profiles: reports
        )
    }

    private static func benchmarkProfile(
        _ profile: RDPGraphicsCapabilityProfile,
        credentials: RDPCredentials?,
        args: BenchmarkArguments
    ) -> ProfileBenchmarkReport {
        do {
            let capture = try captureFrames(profile, credentials: credentials, args: args)
            let framePayloadByteCount = capture.frames.reduce(0) { $0 + $1.payloadByteCount }
            let codecNames = Array(Set(capture.frames.map(\.codecName))).sorted()
            let frameReports = makeCapturedFrameReports(capture.frames)
            let strategyReports = BenchmarkStrategy.allCases.map { strategy in
                benchmarkStrategy(strategy, frames: capture.frames)
            }
            let completedRequestedFrames = capture.frames.count >= args.frames
            let stoppedAfterCapture = completedRequestedFrames && capture.report.error == "cancelled"
            let status = completedRequestedFrames
                ? (stoppedAfterCapture ? "success" : capture.report.status)
                : "incomplete"
            let error = completedRequestedFrames
                ? (stoppedAfterCapture ? nil : capture.report.error)
                : "captured \(capture.frames.count) of \(args.frames) requested frames"
            return ProfileBenchmarkReport(
                profile: profile.rawValue,
                status: status,
                selectedCapabilityVersion: capture.report.rdpGraphicsSelectedCapabilityVersion,
                selectedCapabilityFlags: capture.report.rdpGraphicsSelectedCapabilityFlags,
                firstFrameCodecName: capture.report.rdpGraphicsFirstFrame?.codecName,
                firstFrameContentKind: capture.report.rdpGraphicsFirstFrame?.contentKind,
                capturedFrameCount: capture.frames.count,
                captureWallMilliseconds: capture.measurement.wallMilliseconds,
                captureCPUMilliseconds: capture.measurement.cpuMilliseconds,
                captureResidentMemoryDeltaBytes: capture.measurement.residentMemoryDeltaBytes,
                captureResidentMemoryPeakDeltaBytes: capture.measurement.residentMemoryPeakDeltaBytes,
                wireByteCount: capture.wireByteCount,
                framePayloadByteCount: framePayloadByteCount,
                codecNames: codecNames,
                frameReports: frameReports,
                strategyReports: strategyReports,
                error: error
            )
        } catch {
            return ProfileBenchmarkReport(
                profile: profile.rawValue,
                status: "failure",
                selectedCapabilityVersion: nil,
                selectedCapabilityFlags: nil,
                firstFrameCodecName: nil,
                firstFrameContentKind: nil,
                capturedFrameCount: 0,
                captureWallMilliseconds: 0,
                captureCPUMilliseconds: 0,
                captureResidentMemoryDeltaBytes: 0,
                captureResidentMemoryPeakDeltaBytes: 0,
                wireByteCount: 0,
                framePayloadByteCount: 0,
                codecNames: [],
                frameReports: [],
                strategyReports: [],
                error: String(describing: error)
            )
        }
    }

    private static func makeCapturedFrameReports(_ frames: [RDPGraphicsFrameSnapshot]) -> [CapturedFrameReport] {
        frames.enumerated().map { index, frame in
            let destinationArea = rectArea(frame.destinationRect)
            let regionArea = frame.regionRects.reduce(0) { $0 + rectArea($1) }
            return CapturedFrameReport(
                index: index,
                frameID: frame.frameID,
                codecName: frame.codecName,
                contentKind: frame.contentKind,
                videoCodec: frame.videoCodec,
                pixelFormat: frame.pixelFormat,
                destinationRect: frame.destinationRect,
                regionRects: frame.regionRects,
                width: frame.width,
                height: frame.height,
                destinationAreaPixels: destinationArea,
                regionAreaPixels: regionArea,
                regionCoverage: destinationArea > 0 ? Double(regionArea) / Double(destinationArea) : nil,
                payloadByteCount: frame.payloadByteCount
            )
        }
    }

    private static func captureFrames(
        _ profile: RDPGraphicsCapabilityProfile,
        credentials: RDPCredentials?,
        args: BenchmarkArguments
    ) throws -> LiveCapture {
        let cancellation = RDPConnectionCancellation()
        let accumulator = LiveCaptureAccumulator(
            frameLimit: args.frames,
            initialResidentMemoryBytes: currentResidentMemoryBytes()
        )
        let candidateFrameLimit = args.frames + max(3, args.frames)
        let configuration = try args.connection.configuration(
            credentials: credentials,
            graphicsCapabilityProfile: profile,
            graphicsFrameCaptureLimit: candidateFrameLimit,
            clipboardEnabled: false
        )
        let displayResize = args.displayResize
        let start = processSample()
        let report = RDPSessionClient().run(
            configuration: configuration,
            onGraphicsFrame: { frame in
                if accumulator.appendFrame(frame) {
                    cancellation.cancel()
                }
            },
            onDisplayControlReady: { session in
                guard let displayResize else {
                    return
                }
                session.sendSingleMonitorLayout(
                    width: UInt32(displayResize.width),
                    height: UInt32(displayResize.height)
                )
            },
            onWireReceive: { sample in
                accumulator.recordWireReceive(byteCount: sample.byteCount)
            },
            cancellation: cancellation
        )
        let end = processSample()
        let captureSnapshot = accumulator.snapshot()
        let measurement = measurementDelta(
            start: start,
            end: end,
            peakResidentMemoryBytes: captureSnapshot.peakResidentMemoryBytes
        )
        return LiveCapture(
            report: report,
            frames: captureSnapshot.frames,
            wireByteCount: captureSnapshot.wireByteCount,
            measurement: measurement
        )
    }

    private static func benchmarkStrategy(
        _ strategy: BenchmarkStrategy,
        frames: [RDPGraphicsFrameSnapshot]
    ) -> StrategyBenchmarkReport {
        let decoder = RDPVideoToolboxFrameDecoder()
        var frameTimings: [FrameTiming] = []
        var samplePreparationMilliseconds = 0.0
        var videoToolboxMilliseconds = 0.0
        var imageConversionMilliseconds = 0.0
        var cropMilliseconds = 0.0
        var decodedPixelFormats: Set<UInt32> = []
        var usesHardwareAcceleration: Bool?
        var outputPixelCount = 0
        var failedFrameCount = 0
        var errors: [String] = []
        var peakResidentMemoryBytes = currentResidentMemoryBytes()
        let start = processSample()

        for frame in frames {
            autoreleasepool {
                let frameStart = processSample()
                do {
                    switch strategy {
                    case .pixelBuffer:
                        let detailed = try decoder.decodeDetailed(frame)
                        samplePreparationMilliseconds += detailed.samplePreparationMilliseconds
                        videoToolboxMilliseconds += detailed.videoToolboxMilliseconds
                        imageConversionMilliseconds += detailed.imageConversionMilliseconds
                        decodedPixelFormats.insert(detailed.decodedPixelFormat)
                        if usesHardwareAcceleration == nil {
                            usesHardwareAcceleration = detailed.usesHardwareAcceleration
                        }
                        outputPixelCount += CVPixelBufferGetWidth(detailed.imageBuffer)
                            * CVPixelBufferGetHeight(detailed.imageBuffer)
                    case .cgImage:
                        let image = try decoder.decode(frame)
                        outputPixelCount += image.width * image.height
                    case .cgImageCrop:
                        let image = try decoder.decode(frame)
                        let cropStart = Date()
                        let cropped = try cropToDestinationRect(image, frame: frame)
                        cropMilliseconds += Date().timeIntervalSince(cropStart) * 1000
                        outputPixelCount += cropped.width * cropped.height
                    }

                    let frameEnd = processSample()
                    frameTimings.append(frameTiming(start: frameStart, end: frameEnd))
                    peakResidentMemoryBytes = max(peakResidentMemoryBytes, frameEnd.residentMemoryBytes)
                } catch {
                    failedFrameCount += 1
                    if errors.count < 5 {
                        errors.append(String(describing: error))
                    }
                    let frameEnd = processSample()
                    frameTimings.append(frameTiming(start: frameStart, end: frameEnd))
                    peakResidentMemoryBytes = max(peakResidentMemoryBytes, frameEnd.residentMemoryBytes)
                }
            }
        }

        let end = processSample()
        let measurement = measurementDelta(start: start, end: end, peakResidentMemoryBytes: peakResidentMemoryBytes)
        let wallTimes = frameTimings.map(\.wallMilliseconds)
        let decodedFrameCount = frames.count - failedFrameCount
        return StrategyBenchmarkReport(
            strategy: strategy,
            decodedFrameCount: decodedFrameCount,
            failedFrameCount: failedFrameCount,
            totalWallMilliseconds: measurement.wallMilliseconds,
            averageWallMilliseconds: average(wallTimes),
            maxWallMilliseconds: wallTimes.max(),
            p50WallMilliseconds: percentile(wallTimes, percentile: 0.50),
            p95WallMilliseconds: percentile(wallTimes, percentile: 0.95),
            totalCPUMilliseconds: measurement.cpuMilliseconds,
            averageCPUMilliseconds: frameTimings.isEmpty ? nil : measurement.cpuMilliseconds / Double(frameTimings.count),
            residentMemoryDeltaBytes: measurement.residentMemoryDeltaBytes,
            residentMemoryPeakDeltaBytes: measurement.residentMemoryPeakDeltaBytes,
            samplePreparationAverageMilliseconds: averageComponent(samplePreparationMilliseconds, decodedFrameCount),
            videoToolboxAverageMilliseconds: averageComponent(videoToolboxMilliseconds, decodedFrameCount),
            imageConversionAverageMilliseconds: averageComponent(imageConversionMilliseconds, decodedFrameCount),
            cropAverageMilliseconds: averageComponent(cropMilliseconds, decodedFrameCount),
            decodedPixelFormats: Array(decodedPixelFormats).sorted(),
            usesHardwareAcceleration: usesHardwareAcceleration,
            outputPixelCount: outputPixelCount,
            errors: errors
        )
    }

    private static func printTextReport(_ report: BenchmarkReport) {
        print("target: \(report.target)")
        print("requested frames: \(report.requestedFrames)")
        for profile in report.profiles {
            print("")
            print("""
            profile \(profile.profile): \(profile.status) \
            frames=\(profile.capturedFrameCount) \
            selected=\(profile.selectedCapabilityVersion.map(String.init) ?? "none") \
            flags=\(profile.selectedCapabilityFlags.map { String(format: "0x%08x", $0) } ?? "none") \
            first=\(profile.firstFrameCodecName ?? "none")/\(profile.firstFrameContentKind?.rawValue ?? "none")
            """)
            print("""
              capture wall=\(format(profile.captureWallMilliseconds))ms \
              cpu=\(format(profile.captureCPUMilliseconds))ms \
              rssΔ=\(formatBytes(profile.captureResidentMemoryDeltaBytes)) \
              rssPeakΔ=\(formatBytes(profile.captureResidentMemoryPeakDeltaBytes)) \
              wire=\(profile.wireByteCount)B payload=\(profile.framePayloadByteCount)B
            """)
            if let error = profile.error {
                print("  error: \(error)")
            }
            if !profile.frameReports.isEmpty {
                let coverages = profile.frameReports.compactMap(\.regionCoverage)
                print("""
              frame coverage avg=\(format(average(coverages))) \
              min=\(format(coverages.min())) \
              max=\(format(coverages.max()))
            """)
            }
            for strategy in profile.strategyReports {
                print("""
              \(strategy.strategy.rawValue): \
              frames=\(strategy.decodedFrameCount) failed=\(strategy.failedFrameCount) \
              wall avg=\(format(strategy.averageWallMilliseconds))ms \
              p50=\(format(strategy.p50WallMilliseconds))ms \
              p95=\(format(strategy.p95WallMilliseconds))ms \
              max=\(format(strategy.maxWallMilliseconds))ms \
              cpu avg=\(format(strategy.averageCPUMilliseconds))ms \
              sample=\(format(strategy.samplePreparationAverageMilliseconds))ms \
              vt=\(format(strategy.videoToolboxAverageMilliseconds))ms \
              image=\(format(strategy.imageConversionAverageMilliseconds))ms \
              crop=\(format(strategy.cropAverageMilliseconds))ms \
              rssΔ=\(formatBytes(strategy.residentMemoryDeltaBytes)) \
              rssPeakΔ=\(formatBytes(strategy.residentMemoryPeakDeltaBytes)) \
              hw=\(strategy.usesHardwareAcceleration.map(String.init) ?? "n/a")
            """)
                if !strategy.errors.isEmpty {
                    print("                errors=\(strategy.errors.joined(separator: " | "))")
                }
            }
        }
    }

    private static func parseArguments(_ values: [String]) throws -> BenchmarkArguments {
        var args = BenchmarkArguments()
        var cursor = RDPCommandLineArguments(values)
        while let option = cursor.nextOption() {
            if try args.connection.parse(option, from: &cursor) {
                continue
            }
            switch option {
            case "--frames":
                args.frames = try cursor.positiveInteger(for: option)
            case "--desktop-size":
                let size = try cursor.value(for: option, expected: "<width>x<height>", BenchmarkDisplaySize.init)
                args.connection.desktopWidth = size.width
                args.connection.desktopHeight = size.height
            case "--display-resize":
                args.displayResize = try cursor.value(for: option, expected: "<width>x<height>", BenchmarkDisplaySize.init)
            case "--json":
                args.json = true
            default:
                throw RDPCommandLineError.unknownOption(option)
            }
        }
        return args
    }
}

private func processSample() -> ProcessSample {
    ProcessSample(
        wallTime: Date(),
        cpuTimeSeconds: processCPUTimeSeconds(),
        residentMemoryBytes: currentResidentMemoryBytes()
    )
}

private func processCPUTimeSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return timeValueSeconds(usage.ru_utime) + timeValueSeconds(usage.ru_stime)
}

private func timeValueSeconds(_ value: timeval) -> Double {
    Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
}

private func currentResidentMemoryBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                rebound,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    return Int64(info.resident_size)
}

private func measurementDelta(
    start: ProcessSample,
    end: ProcessSample,
    peakResidentMemoryBytes: Int64
) -> MeasurementDelta {
    MeasurementDelta(
        wallMilliseconds: end.wallTime.timeIntervalSince(start.wallTime) * 1000,
        cpuMilliseconds: max(0, end.cpuTimeSeconds - start.cpuTimeSeconds) * 1000,
        residentMemoryDeltaBytes: end.residentMemoryBytes - start.residentMemoryBytes,
        residentMemoryPeakDeltaBytes: peakResidentMemoryBytes - start.residentMemoryBytes
    )
}

private func frameTiming(start: ProcessSample, end: ProcessSample) -> FrameTiming {
    FrameTiming(
        wallMilliseconds: end.wallTime.timeIntervalSince(start.wallTime) * 1000,
        cpuMilliseconds: max(0, end.cpuTimeSeconds - start.cpuTimeSeconds) * 1000
    )
}

/// Crops a decoded image to the frame's size, as a client that cannot present
/// a padded decoder buffer must.
private func cropToDestinationRect(_ image: CGImage, frame: RDPGraphicsFrameSnapshot) throws -> CGImage {
    let width = Int(frame.width)
    let height = Int(frame.height)
    guard width > 0, height > 0, image.width >= width, image.height >= height,
          image.width != width || image.height != height
    else {
        return image
    }
    guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
        throw BenchmarkCropError(sourceWidth: image.width, sourceHeight: image.height, width: width, height: height)
    }
    return cropped
}

private struct BenchmarkCropError: Error, CustomStringConvertible {
    var sourceWidth: Int
    var sourceHeight: Int
    var width: Int
    var height: Int

    var description: String {
        "CoreGraphics could not crop decoded frame from \(sourceWidth)x\(sourceHeight) to \(width)x\(height)."
    }
}

private func rectArea(_ rect: RDPFrameRect) -> Int {
    Int(rect.width) * Int(rect.height)
}

private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else {
        return nil
    }
    return values.reduce(0, +) / Double(values.count)
}

private func averageComponent(_ value: Double, _ count: Int) -> Double? {
    guard count > 0 else {
        return nil
    }
    return value / Double(count)
}

private func percentile(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty else {
        return nil
    }
    let sorted = values.sorted()
    let clamped = min(1, max(0, percentile))
    let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
    return sorted[index]
}

private func format(_ value: Double?) -> String {
    guard let value else {
        return "n/a"
    }
    return String(format: "%.3f", value)
}

private func formatBytes(_ value: Int64) -> String {
    let sign = value < 0 ? "-" : ""
    let bytes = Double(abs(value))
    if bytes >= 1_048_576 {
        return "\(sign)\(String(format: "%.2f", bytes / 1_048_576))MiB"
    }
    if bytes >= 1024 {
        return "\(sign)\(String(format: "%.2f", bytes / 1024))KiB"
    }
    return "\(value)B"
}

private func printUsage() {
    print("""
    Usage: RDPFrameBenchmark --host <host> [--port 3389] [--username <name>] [--domain <domain>] [--password-env <env>] [--timeout-seconds 60] [--frames 10] [--desktop-size 1920x1080] [--display-resize 2768x1492] [--graphics-profile automatic|avcThinClient|avc420|legacy] [--hide-certificate-warnings] [--json]

    Captures live RDPGFX frames and replays them through pixelBuffer, cgImage, and cgImageCrop decode strategies.
    Pass --graphics-profile multiple times to benchmark a subset; default is all profiles.
    """)
}

RDPFrameBenchmark.main()
