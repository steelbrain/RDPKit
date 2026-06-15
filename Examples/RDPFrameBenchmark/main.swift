import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import RDPKit

private struct BenchmarkArguments {
    var host: String?
    var port: UInt16 = 3389
    var username: String?
    var domain: String?
    var passwordEnv: String?
    var timeoutSeconds = 60
    var frames = 10
    var desktopSize: BenchmarkDisplaySize?
    var displayResize: BenchmarkDisplaySize?
    var profiles: [RDPGraphicsCapabilityProfile] = RDPGraphicsCapabilityProfile.allCases
    var hideCertificateWarnings = false
    var json = false
}

private struct BenchmarkDisplaySize: Equatable {
    var width: UInt16
    var height: UInt16
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

private enum BenchmarkError: Error, CustomStringConvertible {
    case missingValue(String)
    case missingHost
    case missingCredential(String)
    case missingPasswordEnv(String)
    case invalidPort(String)
    case invalidTimeout(String)
    case invalidFrames(String)
    case invalidDisplaySize(String)
    case invalidGraphicsProfile(String)

    var description: String {
        switch self {
        case let .missingValue(option):
            "missing value for \(option)"
        case .missingHost:
            "missing required --host"
        case let .missingCredential(message):
            message
        case let .missingPasswordEnv(name):
            "password environment variable \(name) is not set or is empty"
        case let .invalidPort(value):
            "invalid --port \(value)"
        case let .invalidTimeout(value):
            "invalid --timeout-seconds \(value)"
        case let .invalidFrames(value):
            "invalid --frames \(value)"
        case let .invalidDisplaySize(value):
            "invalid display size \(value)"
        case let .invalidGraphicsProfile(value):
            "invalid --graphics-profile \(value)"
        }
    }
}

private struct ProcessSample {
    var wallTime: Date
    var cpuTimeSeconds: Double
    var residentMemoryBytes: Int64
}

private struct LiveCapture {
    var report: RDPPreflightReport
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
        do {
            let args = try parseArguments(CommandLine.arguments)
            let host = try requiredHost(args)
            let credentials = try loadCredentials(from: args)
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
        let target = "\(host):\(args.port)"
        let reports = args.profiles.map { profile in
            benchmarkProfile(
                profile,
                host: host,
                credentials: credentials,
                args: args
            )
        }
        return BenchmarkReport(
            target: target,
            requestedFrames: args.frames,
            profiles: reports
        )
    }

    private static func benchmarkProfile(
        _ profile: RDPGraphicsCapabilityProfile,
        host: String,
        credentials: RDPCredentials?,
        args: BenchmarkArguments
    ) -> ProfileBenchmarkReport {
        do {
            let capture = try captureFrames(
                profile,
                host: host,
                credentials: credentials,
                args: args
            )
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
        host: String,
        credentials: RDPCredentials?,
        args: BenchmarkArguments
    ) throws -> LiveCapture {
        let cancellation = RDPConnectionCancellation()
        let accumulator = LiveCaptureAccumulator(
            frameLimit: args.frames,
            initialResidentMemoryBytes: currentResidentMemoryBytes()
        )
        let candidateFrameLimit = args.frames + max(3, args.frames)
        let start = processSample()
        let report = RDPPreflightClient().run(
            configuration: RDPConnectionConfiguration(
                host: host,
                port: args.port,
                credentials: credentials,
                timeoutSeconds: args.timeoutSeconds,
                hideCertificateWarnings: args.hideCertificateWarnings,
                graphicsFrameCaptureLimit: candidateFrameLimit,
                desktopWidth: args.desktopSize?.width ?? 1280,
                desktopHeight: args.desktopSize?.height ?? 720,
                clipboardEnabled: false,
                graphicsCapabilityProfile: profile
            ),
            onGraphicsFrame: { frame in
                if accumulator.appendFrame(frame) {
                    cancellation.cancel()
                }
            },
            onDisplayControlReady: { session in
                guard let displayResize = args.displayResize else {
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
                        let cropped = try RDPH264DecodedFrameImage.cropToDestinationRect(image, frame: frame)
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
        var index = 1
        var explicitProfiles: [RDPGraphicsCapabilityProfile] = []

        while index < values.count {
            let value = values[index]
            switch value {
            case "--host":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                args.host = values[index]
            case "--port":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                guard let port = UInt16(values[index]) else { throw BenchmarkError.invalidPort(values[index]) }
                args.port = port
            case "--username":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                args.username = values[index]
            case "--domain":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                args.domain = values[index]
            case "--password-env":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                args.passwordEnv = values[index]
            case "--timeout-seconds":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                guard let timeout = Int(values[index]), timeout > 0 else {
                    throw BenchmarkError.invalidTimeout(values[index])
                }
                args.timeoutSeconds = timeout
            case "--frames":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                guard let frames = Int(values[index]), frames > 0 else {
                    throw BenchmarkError.invalidFrames(values[index])
                }
                args.frames = frames
            case "--desktop-size":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                guard let size = parseDisplaySize(values[index]) else {
                    throw BenchmarkError.invalidDisplaySize(values[index])
                }
                args.desktopSize = size
            case "--display-resize":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                guard let size = parseDisplaySize(values[index]) else {
                    throw BenchmarkError.invalidDisplaySize(values[index])
                }
                args.displayResize = size
            case "--graphics-profile":
                index += 1
                guard index < values.count else { throw BenchmarkError.missingValue(value) }
                guard let profile = RDPGraphicsCapabilityProfile(rawValue: values[index]) else {
                    throw BenchmarkError.invalidGraphicsProfile(values[index])
                }
                explicitProfiles.append(profile)
            case "--hide-certificate-warnings":
                args.hideCertificateWarnings = true
            case "--json":
                args.json = true
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                throw BenchmarkError.missingValue("unknown option \(value)")
            }
            index += 1
        }

        if !explicitProfiles.isEmpty {
            args.profiles = explicitProfiles
        }
        return args
    }

    private static func parseDisplaySize(_ value: String) -> BenchmarkDisplaySize? {
        let parts = value.lowercased().split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let width = UInt16(parts[0]),
              let height = UInt16(parts[1]),
              width > 0,
              height > 0
        else {
            return nil
        }
        return BenchmarkDisplaySize(width: width, height: height)
    }

    private static func requiredHost(_ args: BenchmarkArguments) throws -> String {
        guard let host = args.host, !host.isEmpty else {
            throw BenchmarkError.missingHost
        }
        return host
    }

    private static func loadCredentials(from args: BenchmarkArguments) throws -> RDPCredentials? {
        let hasAnyCredentialInput = args.username != nil || args.domain != nil || args.passwordEnv != nil
        guard hasAnyCredentialInput else {
            return nil
        }
        guard let username = args.username, !username.isEmpty else {
            throw BenchmarkError.missingCredential("username is required when password or domain is provided")
        }
        guard let passwordEnv = args.passwordEnv else {
            throw BenchmarkError.missingCredential("password environment variable is required when credentials are provided")
        }
        let password = ProcessInfo.processInfo.environment[passwordEnv]
        guard let password, !password.isEmpty else {
            throw BenchmarkError.missingPasswordEnv(passwordEnv)
        }
        return RDPCredentials(username: username, domain: args.domain, password: password)
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
