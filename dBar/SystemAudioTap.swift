import Accelerate
import CoreAudio
import os

/// Captures the stereo mix of everything the Mac is playing using a Core Audio process tap
/// (macOS 14.2+) and reports per-channel peak amplitude.
///
/// The tap feeds a private aggregate device whose IO callback measures each buffer and
/// folds the result into a `PeakAccumulator`, which the UI drains at display rate.
final class SystemAudioTap {
    private let accumulator = PeakAccumulator()
    private let ioQueue = DispatchQueue(label: "dBar.SystemAudioTap", qos: .userInteractive)
    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    var isRunning: Bool { ioProcID != nil }

    func start() throws {
        guard !isRunning else { return }
        do {
            let tapUID = try createTap()
            try createAggregateDevice(tapUID: tapUID)
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        _ = accumulator.drain()
    }

    /// Highest absolute sample value per channel (0 = silence, 1 = 0 dBFS) since the previous call.
    func drainPeaks() -> SIMD2<Float> {
        accumulator.drain()
    }

    private func createTap() throws -> String {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "dBar Output Meter"
        description.isPrivate = true
        try AudioHardwareCreateProcessTap(description, &tapID).check("Creating the system audio tap")

        let format = try tapID.read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else {
            throw CoreAudioError(operation: "Reading the tap format", status: kAudioDeviceUnsupportedFormatError)
        }
        return description.uuid.uuidString
    }

    /// The aggregate device contains only the tap, so its input streams are exactly the tapped mix.
    private func createAggregateDevice(tapUID: String) throws {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "dBar Output Meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        try AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateDeviceID)
            .check("Creating the capture device")
    }

    private func startIO() throws {
        let accumulator = self.accumulator
        try AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, ioQueue) { _, inputData, _, _, _ in
            accumulator.record(Self.peaks(in: inputData))
        }
        .check("Creating the audio callback")
        try AudioDeviceStart(aggregateDeviceID, ioProcID).check("Starting audio capture")
    }

    /// Runs on the audio IO thread: must not allocate or block.
    private static func peaks(in bufferList: UnsafePointer<AudioBufferList>) -> SIMD2<Float> {
        var peaks = SIMD2<Float>.zero
        var channel = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList)) {
            let channelsInBuffer = Int(buffer.mNumberChannels)
            guard channelsInBuffer > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride / channelsInBuffer
            if frameCount > 0 {
                // Interleaved buffers hold several channels; stride over them one channel at a time.
                for offset in 0..<channelsInBuffer where channel + offset < 2 {
                    var peak: Float = 0
                    vDSP_maxmgv(samples + offset, vDSP_Stride(channelsInBuffer), &peak, vDSP_Length(frameCount))
                    peaks[channel + offset] = peak
                }
            }
            channel += channelsInBuffer
        }
        if channel == 1 {
            peaks[1] = peaks[0]
        }
        return peaks
    }
}

/// Collects the running per-channel maximum between UI refreshes so no transient is missed.
private final class PeakAccumulator: Sendable {
    private let peaks = OSAllocatedUnfairLock(initialState: SIMD2<Float>.zero)

    func record(_ newPeaks: SIMD2<Float>) {
        peaks.withLock { $0 = pointwiseMax($0, newPeaks) }
    }

    func drain() -> SIMD2<Float> {
        peaks.withLock { current in
            defer { current = .zero }
            return current
        }
    }
}
