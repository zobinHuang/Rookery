import CoreAudio
import Foundation

/// The sound of some processes captured as it is played, and silenced where it would otherwise have
/// played, so it can be played again after treatment. Works through a Core Audio process tap, read through
/// a private aggregate device of its own.
final class ProcessTap {
    /// The tap's sample rate, which the captured frames come at.
    private(set) var sampleRate: Double = 0
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceId = AudioObjectID(kAudioObjectUnknown)
    private var ioProcId: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.zobinhuang.rookery.tap", qos: .userInteractive)

    /// Start capturing, which also silences the processes everywhere else.
    ///
    /// - Parameters:
    ///   - listProcessObjectIds: the Core Audio objects of the processes to capture
    ///   - name: what to call the tap and its device, for the system's audio settings
    ///   - ringBuffer: where the captured frames go
    init(listProcessObjectIds: [AudioObjectID], name: String, ringBuffer: AudioRingBuffer) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: listProcessObjectIds)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapId = AudioObjectID(kAudioObjectUnknown)
        try AudioError.check(AudioHardwareCreateProcessTap(description, &tapId), "Creating the process tap")
        self.tapId = tapId

        do {
            let format = try AudioObject.value(kAudioTapPropertyFormat, of: tapId, as: AudioStreamBasicDescription.self)
            sampleRate = format.mSampleRate
            let outputDeviceId = try AudioObject.value(kAudioHardwarePropertyDefaultOutputDevice, of: AudioObject.system, as: AudioObjectID.self)
            let outputUid = try AudioObject.string(kAudioDevicePropertyDeviceUID, of: outputDeviceId)
            let deviceDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: name,
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUid]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var aggregateDeviceId = AudioObjectID(kAudioObjectUnknown)
            try AudioError.check(
                AudioHardwareCreateAggregateDevice(deviceDescription as CFDictionary, &aggregateDeviceId),
                "Creating the aggregate device"
            )
            self.aggregateDeviceId = aggregateDeviceId

            let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let channelCount = Int(format.mChannelsPerFrame)
            var ioProcId: AudioDeviceIOProcID?
            try AudioError.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcId, aggregateDeviceId, queue) { _, inputData, _, _, _ in
                Self.capture(inputData, isInterleaved: isInterleaved, channelCount: channelCount, into: ringBuffer)
            }, "Creating the device's IO proc")
            self.ioProcId = ioProcId
            try AudioError.check(AudioDeviceStart(aggregateDeviceId, ioProcId), "Starting the aggregate device")
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
    }

    /// Stop capturing, which lets the processes play as they always would.
    func invalidate() {
        if aggregateDeviceId != kAudioObjectUnknown {
            if let ioProcId {
                AudioDeviceStop(aggregateDeviceId, ioProcId)
                AudioDeviceDestroyIOProcID(aggregateDeviceId, ioProcId)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceId)
        }
        if tapId != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapId)
        }
        ioProcId = nil
        aggregateDeviceId = AudioObjectID(kAudioObjectUnknown)
        tapId = AudioObjectID(kAudioObjectUnknown)
    }

    /// Copy the tap's frames, one interleaved buffer or one buffer per channel, into the ring buffer as
    /// stereo, a single channel feeding both sides.
    private static func capture(
        _ inputData: UnsafePointer<AudioBufferList>,
        isInterleaved: Bool,
        channelCount: Int,
        into ringBuffer: AudioRingBuffer
    ) {
        let listBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = listBuffers.first, let firstData = first.mData, channelCount > 0 else {
            return
        }
        let firstSamples = firstData.assumingMemoryBound(to: Float.self)
        if isInterleaved {
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channelCount
            ringBuffer.write(frameCount: frameCount) { frame, channel in
                firstSamples[frame * channelCount + min(channel, channelCount - 1)]
            }
        } else {
            let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let secondSamples = listBuffers.count > 1
                ? listBuffers[1].mData?.assumingMemoryBound(to: Float.self) ?? firstSamples
                : firstSamples
            ringBuffer.write(frameCount: frameCount) { frame, channel in
                channel == 0 ? firstSamples[frame] : secondSamples[frame]
            }
        }
    }
}
