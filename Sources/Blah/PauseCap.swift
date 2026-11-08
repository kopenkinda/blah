import Foundation

/// Decides which audio a live transcription stream hears, ported from Hex
/// (src/transcription/engine/streaming.rs and pause_segmenter.rs).
///
/// Parakeet's buffered stream can drop the first word after a pause longer than
/// its 5.6 s left context, so the stream hears only the head and tail of each
/// pause. The clip keeps every sample, so the whole-clip fallback is unaffected.
/// It also reports when the stream's text stops well before the speech it heard,
/// which means a phrase was dropped and the whole clip should decide.
struct PauseCap {
    static let frameSamples = 320 // 20 ms
    /// Longer than a chunk plus its lookahead (2.08 s), so words before a pause decode during it.
    static let pauseHead = 40_000
    /// Pause audio kept just before speech resumes.
    static let pauseTail = 4_800
    /// A word's last timestamp can come slightly before the word ends.
    static let slack = 6_400
    /// Untranscribed speech that marks a dropped phrase. Longer than a key click.
    static let untranscribedLimit = 4_800

    private var floor: Float?
    private var frame: [Float] = []
    private var sent = 0
    private var speechEnds: [Int] = []
    private var pause = 0
    private var tail: [Float] = []
    private var dropped = 0
    private var heard = false

    /// Returns the part of `samples` the stream should hear.
    mutating func push(_ samples: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count + tail.count)
        var rest = samples[...]
        while !rest.isEmpty {
            let take = min(rest.count, Self.frameSamples - frame.count)
            frame.append(contentsOf: rest.prefix(take))
            rest = rest.dropFirst(take)
            if frame.count == Self.frameSamples { complete(into: &out) }
        }
        sent += out.count
        return out
    }

    /// Returns the last audio to feed before trailing silence, or nil when the
    /// level detection misjudged the microphone and cut everything after the opening words.
    mutating func finish() -> [Float]? {
        var out: [Float] = []
        if pause <= Self.pauseHead { out = frame } else { dropped += frame.count }
        frame = []
        dropped += tail.count
        tail = []
        return !heard && dropped > 0 ? nil : out
    }

    /// Whether speech the stream heard continues well past where its text ends.
    func droppedSpeech(textEndMs: Int) -> Bool {
        let covered = textEndMs * 16 + Self.slack
        return speechEnds.filter { $0 > covered }.count * Self.frameSamples >= Self.untranscribedLimit
    }

    private mutating func complete(into out: inout [Float]) {
        let (quiet, speech) = classify(frame)
        if !quiet {
            heard = true
            out += tail
            tail = []
            pause = 0
            out += frame
            frame = []
            if speech { speechEnds.append(sent + out.count) }
            return
        }
        pause += frame.count
        if pause <= Self.pauseHead {
            out += frame
            frame = []
            return
        }
        tail += frame
        frame = []
        let overflow = max(0, tail.count - Self.pauseTail)
        tail.removeFirst(overflow)
        dropped += overflow
    }

    /// Only audio near the noise floor counts as pause. Speech a few dB over steady
    /// noise must not be cut, and a quiet microphone needs a low absolute bound.
    private mutating func classify(_ frame: [Float]) -> (quiet: Bool, speech: Bool) {
        let mean = frame.reduce(0, +) / Float(frame.count)
        let energy = frame.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(frame.count)
        let level = energy.isFinite ? 10 * log10(max(energy, 1e-18)) : 0
        let floor = if let floor = self.floor, level >= floor { floor + 0.06 } else { max(level, -90) }
        self.floor = floor
        return (level <= max(floor + 4, -70), level > max(floor + 12, -55))
    }
}
