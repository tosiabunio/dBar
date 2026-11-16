import Accelerate
import CoreAudio
import os

/// Captures the stereo mix of everything the Mac is playing using a Core Audio process tap
/// (macOS 14.2+) and reports per-channel peak amplitude and loudness.
///
/// The tap feeds a private aggregate device whose IO callback measures each buffer into a
/// `PeakAccumulator` and a `LoudnessAnalyzer`, which the UI drains at display rate.
final class SystemAudioTap {
    private let accumulator = PeakAccumulator()
    private let ioQueue = DispatchQueue(label: "dBar.SystemAudioTap", qos: .userInteractive)
    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var loudness: LoudnessAnalyzer?

    var isRunning: Bool { ioProcID != nil }

    /// Measures the mix of every app, or with a `deviceUID` only the audio headed for that
    /// output device, whichever apps or helpers it passed through on the way.
    func start(deviceUID: String? = nil) throws {
        guard !isRunning else { return }
        do {
            let tap = try createTap(deviceUID: deviceUID)
            try createAggregateDevice(tapUID: tap.uid)
            try startIO(sampleRate: tap.sampleRate)
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
        loudness = nil
    }

    /// Highest absolute sample value per channel (0 = silence, 1 = 0 dBFS) since the previous call.
    func drainPeaks() -> SIMD2<Float> {
        accumulator.drain()
    }

    /// K-weighted power of each 100 ms block completed since the previous call, for `LoudnessMeter`.
    func drainLoudnessBlocks() -> [Double] {
        loudness?.drainBlocks() ?? []
    }

    /// Per-app volume mixers that tap other apps' audio, mute it, and play their own processed
    /// copy. A global tap hears both the original and the copy, so these are left out.
    private static let replayingAppBundleIDs: Set<String> = [
        "com.finetuneapp.FineTune",
    ]

    /// Background helpers that do the same but have no bundle ID, matched by executable name.
    /// ForceStereo's helper replays its virtual device's audio on the real interface.
    private static let replayingExecutableNames: Set<String> = [
        "forcestereo",
    ]

    private static func replayingProcesses() -> [AudioObjectID] {
        let processes = (try? AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList)) ?? []
        return processes.filter { process in
            if let bundleID = try? process.readString(kAudioProcessPropertyBundleID),
               replayingAppBundleIDs.contains(bundleID) {
                return true
            }
            guard let pid = try? process.read(kAudioProcessPropertyPID, defaultValue: pid_t(0)),
                  let name = executableName(of: pid)
            else { return false }
            return replayingExecutableNames.contains(name)
        }
    }

    private static func executableName(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
    }

    /// Returns the tap's UID and sample rate.
    private func createTap(deviceUID: String?) throws -> (uid: String, sampleRate: Double) {
        let description: CATapDescription
        if let deviceUID {
            // Everything playing to the device's first output stream. Nothing is excluded: a
            // replaying app's output is exactly what reaches the device. The tap has the
            // stream's channel count, and the meter reads its first two channels.
            description = CATapDescription(excludingProcesses: [], deviceUID: deviceUID, stream: 0)
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.replayingProcesses())
        }
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
        return (description.uuid.uuidString, format.mSampleRate)
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

    private func startIO(sampleRate: Double) throws {
        let accumulator = self.accumulator
        let loudness = LoudnessAnalyzer(sampleRate: sampleRate)
        self.loudness = loudness
        try AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, ioQueue) { _, inputData, _, _, _ in
            // Runs on the audio IO thread: nothing here may allocate or block.
            guard let samples = StereoSamples(inputData) else { return }
            accumulator.record(samples.peaks())
            loudness.process(
                left: samples.left, leftStride: samples.leftStride,
                right: samples.right, rightStride: samples.rightStride,
                frameCount: samples.frameCount
            )
        }
        .check("Creating the audio callback")
        try AudioDeviceStart(aggregateDeviceID, ioProcID).check("Starting audio capture")
    }
}

/// The first two channels of an IO buffer list, whether interleaved (one buffer, stride 2) or
/// planar (one buffer per channel). A mono buffer list is read as both channels.
private struct StereoSamples {
    let left: UnsafePointer<Float>
    let leftStride: Int
    let right: UnsafePointer<Float>
    let rightStride: Int
    let frameCount: Int

    init?(_ bufferList: UnsafePointer<AudioBufferList>) {
        var left: (samples: UnsafePointer<Float>, stride: Int)?
        var right: (samples: UnsafePointer<Float>, stride: Int)?
        var frameCount = Int.max
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList)) {
            let channels = Int(buffer.mNumberChannels)
            guard right == nil, channels > 0, let data = buffer.mData else { continue }
            let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            frameCount = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride / channels)
            for offset in 0..<channels where right == nil {
                if left == nil {
                    left = (samples + offset, channels)
                } else {
                    right = (samples + offset, channels)
                }
            }
        }
        guard let left, frameCount > 0, frameCount != .max else { return nil }
        let second = right ?? left
        (self.left, leftStride, self.right, rightStride) = (left.samples, left.stride, second.samples, second.stride)
        self.frameCount = frameCount
    }

    /// Highest absolute sample value of each channel.
    func peaks() -> SIMD2<Float> {
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        vDSP_maxmgv(left, vDSP_Stride(leftStride), &leftPeak, vDSP_Length(frameCount))
        vDSP_maxmgv(right, vDSP_Stride(rightStride), &rightPeak, vDSP_Length(frameCount))
        return SIMD2(leftPeak, rightPeak)
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
