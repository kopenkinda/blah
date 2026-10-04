import AVFoundation
import CoreMedia
import Foundation

/// Records 16 kHz mono Float32 PCM from one explicitly selected microphone.
/// This app records the user's ranked preferred device, but AVAudioEngine on
/// macOS captures the system default input, which a lower-priority connected
/// headset can hold or steal mid-session. AVCaptureSession instead binds the
/// capture to the persisted device UID, and its audioSettings deliver the
/// target format without a manual converter.
final class AudioRecorder: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "blah.microphone", qos: .userInitiated)
    // Separate from `queue` so stop() can wait on `queue` for the final tail
    // buffer without deadlocking against the sample callback.
    private let sampleQueue = DispatchQueue(label: "blah.microphone.samples", qos: .userInitiated)
    private let lock = NSLock()

    // State under `lock`, shared with the sample and notification threads.
    private var samples: [Float] = []
    private var accepting = false
    private var peak: Float = 0
    private var timeline = SampleTimeline()
    private var cutoff: TimeInterval?
    private var drain: DispatchSemaphore?
    private var failure: String?
    private var generation = 0
    private var activeOutput: AVCaptureAudioDataOutput?
    private var syncClock: CMClock?
    // Retained for the current capture so both failure paths can notify the
    // controller exactly once; cleared when the capture is torn down.
    private var onInterruption: (@Sendable (String) -> Void)?

    // Session lifecycle, owned by `queue`.
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []

    var level: Float { lock.withLock { peak } }

    func start(deviceUID: String, onInterruption: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    // Defensive only: the controller always stops before starting again.
                    teardown(generation: lock.withLock { generation })
                    guard let device = AVCaptureDevice(uniqueID: deviceUID), device.isConnected else {
                        throw AppFailure("The selected microphone is unavailable. Check its connection and try again.")
                    }
                    let session = AVCaptureSession()
                    let input: AVCaptureDeviceInput
                    do { input = try AVCaptureDeviceInput(device: device) }
                    catch { throw AppFailure("Could not open the selected microphone. \(error.localizedDescription)") }
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                    output.setSampleBufferDelegate(self, queue: sampleQueue)
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw AppFailure("Could not configure the selected microphone. Check Sound settings and try again.")
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                    // Own the session and arm state before running, so any
                    // startup failure is torn down and the first delivered
                    // buffer is accepted; no callbacks can arrive before the
                    // session runs.
                    self.session = session
                    let generation = lock.withLock {
                        self.generation += 1
                        samples.removeAll(keepingCapacity: true)
                        accepting = true
                        peak = 0
                        timeline = SampleTimeline()
                        cutoff = nil
                        drain = nil
                        failure = nil
                        activeOutput = output
                        return self.generation
                    }
                    // Observe only this session and the selected device, so unrelated
                    // headset, default-device, and output events are ignored. Registered
                    // before running so startup errors and disconnects during
                    // startRunning are caught instead of missed.
                    observers = [
                        NotificationCenter.default.addObserver(
                            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
                        ) { [weak self] notification in
                            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                            self?.fail(generation: generation,
                                       message: "Recording failed. \(error?.localizedDescription ?? "Try recording again.")")
                        },
                        NotificationCenter.default.addObserver(
                            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
                        ) { [weak self] _ in
                            self?.fail(generation: generation, message: "Recording was interrupted. Try recording again.")
                        },
                        NotificationCenter.default.addObserver(
                            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
                        ) { [weak self] _ in
                            self?.fail(generation: generation, message: "The selected microphone was disconnected. Try recording again.")
                        }
                    ]
                    session.startRunning()
                    guard session.isRunning else {
                        throw AppFailure("Could not start the selected microphone. Try again.")
                    }
                    // The synchronization clock is nil until the session runs,
                    // and sample timestamps use its timebase, not host time. A
                    // buffer can beat this assignment, so the fallback anchor
                    // stays until a synced timestamp re-anchors the stream.
                    let startupFailure = lock.withLock {
                        syncClock = session.synchronizationClock
                        self.onInterruption = onInterruption
                        return failure
                    }
                    // A disconnect or runtime error during startup must surface
                    // here instead of being reported as a successful start.
                    if let startupFailure { throw AppFailure(startupFailure) }
                    continuation.resume()
                } catch {
                    teardown(generation: lock.withLock { generation })
                    lock.withLock {
                        accepting = false
                        drain = nil
                        cutoff = nil
                        self.onInterruption = nil
                        failure = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(at endTime: TimeInterval? = nil) async throws -> [Float] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Float], Error>) in
            queue.async { [self] in
                let completed = DispatchSemaphore(value: 0)
                let waitForTail = lock.withLock {
                    guard accepting, let endTime, endTime.isFinite, session?.isRunning == true else { return false }
                    if let cap = timeline.totalSampleCap(cutoff: endTime), samples.count >= cap {
                        // Key-up is already covered: trim and stop accepting in
                        // the same locked step so no buffer can append past the
                        // cutoff before teardown obtains the lock.
                        samples.removeSubrange(cap...)
                        accepting = false
                        return false
                    }
                    cutoff = endTime
                    drain = completed
                    return true
                }
                // Buffers arrive roughly every 10 ms. Let the buffer containing
                // key-up arrive, keeping only PCM before that timestamp, and
                // never wait on the main thread.
                if waitForTail { _ = completed.wait(timeout: .now() + .milliseconds(500)) }
                teardown(generation: lock.withLock { generation })
                let (result, failure) = lock.withLock {
                    accepting = false
                    drain = nil
                    cutoff = nil
                    timeline = SampleTimeline()
                    let result = samples
                    samples = []
                    peak = 0
                    return (result, failure)
                }
                if let failure { continuation.resume(throwing: AppFailure(failure)) }
                else { continuation.resume(returning: result) }
            }
        }
    }

    /// Fails the active capture, notifies the controller exactly once, and
    /// releases anyone waiting for the tail. `isCurrent` runs under the lock,
    /// so it may match against generation or output identity. The output stays
    /// owned until teardown clears the delegate.
    private func fail(_ message: String, isCurrent: () -> Bool) {
        let target = lock.withLock { () -> (generation: Int, notify: (@Sendable (String) -> Void)?)? in
            guard accepting, failure == nil, isCurrent() else { return nil }
            failure = message
            accepting = false
            drain?.signal()
            drain = nil
            return (generation, onInterruption)
        }
        guard let target else { return }
        target.notify?(message)
        queue.async { [self] in teardown(generation: target.generation) }
    }

    /// Fails the capture identified by its generation, from session and device
    /// notifications.
    private func fail(generation: Int, message: String) {
        fail(message) { self.generation == generation }
    }

    /// Fails the capture that owns `output`, from the sample callback.
    private func failCapture(_ message: String, from output: AVCaptureOutput) {
        fail(message) { output === self.activeOutput }
    }

    /// Removes observers, delegate, and session. Acceptance and the output
    /// identity are disabled as one atomic step before anything is stopped,
    /// so no buffer lands while the session winds down. Runs on `queue` only.
    private func teardown(generation: Int) {
        var output: AVCaptureAudioDataOutput?
        var active = false
        lock.withLock {
            guard generation == self.generation else { return }
            active = true
            accepting = false
            onInterruption = nil
            output = activeOutput
            activeOutput = nil
            syncClock = nil
        }
        guard active else { return }
        let session = self.session
        let observers = self.observers
        self.session = nil
        self.observers = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Stale callbacks from a previous capture must not touch the new one:
        // identity is checked against the output of the current generation.
        guard lock.withLock({ accepting && output === activeOutput }) else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              Self.isExpectedFormat(description.pointee) else {
            failCapture("Microphone audio was not in the expected format. Try recording again.", from: output)
            return
        }
        // Empty buffers carry no audio and are ignored. A buffer missing data
        // or shorter than its declared sample count would be corrupt audio fed
        // to the model, so it fails instead of being skipped or clamped.
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }
        guard let data = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferGetDataLength(data) >= frames * 4 else {
            failCapture("Microphone audio could not be read. Try recording again.", from: output)
            return
        }
        // The validated layout is exactly packed little-endian Float32, so the
        // bytes are the samples; no downmix or conversion is needed.
        var values = [Float](repeating: 0, count: frames)
        let copied = values.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: frames * 4, destination: buffer.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else {
            failCapture("Microphone audio could not be read. Try recording again.", from: output)
            return
        }
        lock.withLock {
            guard accepting, output === activeOutput else { return }
            if let hostSeconds = Self.hostSeconds(of: sampleBuffer, clock: syncClock) {
                timeline.sync(to: hostSeconds, bufferedSamples: samples.count)
            } else {
                timeline.fallback(now: ProcessInfo.processInfo.systemUptime, frames: frames)
            }
            let cap = timeline.totalSampleCap(cutoff: cutoff)
            var count = values.count
            if let cap { count = min(count, max(0, cap - samples.count)) }
            let kept = values.prefix(count)
            samples.append(contentsOf: kept)
            let energy = kept.reduce(Float(0)) { $0 + $1 * $1 }
            peak = min(1, sqrt(energy / Float(max(count, 1))) * 8)
            if let cap, samples.count >= cap {
                accepting = false
                drain?.signal()
                drain = nil
            }
        }
    }

    /// The exact PCM layout the audioSettings request: 16 kHz, one channel,
    /// 32-bit little-endian Float, packed four bytes per frame. Anything else
    /// would be silently misread rather than converted (48 kHz data read at
    /// 16 kHz shifts every timestamp and transcript), so it must be rejected.
    static func isExpectedFormat(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mSampleRate == 16_000
            && asbd.mChannelsPerFrame == 1
            && asbd.mBitsPerChannel == 32
            && asbd.mBytesPerFrame == 4
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    /// Converts a presentation timestamp from the session synchronization
    /// clock to host-clock seconds, comparable with ProcessInfo.systemUptime.
    private static func hostSeconds(of sampleBuffer: CMSampleBuffer, clock: CMClock?) -> TimeInterval? {
        guard let clock else { return nil }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentation.isValid, presentation.isNumeric else { return nil }
        let host = CMSyncConvertTime(presentation, from: clock, to: CMClockGetHostTimeClock())
        guard host.isValid, host.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(host)
        return seconds.isFinite ? seconds : nil
    }
}

/// Maps contiguous 16 kHz mono samples onto host-time timestamps and applies
/// the key-up cutoff. The first valid host-synced presentation timestamp
/// anchors the stream; fallback estimates are re-anchored against it when a
/// synced timestamp arrives late.
struct SampleTimeline {
    private(set) var start: TimeInterval?
    private var synced = false

    /// Anchors the stream so that sample `bufferedSamples` ends at `hostSeconds`.
    mutating func sync(to hostSeconds: TimeInterval, bufferedSamples: Int) {
        guard !synced, hostSeconds.isFinite else { return }
        start = hostSeconds - Double(bufferedSamples) / 16_000
        synced = true
    }

    /// Estimates the start from arrival time when no timestamp is usable yet.
    mutating func fallback(now: TimeInterval, frames: Int) {
        if start == nil { start = now - Double(frames) / 16_000 }
    }

    /// Total sample cap implied by the cutoff, or nil while unanchored or uncapped.
    func totalSampleCap(cutoff: TimeInterval?) -> Int? {
        guard let cutoff, let start else { return nil }
        return Int(max(0, (cutoff - start) * 16_000))
    }
}
