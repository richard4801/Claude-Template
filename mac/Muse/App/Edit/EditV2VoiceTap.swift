import AVFoundation
import MediaToolbox
import MuseCore

/// Edit suite voice processing (plans/video-editor.md "Voice"): an MTAudioProcessingTap on an audio-mix lane that runs each
/// clip's biquad chain (EditV2.voiceChain: enhance, then the warm/radio/phone/deep effect; RBJ coefficients from MuseCore,
/// fixture-checked) over the samples while that clip plays. Taps run in the live preview and in AVAssetExportSession, so the
/// exported file has the same sound. Spans are timeline seconds (the tap sees composition time).
final class EditV2VoiceTap: @unchecked Sendable {
    struct Span {
        let start: Double
        let end: Double
        /// The clip's voice processing, or nil (only a boost).
        let voice: EditV2.VoiceSettings?
        /// Gain above 1× (Mac Edit audit 2026-11-08: AVAudioMix volumes stop at 1, so a clip at +6 dB played at 0 dB): the
        /// clip's envelope points; the tap multiplies by max(1, gain) while the mix applies min(1, gain).
        var boost: [EditV2.GainPoint] = []
        init(start: Double, end: Double, voice: EditV2.VoiceSettings?, boost: [EditV2.GainPoint] = []) {
            self.start = start; self.end = end; self.voice = voice; self.boost = boost
        }
        /// The boost factor (≥ 1) at timeline t.
        func boostAt(_ t: Double) -> Double {
            guard let f = boost.first else { return 1 }
            if t <= f.t { return max(1, f.gain) }
            for (a, b) in zip(boost, boost.dropFirst()) where t >= a.t && t <= b.t {
                let g = b.t - a.t < 1e-9 ? b.gain : a.gain + (b.gain - a.gain) * (t - a.t) / (b.t - a.t)
                return max(1, g)
            }
            return max(1, boost[boost.count - 1].gain)
        }
    }

    private let spans: [Span]
    private var chains: [[EditV2.Biquad]] = []
    /// [channel][filter] state of the chain in use.
    private var state: [[EditV2.BiquadState]] = []
    private var current = -1
    private var sampleRate = 44_100.0
    private var isFloat = true
    private var interleaved = false
    private var channels = 2

    private init(_ spans: [Span]) { self.spans = spans }

    /// A tap for one lane, or nil when none of its clips has voice processing (or the tap can't be made).
    static func make(_ spans: [Span]) -> MTAudioProcessingTap? {
        guard !spans.isEmpty else { return nil }
        let ctx = EditV2VoiceTap(spans)
        let info = Unmanaged.passRetained(ctx).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: info,
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<EditV2VoiceTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<EditV2VoiceTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: { _ in },
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.zero
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                let me = Unmanaged<EditV2VoiceTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.process(buffers, frames: Int(framesOut.pointee), start: range.start.isNumeric ? range.start.seconds : nil)
            })
        // The macOS SDK hands the new tap back as a retained Unmanaged reference.
        var tapOut: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tapOut)
        guard err == noErr, let made = tapOut else {
            Unmanaged<EditV2VoiceTap>.fromOpaque(info).release()
            return nil
        }
        return made.takeRetainedValue()
    }

    private func prepare(_ f: AudioStreamBasicDescription) {
        sampleRate = f.mSampleRate > 0 ? f.mSampleRate : 44_100
        isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
        interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = max(1, Int(f.mChannelsPerFrame))
        chains = spans.map { $0.voice?.chain(sampleRate: sampleRate) ?? [] }
        current = -1
    }

    private func span(at t: Double) -> Int {
        for (i, s) in spans.enumerated() where t >= s.start - 1e-4 && t < s.end { return i }
        return -1
    }

    private func use(_ i: Int) {
        guard i != current else { return }
        current = i
        let n = i >= 0 ? chains[i].count : 0
        state = Array(repeating: Array(repeating: EditV2.BiquadState(), count: n), count: channels)
    }

    private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double?) {
        guard isFloat, frames > 0 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        let block = 256
        var f0 = 0
        while f0 < frames {
            let f1 = min(frames, f0 + block)
            if let start { use(span(at: start + Double(f0) / sampleRate)) }
            if current >= 0 {
                let chain = chains[current]
                let gain = start.map { Float(spans[current].boostAt($0 + Double(f0) / sampleRate)) } ?? 1
                if gain > 1.0001 {
                    for (c, buf) in abl.enumerated() {
                        guard let raw = buf.mData else { continue }
                        let p = raw.assumingMemoryBound(to: Float.self)
                        let ch = interleaved ? max(1, Int(buf.mNumberChannels)) : 1
                        let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                        let a = f0 * ch, b = min(n, f1 * ch)
                        if a < b { for i in a..<b { p[i] = max(-1, min(1, p[i] * gain)) } }
                        if interleaved && c == 0 { break }
                    }
                }
                if !chain.isEmpty {
                    if interleaved {
                        if let buf = abl.first, let raw = buf.mData {
                            let p = raw.assumingMemoryBound(to: Float.self)
                            let ch = max(1, Int(buf.mNumberChannels))
                            for i in f0..<f1 {
                                for c in 0..<min(ch, state.count) {
                                    var v = Double(p[i * ch + c])
                                    for k in 0..<chain.count { v = state[c][k].step(chain[k], v) }
                                    p[i * ch + c] = Float(v)
                                }
                            }
                        }
                    } else {
                        for (c, buf) in abl.enumerated() where c < state.count {
                            guard let raw = buf.mData else { continue }
                            let p = raw.assumingMemoryBound(to: Float.self)
                            let n = min(f1, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                            if f0 >= n { continue }
                            for i in f0..<n {
                                var v = Double(p[i])
                                for k in 0..<chain.count { v = state[c][k].step(chain[k], v) }
                                p[i] = Float(v)
                            }
                        }
                    }
                }
            }
            f0 = f1
        }
    }
}
