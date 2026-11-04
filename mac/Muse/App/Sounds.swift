import AVFoundation
import Foundation
import MuseCore

/// The prototype's interface sounds, a different set per theme, synthesised by `SoundSynth` (MuseCore) and played with
/// AVAudioEngine. Every theme × kind is rendered once into an `AVAudioPCMBuffer` (current theme first, in the background),
/// so a tap plays at once. Several player nodes take turns, so overlapping sounds mix instead of cutting each other off.
enum Sounds {
    typealias Kind = SoundKind
    /// The Sound toggle (title bar, Theme menu, palette).
    static var enabled = true
    static var theme: ThemeID = .a { didSet { SoundPlayer.shared.prepare(theme.rawValue) } }

    static func play(_ k: Kind) {
        guard enabled else { return }
        SoundPlayer.shared.play(theme: theme.rawValue, kind: k)
    }
}

final class SoundPlayer: @unchecked Sendable {
    static let shared = SoundPlayer()

    private let queue = DispatchQueue(label: "studio.muse.sounds", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.defaultRate, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var running = false
    private var observer: NSObjectProtocol?

    private init() {
        queue.async { self.setUp() }
    }

    private func setUp() {
        for _ in 0..<6 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        // The output device changed (headphones, AirPods, display audio): the engine stops and must be restarted.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.running = false }
        }
        let first = Sounds.theme.rawValue
        for t in [first] + ThemeID.allCases.map(\.rawValue).filter({ $0 != first }) {
            for k in SoundKind.allCases { _ = buffer(t, k) }
        }
    }

    /// Renders a theme's sounds ahead of time (called on theme change).
    func prepare(_ theme: String) {
        queue.async { for k in SoundKind.allCases { _ = self.buffer(theme, k) } }
    }

    func play(theme: String, kind: SoundKind) {
        queue.async {
            guard let buf = self.buffer(theme, kind), self.start() else { return }
            let p = self.players[self.nextPlayer]
            self.nextPlayer = (self.nextPlayer + 1) % self.players.count
            p.stop()
            p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
            p.play()
        }
    }

    private func start() -> Bool {
        if running && engine.isRunning { return true }
        do {
            try engine.start()
            running = true
        } catch {
            NSLog("MUSE sounds: could not start audio engine: \(error)")
            running = false
        }
        return running
    }

    private func buffer(_ theme: String, _ kind: SoundKind) -> AVAudioPCMBuffer? {
        let key = theme + kind.rawValue
        if let b = buffers[key] { return b }
        let pcm = SoundSynth.render(theme: theme, kind: kind, sampleRate: format.sampleRate)
        guard !pcm.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)), let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { src in ch[0].update(from: src.baseAddress!, count: pcm.count) }
        buffers[key] = b
        return b
    }
}
