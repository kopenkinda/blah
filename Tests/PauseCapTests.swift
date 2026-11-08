import Foundation

@main
struct PauseCapTests {
    static func main() {
        func tone(_ seconds: Double, amplitude: Float) -> [Float] {
            (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.2) }
        }
        let room = tone(10, amplitude: 0.000_5)
        // Syllable-like bursts over room noise. A steady tone would read as background noise.
        let syllable = tone(0.15, amplitude: 0.1) + tone(0.05, amplitude: 0.000_5)
        let speech = Array(repeating: syllable, count: 10).flatMap { $0 }

        // A long pause is shortened for the stream, but every bit of speech is kept.
        var cap = PauseCap()
        let clip = tone(0.5, amplitude: 0.000_5) + speech + room + speech
        let heard = cap.push(clip).count + cap.finish()!.count
        assert(heard < clip.count - room.count / 2, "the pause was not shortened")
        assert(heard >= clip.count - room.count + PauseCap.pauseHead, "speech or the pause head was cut")

        // Audio that never rises above its own floor, then gets cut, means the level was misjudged.
        var quiet = PauseCap()
        _ = quiet.push(tone(8, amplitude: 0.000_5))
        assert(quiet.finish() == nil)
        print("Pause cap checks passed")
    }
}
