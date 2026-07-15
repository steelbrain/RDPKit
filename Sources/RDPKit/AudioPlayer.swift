import AVFoundation
import Foundation

@MainActor
public final class RDPAudioPlayer {
    private struct Configuration: Equatable {
        var sampleRate: Double
        var channelCount: UInt32
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configuration: Configuration?
    private var format: AVAudioFormat?
    private var queuedFrameCount: AVAudioFramePosition = 0
    private let maximumQueuedSeconds: Double

    public init(maximumQueuedSeconds: Double = 0.75) {
        self.maximumQueuedSeconds = max(0, maximumQueuedSeconds)
        engine.attach(player)
    }

    public var statusMessage: String {
        guard let configuration else {
            return "Ready."
        }
        let channels = switch configuration.channelCount {
        case 1:
            "mono"
        case 2:
            "stereo"
        default:
            "\(configuration.channelCount) channel"
        }
        return "Playing PCM \(Int(configuration.sampleRate)) Hz \(channels)."
    }

    public func reset() {
        player.stop()
        engine.stop()
        engine.reset()
        configuration = nil
        format = nil
        queuedFrameCount = 0
    }

    @discardableResult
    public func enqueue(_ sample: RDPAudioSample) throws -> Bool {
        guard sample.format.isPCM16Bit else {
            throw RDPAudioPlayerError.unsupportedFormat
        }

        let channelCount = AVAudioChannelCount(sample.format.channelCount)
        let frameCount = sample.data.count / Int(sample.format.blockAlign)
        guard channelCount > 0, frameCount > 0 else {
            return false
        }

        let nextConfiguration = Configuration(
            sampleRate: Double(sample.format.samplesPerSecond),
            channelCount: UInt32(channelCount)
        )
        if configuration != nextConfiguration {
            try configure(nextConfiguration)
        }

        let maximumQueuedFrames = AVAudioFramePosition(
            Double(sample.format.samplesPerSecond) * maximumQueuedSeconds
        )
        guard queuedFrameCount <= maximumQueuedFrames else {
            return false
        }

        guard let format,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              )
        else {
            throw RDPAudioPlayerError.bufferAllocationFailed
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let audioByteCount = frameCount * Int(format.streamDescription.pointee.mBytesPerFrame)
        guard sample.data.count == audioByteCount else {
            throw RDPAudioPlayerError.bufferAllocationFailed
        }
        let audioBufferList = buffer.mutableAudioBufferList
        guard audioBufferList.pointee.mNumberBuffers == 1,
              let destination = audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: UInt8.self)
        else {
            throw RDPAudioPlayerError.bufferAllocationFailed
        }
        try sample.data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw RDPAudioPlayerError.bufferAllocationFailed
            }
            destination.update(from: source, count: audioByteCount)
        }
        audioBufferList.pointee.mBuffers.mDataByteSize = UInt32(audioByteCount)

        let scheduledFrameCount = AVAudioFramePosition(frameCount)
        queuedFrameCount += scheduledFrameCount
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.queuedFrameCount = max(0, self.queuedFrameCount - scheduledFrameCount)
            }
        }

        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        return true
    }

    private func configure(_ nextConfiguration: Configuration) throws {
        player.stop()
        engine.stop()
        engine.reset()
        guard let nextFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: nextConfiguration.sampleRate,
            channels: AVAudioChannelCount(nextConfiguration.channelCount),
            interleaved: true
        ) else {
            throw RDPAudioPlayerError.unsupportedFormat
        }

        engine.connect(player, to: engine.mainMixerNode, format: nextFormat)
        engine.prepare()
        try engine.start()
        player.play()
        configuration = nextConfiguration
        format = nextFormat
        queuedFrameCount = 0
    }
}

public enum RDPAudioPlayerError: Error, Equatable, CustomStringConvertible, Sendable {
    case unsupportedFormat
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .unsupportedFormat:
            "Remote audio format is not supported."
        case .bufferAllocationFailed:
            "Remote audio buffer allocation failed."
        }
    }
}
