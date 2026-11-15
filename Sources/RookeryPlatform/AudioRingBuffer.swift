import os

/// Stereo audio passed from the thread that captures it to the thread that plays it, holding no more than
/// a short stretch so the sound stays close to live.
final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    /// The most it holds before dropping the oldest frames, to keep the delay down when the capture runs
    /// ahead of the playback.
    private let maxFill: Int
    private let lock = OSAllocatedUnfairLock()
    private let samples: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var fill = 0

    /// - Parameters:
    ///   - capacity: the frames it can hold
    ///   - maxFill: the frames it keeps at most before dropping the oldest
    init(capacity: Int, maxFill: Int) {
        self.capacity = capacity
        self.maxFill = min(maxFill, capacity)
        samples = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
    }

    deinit {
        samples.deallocate()
    }

    /// Add frames, each taken from a reader of one channel's sample at a frame.
    func write(frameCount: Int, sample: (_ frame: Int, _ channel: Int) -> Float) {
        lock.withLockUnchecked {
            for frame in 0..<frameCount {
                let index = (readIndex + fill) % capacity
                samples[index * 2] = sample(frame, 0)
                samples[index * 2 + 1] = sample(frame, 1)
                if fill == capacity {
                    readIndex = (readIndex + 1) % capacity
                } else {
                    fill += 1
                }
            }
            if fill > maxFill {
                readIndex = (readIndex + fill - maxFill) % capacity
                fill = maxFill
            }
        }
    }

    /// Take frames into one buffer per channel, filling with silence where too few have arrived.
    func read(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        lock.withLockUnchecked {
            let available = min(frameCount, fill)
            for frame in 0..<available {
                let index = (readIndex + frame) % capacity
                left[frame] = samples[index * 2]
                right[frame] = samples[index * 2 + 1]
            }
            for frame in available..<frameCount {
                left[frame] = 0
                right[frame] = 0
            }
            readIndex = (readIndex + available) % capacity
            fill -= available
        }
    }

    /// Drop everything held.
    func clear() {
        lock.withLockUnchecked {
            readIndex = 0
            fill = 0
        }
    }
}
