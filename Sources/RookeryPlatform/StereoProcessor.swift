import os

/// The stereo treatment applied to a track as it plays: inverting either channel's polarity, swapping the
/// channels, widening or narrowing the stereo image and turning it up or down. Also measures how loud the
/// track is, for meters.
final class StereoProcessor: @unchecked Sendable {
    struct Parameters {
        var isLeftInverted = false
        var isRightInverted = false
        var isSwapped = false
        /// 0 mono, 1 unchanged, 2 twice as wide.
        var width: Float = 1
        /// 1 unchanged.
        var gain: Float = 1
    }

    /// The loudest sample of each channel since the levels were last read, 0 to 1.
    struct Levels: Sendable {
        var left: Float = 0
        var right: Float = 0
    }

    private let lock = OSAllocatedUnfairLock()
    private var parameters = Parameters()
    private var levels = Levels()

    func setParameters(_ parameters: Parameters) {
        lock.withLockUnchecked {
            self.parameters = parameters
        }
    }

    /// The levels since the last call, starting afresh.
    func takeLevels() -> Levels {
        lock.withLockUnchecked {
            defer {
                levels = Levels()
            }
            return levels
        }
    }

    /// Treat frames in place.
    func process(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let parameters = lock.withLockUnchecked { self.parameters }
        let leftSign: Float = parameters.isLeftInverted ? -1 : 1
        let rightSign: Float = parameters.isRightInverted ? -1 : 1
        var peakLeft: Float = 0
        var peakRight: Float = 0
        for frame in 0..<frameCount {
            var sampleLeft = left[frame] * leftSign
            var sampleRight = right[frame] * rightSign
            if parameters.isSwapped {
                swap(&sampleLeft, &sampleRight)
            }
            if parameters.width != 1 {
                // Scale the side signal, the difference between the channels, leaving the middle alone.
                let mid = (sampleLeft + sampleRight) / 2
                let side = (sampleLeft - sampleRight) / 2 * parameters.width
                sampleLeft = mid + side
                sampleRight = mid - side
            }
            sampleLeft *= parameters.gain
            sampleRight *= parameters.gain
            left[frame] = sampleLeft
            right[frame] = sampleRight
            peakLeft = max(peakLeft, abs(sampleLeft))
            peakRight = max(peakRight, abs(sampleRight))
        }
        lock.withLockUnchecked {
            levels.left = max(levels.left, peakLeft)
            levels.right = max(levels.right, peakRight)
        }
    }
}
