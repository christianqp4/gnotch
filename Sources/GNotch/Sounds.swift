import AppKit
import AVFoundation

/// Short system sounds for timer events.
enum Sounds {
    enum Event {
        case start, pause, resume, goal, saved

        var name: String {
            switch self {
            case .start: return "Purr"
            case .pause: return "Pop"
            case .resume: return "Tink"
            case .goal: return "Glass"
            case .saved: return "Hero"
            }
        }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "timerSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "timerSounds") }
    }

    static func play(_ e: Event) {
        guard enabled else { return }
        NSSound(named: e.name)?.play()
    }
}

/// Focus sounds generated on the fly (no audio files): plays only while a block is running.
@MainActor
final class AmbientPlayer: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case off, brown, pink, white, ocean

        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .brown: return "Brown noise"
            case .pink: return "Pink noise"
            case .white: return "White noise"
            case .ocean: return "Ocean waves"
            }
        }
        var icon: String { self == .off ? "speaker.slash.fill" : self == .ocean ? "water.waves" : "waveform" }
    }

    @Published var kind = Kind(rawValue: UserDefaults.standard.string(forKey: "ambientKind") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(kind.rawValue, forKey: "ambientKind")
            generator.kind = kind
            refresh()
        }
    }
    @Published var volume = UserDefaults.standard.object(forKey: "ambientVolume") as? Double ?? 0.5 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "ambientVolume")
            refresh()
        }
    }

    private let generator = NoiseGenerator()
    private var engine: AVAudioEngine?
    private var running = false
    private var stopWork: DispatchWorkItem?

    init() { generator.kind = kind }

    /// Called whenever the timer phase changes.
    func timerRunning(_ isRunning: Bool) {
        running = isRunning
        refresh()
    }

    private func refresh() {
        let audible = running && kind != .off
        generator.targetGain = audible ? Float(volume * volume) * 0.6 : 0
        stopWork?.cancel()
        if audible {
            startEngineIfNeeded()
        } else if engine != nil {
            // Let it fade out, then release the audio device.
            let work = DispatchWorkItem { [weak self] in
                self?.engine?.stop()
                self?.engine = nil
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func startEngineIfNeeded() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 44100, channels: 1)
        else { return }
        let gen = generator
        gen.sampleRate = Float(format.sampleRate)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let v = gen.next()
                for buffer in buffers {
                    UnsafeMutableBufferPointer<Float>(buffer)[frame] = v
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("GNotch: couldn't start audio: \(error)")
        }
    }
}

/// Runs on the audio thread. Gain glides toward `targetGain`, so changes fade instead of clicking.
final class NoiseGenerator: @unchecked Sendable {
    var kind: AmbientPlayer.Kind = .off
    var targetGain: Float = 0
    var sampleRate: Float = 44100

    private var gain: Float = 0
    private var seed: UInt32 = 0x1234_5678
    private var brown: Float = 0
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    private var wavePhase: Float = 0
    private var wavePeriod: Float = 9

    private func white() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    private func nextBrown() -> Float {
        brown = (brown + 0.02 * white()) / 1.02
        return brown * 3.5
    }

    func next() -> Float {
        gain += (targetGain - gain) * 0.00008
        guard gain > 0.0001 else { return 0 }
        let w = white()
        var v: Float
        switch kind {
        case .off:
            v = 0
        case .white:
            v = w * 0.35
        case .brown:
            v = nextBrown()
        case .pink:
            // Paul Kellet's refined pink filter.
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            v = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
            b6 = w * 0.115926
        case .ocean:
            // Brown noise swelling and receding like waves, each wave a slightly different length.
            wavePhase += 1 / (sampleRate * wavePeriod)
            if wavePhase >= 1 {
                wavePhase -= 1
                wavePeriod = 7 + (white() + 1) * 2.5
            }
            let swell = 0.5 - 0.5 * cos(2 * Float.pi * wavePhase)
            v = nextBrown() * (0.25 + 0.75 * swell * swell)
        }
        return max(-1, min(1, v)) * gain
    }
}
