import AVFoundation
import CoreMedia
import Foundation

// Run: swiftc Sources/Blah/AudioRecorder.swift Tests/AudioRecorderTests.swift -o /tmp/blah-recorder-tests && /tmp/blah-recorder-tests

// Stand-in for the app's user-facing error type, which lives in Models.swift
// alongside types that cannot compile outside the full app target.
struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct AudioRecorderTests {
    static func main() {
        // Cutoff half a second after the anchor keeps exactly 8_000 samples.
        var timeline = SampleTimeline()
        timeline.sync(to: 100.0, bufferedSamples: 0)
        assert(timeline.totalSampleCap(cutoff: nil) == nil)
        assert(timeline.totalSampleCap(cutoff: 100.5) == 8_000)

        // Key-up before any audio: once an anchor exists the cap is zero.
        assert(timeline.totalSampleCap(cutoff: 99.9) == 0)

        // Key-up during startup: no anchor yet, so the cutoff cannot be applied
        // and stop() must wait for the tail instead of returning immediately.
        var waiting = SampleTimeline()
        assert(waiting.totalSampleCap(cutoff: 100.5) == nil)
        waiting.fallback(now: 100.02, frames: 320)
        assert(abs(waiting.start! - 100.0) < 1e-9)
        assert(waiting.totalSampleCap(cutoff: 100.5) == 8_000)

        // A synced timestamp arriving late re-anchors already collected samples.
        waiting.sync(to: 100.12, bufferedSamples: 3_200)
        assert(abs(waiting.start! - 99.92) < 1e-9)
        let cap = waiting.totalSampleCap(cutoff: 100.5)!
        assert((9_279...9_281).contains(cap))

        // Only the first synced timestamp anchors the stream.
        waiting.sync(to: 200.0, bufferedSamples: 16_000)
        assert(abs(waiting.start! - 99.92) < 1e-9)

        // The sample path copies PCM bytes straight into [Float], so every
        // deviation from the requested layout must be rejected rather than
        // misread: 48 kHz data interpreted at 16 kHz would shift each cutoff
        // and transcript by 3x, and the other fields would corrupt decoding.
        func format(rate: Double = 16_000,
                    formatID: UInt32 = kAudioFormatLinearPCM,
                    flags: UInt32 = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    bytesPerFrame: UInt32 = 4,
                    bits: UInt32 = 32,
                    channels: UInt32 = 1) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: rate, mFormatID: formatID, mFormatFlags: flags,
                                        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
                                        mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels,
                                        mBitsPerChannel: bits, mReserved: 0)
        }
        assert(AudioRecorder.isExpectedFormat(format()))
        assert(!AudioRecorder.isExpectedFormat(format(rate: 48_000)))
        assert(!AudioRecorder.isExpectedFormat(format(rate: 16_000.5)))
        assert(!AudioRecorder.isExpectedFormat(format(channels: 2)))
        assert(!AudioRecorder.isExpectedFormat(format(bits: 16)))
        assert(!AudioRecorder.isExpectedFormat(format(bytesPerFrame: 8)))
        assert(!AudioRecorder.isExpectedFormat(format(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian)))
        assert(!AudioRecorder.isExpectedFormat(format(flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved)))
        assert(!AudioRecorder.isExpectedFormat(format(flags: kAudioFormatFlagIsPacked)))
        assert(!AudioRecorder.isExpectedFormat(format(formatID: kAudioFormatAppleLossless)))

        print("Recorder timeline and format checks passed")
    }
}
