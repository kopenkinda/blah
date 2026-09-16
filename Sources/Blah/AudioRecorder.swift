import AVFoundation
import Foundation

final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "blah.microphone", qos: .userInitiated)
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var accepting = false
    private var peak: Float = 0
    private var conversionFailed = false
    private var sampleStartTime: TimeInterval?
    private var hasHostTime = false
    private var cutoff: TimeInterval?
    private var drain: DispatchSemaphore?
    private var generation = 0

    var level: Float { lock.withLock { peak } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    var tapInstalled = false
                    var started = false
                    defer {
                        if !started {
                            engine.stop()
                            if tapInstalled { input.removeTap(onBus: 0) }
                        }
                    }
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0,
                          let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                    channels: 1, interleaved: false),
                          let converter = AVAudioConverter(from: format, to: target) else {
                        throw AppFailure("The microphone is unavailable. Check Sound settings and try again.")
                    }
                    let generation = lock.withLock {
                        self.generation += 1
                        samples.removeAll(keepingCapacity: true)
                        accepting = true
                        conversionFailed = false
                        peak = 0
                        sampleStartTime = nil
                        hasHostTime = false
                        cutoff = nil
                        drain = nil
                        return self.generation
                    }
                    let tapFrames = AVAudioFrameCount(ceil(format.sampleRate * 0.1))
                    try input.installAudioTap(onBus: 0, bufferSize: tapFrames, format: format) { [self] readOnlyBuffer, time in
                        guard lock.withLock({ accepting && self.generation == generation }) else { return }
                        let buffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
                        let hostStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
                        // Estimate missing host timestamps until the device supplies a valid one.
                        let fallbackStart = ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
                        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / format.sampleRate)) + 64
                        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                            failConversion(generation: generation)
                            return
                        }
                        var supplied = false
                        var error: NSError?
                        let status = converter.convert(to: output, error: &error) { _, inputStatus in
                            if supplied { inputStatus.pointee = .noDataNow; return nil }
                            supplied = true
                            inputStatus.pointee = .haveData
                            return buffer
                        }
                        guard status != .error, error == nil, let data = output.floatChannelData?[0] else {
                            failConversion(generation: generation)
                            return
                        }
                        lock.withLock {
                            guard accepting, self.generation == generation else { return }
                            if let hostStart, !hasHostTime {
                                sampleStartTime = hostStart - Double(samples.count) / 16_000
                                hasHostTime = true
                            } else if sampleStartTime == nil { sampleStartTime = fallbackStart }
                            var count = Int(output.frameLength)
                            if let cutoff, let sampleStartTime {
                                let limit = Int(max(0, (cutoff - sampleStartTime) * 16_000))
                                count = min(count, max(0, limit - samples.count))
                            }
                            let values = UnsafeBufferPointer(start: data, count: count)
                            samples.append(contentsOf: values)
                            let energy = values.reduce(Float(0)) { $0 + $1 * $1 }
                            peak = min(1, sqrt(energy / Float(max(count, 1))) * 8)
                            if let cutoff, let sampleStartTime,
                               samples.count >= Int(max(0, (cutoff - sampleStartTime) * 16_000)) {
                                accepting = false
                                drain?.signal()
                                drain = nil
                            }
                        }
                    }
                    tapInstalled = true
                    engine.prepare()
                    try engine.start()
                    self.engine = engine
                    started = true
                    continuation.resume()
                } catch {
                    lock.withLock { accepting = false }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(at endTime: TimeInterval? = nil) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let completed = DispatchSemaphore(value: 0)
                let waitForTail = lock.withLock {
                    guard let endTime, endTime.isFinite, accepting, engine?.isRunning == true else { return false }
                    cutoff = endTime
                    if let sampleStartTime {
                        let limit = Int(max(0, (endTime - sampleStartTime) * 16_000))
                        if samples.count >= limit {
                            samples.removeSubrange(limit...)
                            accepting = false
                            return false
                        }
                    }
                    drain = completed
                    return true
                }
                // Taps buffer at least 100 ms. Let the buffer containing key-up arrive,
                // but keep only PCM before that timestamp and never wait on the main thread.
                if waitForTail { _ = completed.wait(timeout: .now() + .milliseconds(500)) }
                lock.withLock {
                    accepting = false
                    drain = nil
                    cutoff = nil
                }
                engine?.stop()
                engine?.inputNode.removeTap(onBus: 0)
                engine = nil
                let result = lock.withLock {
                    let result = samples
                    samples = []
                    peak = 0
                    return result
                }
                if lock.withLock({ conversionFailed }) {
                    continuation.resume(throwing: AppFailure("Microphone audio could not be converted. Try recording again."))
                } else { continuation.resume(returning: result) }
            }
        }
    }

    private func failConversion(generation: Int) {
        let failed = lock.withLock {
            guard accepting, self.generation == generation else { return false }
            conversionFailed = true
            accepting = false
            drain?.signal()
            drain = nil
            return true
        }
        guard failed else { return }
        queue.async { [self] in
            guard lock.withLock({ self.generation == generation }) else { return }
            engine?.stop()
            engine?.inputNode.removeTap(onBus: 0)
            engine = nil
        }
    }
}
