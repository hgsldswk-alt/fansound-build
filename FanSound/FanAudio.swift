import AVFoundation
import Foundation

private struct RenderParameters {
    let profile: FanSynth.Profile
    let gain: Float
    let deadline: TimeInterval?

    init(_ session: PlaybackSession) {
        profile = FanSynth.Profile(session.preset.sound)
        gain = Float(session.preset.gain)
        deadline = session.deadline
    }
}

private final class FanRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: RenderParameters
    private var current: RenderParameters
    private var synth: FanSynth
    private var currentFade: Float
    private let sampleRate: Double

    init(session: PlaybackSession, sampleRate: Double) {
        let parameters = RenderParameters(session)
        pending = parameters
        current = parameters
        synth = FanSynth(sampleRate: sampleRate, sound: session.preset.sound)
        currentFade = PlaybackSession.fadeMultiplier(deadline: session.deadline, now: PlaybackClock.now)
        self.sampleRate = sampleRate
    }

    func update(_ session: PlaybackSession) {
        lock.lock()
        pending = RenderParameters(session)
        lock.unlock()
    }

    func sourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frames, buffer in
            render(frameCount: frames, audio: buffer)
        }
    }

    func render(frameCount: AVAudioFrameCount, audio: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        if lock.try() {
            current = pending
            lock.unlock()
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audio)
        guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self),
              frameCount > 0 else { return noErr }
        let now = PlaybackClock.now
        let count = Int(frameCount)
        let fadeAtStart = PlaybackSession.fadeMultiplier(deadline: current.deadline, now: now)
        let fadeAtEnd = PlaybackSession.fadeMultiplier(deadline: current.deadline, now: now + Double(count) / sampleRate)
        if fadeAtStart == 0 {
            currentFade = 0
            for buffer in buffers {
                if let pointer = buffer.mData { memset(pointer, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }

        let step = (fadeAtEnd - fadeAtStart) / Float(count)
        let rise = Float(1 / (sampleRate * 0.09))
        var target = fadeAtStart
        for i in 0..<count {
            currentFade = min(target, currentFade + rise)
            data[i] = synth.sample(profile: current.profile, gain: current.gain, fade: currentFade)
            target += step
        }
        for buffer in buffers.dropFirst() {
            if let pointer = buffer.mData { memcpy(pointer, data, min(Int(buffer.mDataByteSize), count * MemoryLayout<Float>.size)) }
        }
        return noErr
    }
}

@MainActor
final class FanAudio {
    private var engine: AVAudioEngine?
    private var renderState: FanRenderState?
    private var activated = false

    var running: Bool { engine?.isRunning == true }
    func owns(_ engine: AVAudioEngine) -> Bool { self.engine === engine }

    func start(_ session: PlaybackSession, expectedOutput: [String]? = nil) throws {
        if running {
            update(session)
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            activated = true
            if let expectedOutput, Self.signature(audioSession.currentRoute) != expectedOutput {
                throw AudioFailure.outputChanged
            }
            let engine = AVAudioEngine()
            let rate = audioSession.sampleRate
            guard rate.isFinite, rate > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
            else { throw AudioFailure.unavailableFormat }

            let state = FanRenderState(session: session, sampleRate: rate)
            let source = state.sourceNode(format: format)
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            self.engine = engine
            renderState = state
        } catch {
            stop()
            throw error
        }
    }

    func update(_ session: PlaybackSession) {
        renderState?.update(session)
    }

    func stop(deactivate: Bool = true) {
        engine?.stop()
        engine = nil
        renderState = nil
        if deactivate && activated {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        activated = false
    }

    static func signature(_ route: AVAudioSessionRouteDescription) -> [String] {
        route.outputs.map { $0.portType.rawValue + "|" + $0.uid }.sorted()
    }

    enum AudioFailure: Error { case unavailableFormat, outputChanged }
}
