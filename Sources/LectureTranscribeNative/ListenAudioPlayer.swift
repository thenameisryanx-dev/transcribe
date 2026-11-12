import AVFoundation
import Foundation

/// Plays one spoken sentence at a time at any speed without changing the voice's pitch, and reports how far into
/// the sentence it is, so the reader can highlight the word being spoken.
@MainActor
final class ListenAudioPlayer {
    /// Called when the audio device changes (headphones unplugged): playback has stopped and should be resumed by
    /// playing the sentence again from where it was.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedRate: Double?
    private var sampleRate: Double = 24_000
    /// Where in the sentence the scheduled audio starts, in frames.
    private var startFrame: AVAudioFramePosition = 0
    private var frameCount: AVAudioFramePosition = 0
    /// Bumped each time something new is scheduled, so a stopped sentence's completion is ignored.
    private var generation = 0
    private var pausedTime: Double?
    private var configurationObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    /// 1 is the voice's own pace; 0.5 to 4 keep the voice's pitch.
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(rate) }
    }

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.pausedTime = self.currentTime
                self.isPlaying = false
                self.generation += 1
                self.onInterrupted?()
            }
        }
    }

    /// Plays `sentence` from `time` seconds into it, replacing whatever was playing. `onFinish` runs once it has
    /// all been heard.
    func play(_ sentence: SpokenSentence, from time: Double, onFinish: @escaping @MainActor () -> Void) throws {
        generation += 1
        let current = generation
        player.stop()
        try connect(sampleRate: Double(sentence.sampleRate))

        let total = AVAudioFramePosition(sentence.samples.count)
        let start = min(max(AVAudioFramePosition(time * sampleRate), 0), max(total - 1, 0))
        startFrame = start
        frameCount = total
        pausedTime = nil

        let remaining = AVAudioFrameCount(total - start)
        guard remaining > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining)
        else {
            onFinish()
            return
        }
        buffer.frameLength = remaining
        sentence.samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress! + Int(start), count: Int(remaining))
        }

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.isPlaying = false
                onFinish()
            }
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        pausedTime = currentTime
        player.pause()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying, pausedTime != nil else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        player.play()
        pausedTime = nil
        isPlaying = true
    }

    /// Whether a paused sentence is waiting to resume (after `pause`, not after `stop`).
    var canResume: Bool { !isPlaying && pausedTime != nil && engine.isRunning }

    func stop() {
        generation += 1
        player.stop()
        isPlaying = false
        pausedTime = nil
    }

    /// Seconds into the current sentence, in the voice's own time (not sped up), or nil when nothing is scheduled.
    var currentTime: Double? {
        if let pausedTime { return pausedTime }
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        let frame = min(startFrame + max(playerTime.sampleTime, 0), frameCount)
        return Double(frame) / sampleRate
    }

    private func connect(sampleRate rate: Double) throws {
        guard connectedRate != rate else { return }
        sampleRate = rate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = Float(self.rate)
        connectedRate = rate
    }
}
