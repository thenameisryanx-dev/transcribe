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

    /// Starts the audio engine. Waking the output device can take seconds (a USB or Bluetooth speaker that was
    /// asleep takes about five), so it runs off the main actor; the app stays responsive and keeps speaking ahead.
    typealias EngineStarter = @Sendable (AVAudioEngine) throws -> Void
    static let startEngine: EngineStarter = { engine in
        engine.prepare()
        try engine.start()
    }
    private let startEngine: EngineStarter
    /// The engine starting in the background. Nodes aren't touched until it's done.
    private var engineStart: Task<Void, Error>?

    /// 1 is the voice's own pace; 0.5 to 4 keep the voice's pitch.
    var rate: Double = 1 {
        didSet { timePitch.rate = Float(rate) }
    }

    init(startEngine: @escaping EngineStarter = ListenAudioPlayer.startEngine) {
        self.startEngine = startEngine
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

    /// Plays `sentence` from `time` seconds into it, replacing whatever was playing. `onStart` runs once it can be
    /// heard (at once, unless the output device has to start first), with the error if it couldn't be played.
    /// `onFinish` runs once it has all been heard. Neither runs if it's stopped, paused or replaced first.
    func play(
        _ sentence: SpokenSentence,
        from time: Double,
        onStart: @escaping @MainActor (Error?) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        generation += 1
        let current = generation
        isPlaying = false
        pausedTime = nil
        guard let engineStart else {
            schedule(sentence, from: time, generation: current, onStart: onStart, onFinish: onFinish)
            return
        }
        Task { [weak self] in
            _ = await engineStart.result
            guard let self, self.generation == current else { return }
            self.schedule(sentence, from: time, generation: current, onStart: onStart, onFinish: onFinish)
        }
    }

    private func schedule(
        _ sentence: SpokenSentence,
        from time: Double,
        generation current: Int,
        onStart: @escaping @MainActor (Error?) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        player.stop()
        do {
            try connect(sampleRate: Double(sentence.sampleRate))
        } catch {
            onStart(error)
            return
        }

        let total = AVAudioFramePosition(sentence.samples.count)
        let start = min(max(AVAudioFramePosition(time * sampleRate), 0), max(total - 1, 0))
        startFrame = start
        frameCount = total

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
        if engine.isRunning {
            begin(onStart: onStart)
            return
        }
        let box = EngineBox(engine: engine)
        let startEngine = startEngine
        let task = Task.detached(priority: .userInitiated) { try startEngine(box.engine) }
        engineStart = task
        Task { [weak self] in
            let result = await task.result
            guard let self else { return }
            if self.engineStart == task { self.engineStart = nil }
            // Stopped, paused or replaced while the device was starting.
            guard self.generation == current else { return }
            switch result {
            case .success: self.begin(onStart: onStart)
            case .failure(let error): onStart(error)
            }
        }
    }

    private func begin(onStart: @MainActor (Error?) -> Void) {
        player.play()
        isPlaying = true
        onStart(nil)
    }

    func pause() {
        guard isPlaying else {
            // Paused while the device was starting: don't start playing once it's ready.
            if engineStart != nil { generation += 1 }
            return
        }
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
        // While the engine is starting, the scheduled sentence just never plays; the next one clears it.
        if engineStart == nil { player.stop() }
        isPlaying = false
        pausedTime = nil
    }

    /// Seconds into the current sentence that can be heard now, in the voice's own time (not sped up), or nil when
    /// nothing is scheduled.
    var currentTime: Double? {
        if let pausedTime { return pausedTime }
        guard isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return Self.heardTime(
            rendered: Double(playerTime.sampleTime) / sampleRate,
            from: Double(startFrame) / sampleRate,
            length: Double(frameCount) / sampleRate,
            latency: outputLatency,
            rate: rate
        )
    }

    /// The player hands audio on before it's heard: the speed change holds about 85 ms of it, and the output device
    /// (a Bluetooth speaker most of all) more. Following the player's own position put the highlight that far ahead.
    private var outputLatency: Double {
        timePitch.latency + engine.outputNode.presentationLatency
    }

    /// Where the sound being heard is in a sentence: `rendered` seconds of it handed on since playing from `from`,
    /// less what's still on its way to the speaker. Latency passes at the playback rate, which is in sped-up time.
    nonisolated static func heardTime(rendered: Double, from start: Double, length: Double, latency: Double, rate: Double) -> Double {
        min(start + max(rendered - latency * rate, 0), length)
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

/// Hands the engine to the task that starts it. Nothing else touches the engine until that task is done.
private final class EngineBox: @unchecked Sendable {
    let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }
}
