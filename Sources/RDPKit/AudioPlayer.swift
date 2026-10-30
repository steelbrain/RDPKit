import AVFoundation
import Foundation
import os

@MainActor
public final class RDPAudioPlayer {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var queuedFrameCount: AVAudioFramePosition = 0 {
        didSet {
            updatePlaybackDelay()
        }
    }
    /// What `playbackDelay` reports, kept current on the main actor.
    private nonisolated let reportedPlaybackDelay = OSAllocatedUnfairLock(initialState: Duration.zero)
    /// Advanced on every stop so completions of discarded buffers leave the new queue count alone.
    private var queueGeneration = 0
    private let maximumQueuedSeconds: Double

    public init(maximumQueuedSeconds: Double = 0.75) {
        self.maximumQueuedSeconds = max(0, maximumQueuedSeconds)
        engine.attach(player)
    }

    /// How long a sample enqueued now waits before it is heard: the audio queued ahead of
    /// it and the output's presentation latency. Any thread may read it, so a session's
    /// `audioPlaybackDelay` can return it.
    public nonisolated var playbackDelay: Duration {
        reportedPlaybackDelay.withLock { $0 }
    }

    public var statusMessage: String {
        guard let format else {
            return "Ready."
        }
        let channels = switch format.channelCount {
        case 1:
            "mono"
        case 2:
            "stereo"
        default:
            "\(format.channelCount) channel"
        }
        return "Playing PCM \(Int(format.sampleRate)) Hz \(channels)."
    }

    public func reset() {
        stop()
        format = nil
    }

    @discardableResult
    public func enqueue(_ sample: RDPAudioSample) throws -> Bool {
        guard sample.format.isPlayablePCM16Bit else {
            throw RDPAudioPlayerError.unsupportedFormat
        }

        let frameCount = sample.data.count / Int(sample.format.blockAlign)
        guard frameCount > 0 else {
            return false
        }
        guard sample.data.count.isMultiple(of: Int(sample.format.blockAlign)) else {
            throw RDPAudioPlayerError.bufferAllocationFailed
        }

        let format = try playbackFormat(for: sample.format)
        // Nothing drains while the engine is stopped (a failed start, an audio interruption or
        // an output device change), so that audio is dropped rather than filling the queue for good.
        if !engine.isRunning, queuedFrameCount > 0 {
            stop()
        }
        // Compared as Double: a limit no frame position can hold, such as .infinity, means no limit.
        guard Double(queuedFrameCount) <= format.sampleRate * maximumQueuedSeconds else {
            return false
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = buffer.int16ChannelData?[0]
        else {
            throw RDPAudioPlayerError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        _ = sample.data.copyBytes(to: UnsafeMutableBufferPointer(
            start: samples,
            count: frameCount * Int(format.channelCount)
        ))

        let scheduledFrameCount = AVAudioFramePosition(frameCount)
        let scheduledGeneration = queueGeneration
        queuedFrameCount += scheduledFrameCount
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.queueGeneration == scheduledGeneration else {
                    return
                }
                self.queuedFrameCount -= scheduledFrameCount
            }
        }

        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        // The output's latency is known once the engine runs.
        updatePlaybackDelay()
        return true
    }

    private func updatePlaybackDelay() {
        let queuedSeconds = format.map { Double(queuedFrameCount) / $0.sampleRate } ?? 0
        let outputSeconds = engine.isRunning ? engine.outputNode.presentationLatency : 0
        reportedPlaybackDelay.withLock { $0 = .seconds(queuedSeconds + outputSeconds) }
    }

    private func playbackFormat(for sampleFormat: RDPAudioFormat) throws -> AVAudioFormat {
        let sampleRate = Double(sampleFormat.samplesPerSecond)
        let channelCount = AVAudioChannelCount(sampleFormat.channelCount)
        if let format, format.sampleRate == sampleRate, format.channelCount == channelCount {
            return format
        }

        stop()
        guard let nextFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        ) else {
            throw RDPAudioPlayerError.unsupportedFormat
        }
        engine.connect(player, to: engine.mainMixerNode, format: nextFormat)
        engine.prepare()
        format = nextFormat
        return nextFormat
    }

    private func stop() {
        player.stop()
        engine.stop()
        engine.reset()
        queuedFrameCount = 0
        queueGeneration += 1
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
