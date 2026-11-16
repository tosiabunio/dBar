import CoreAudio
import Foundation
import Observation
import QuartzCore

/// Polls the system audio tap at display rate and applies meter ballistics for the UI.
@MainActor
@Observable
final class LevelMeterModel {
    struct Channel: Equatable {
        /// Displayed level in dBFS: instant attack, linear release.
        var level = MeterScale.floor
        /// Highest recent level in dBFS, held briefly before falling back.
        var peakHold = MeterScale.floor
        /// Highest level in dBFS since the last `resetPeaks()`.
        var maxPeak = MeterScale.floor
        /// Latched once the signal reaches 0 dBFS; cleared by `resetPeaks()`.
        var clipped = false
        fileprivate var peakHoldTime: TimeInterval = 0
    }

    /// BS.1770 loudness of the stereo mix, in LUFS (`MeterScale.floor` when silent).
    struct LoudnessReading: Equatable {
        /// Loudness of the last 3 s.
        var shortTerm = MeterScale.floor
        /// Gated loudness since measuring started or was reset.
        var integrated = MeterScale.floor
    }

    private static let releaseRate: Float = 24 // dB per second
    private static let peakHoldDuration: TimeInterval = 1.5
    private static let refreshInterval: TimeInterval = 1.0 / 60
    private static let backgroundRefreshInterval: TimeInterval = 0.1

    private(set) var channels = [Channel(), Channel()]
    private(set) var loudness = LoudnessReading()
    private(set) var errorMessage: String?

    struct OutputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Connected output devices the user can measure at.
    private(set) var outputDevices: [OutputDevice] = []
    /// UID of the device to measure at, or nil to measure the mix of all apps.
    private(set) var sourceDeviceUID = UserDefaults.standard.string(forKey: Preferences.sourceDeviceUIDKey)
    /// Name of the chosen device, kept so it can still be shown while it's disconnected.
    private(set) var sourceDeviceName = UserDefaults.standard.string(forKey: Preferences.sourceDeviceNameKey)

    /// The chosen device isn't connected, so the meter is measuring all apps instead.
    var sourceDeviceIsMissing: Bool {
        guard let sourceDeviceUID else { return false }
        return !outputDevices.contains { $0.uid == sourceDeviceUID }
    }

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private var loudnessMeter = LoudnessMeter()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: TimeInterval = 0
    @ObservationIgnored private var isVisible = true

    /// Starts capturing, or carries on if capture kept running while the meter was closed.
    func start() {
        refreshOutputDevices()
        guard timer == nil else { return }
        guard startTap() else { return }
        lastTick = CACurrentMediaTime()
        scheduleTimer()
    }

    /// Chooses where to measure: at one output device, or nil for the mix of all apps.
    func selectSource(_ uid: String?) {
        guard uid != sourceDeviceUID else { return }
        sourceDeviceUID = uid
        sourceDeviceName = outputDevices.first { $0.uid == uid }?.name
        UserDefaults.standard.set(sourceDeviceUID, forKey: Preferences.sourceDeviceUIDKey)
        UserDefaults.standard.set(sourceDeviceName, forKey: Preferences.sourceDeviceNameKey)

        guard timer != nil || errorMessage != nil else { return }
        // Readings from the old source don't carry over to the new one.
        stop()
        start()
    }

    private func startTap() -> Bool {
        do {
            try tap.start(deviceUID: sourceDeviceIsMissing ? nil : sourceDeviceUID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshOutputDevices() {
        outputDevices = AudioObjectID.outputDevices().compactMap { device in
            guard let uid = try? device.readString(kAudioDevicePropertyDeviceUID),
                  let name = try? device.readString(kAudioObjectPropertyName)
            else { return nil }
            return OutputDevice(uid: uid, name: name)
        }
    }

    /// While the meter is hidden, refresh just often enough to keep up with the 100 ms
    /// loudness blocks instead of at display rate.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if timer != nil {
            scheduleTimer()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = isVisible ? Self.refreshInterval : Self.backgroundRefreshInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tap.stop()
        channels = [Channel(), Channel()]
        loudnessMeter = LoudnessMeter()
        loudness = LoudnessReading()
    }

    /// Clears the peak hold, maximum peak and clip indicator of every channel, and starts
    /// integrated loudness over.
    func resetPeaks() {
        for index in channels.indices {
            channels[index].peakHold = MeterScale.floor
            channels[index].maxPeak = MeterScale.floor
            channels[index].clipped = false
        }
        loudnessMeter.resetIntegrated()
        loudness.integrated = MeterScale.floor
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let release = Self.releaseRate * Float(now - lastTick)
        lastTick = now

        let peaks = tap.drainPeaks()
        var updated = channels
        for index in updated.indices {
            let peak = MeterScale.decibels(fromAmplitude: peaks[index])
            var channel = updated[index]
            channel.level = max(peak, channel.level - release, MeterScale.floor)
            if peak > MeterScale.floor, peak >= channel.peakHold {
                channel.peakHold = peak
                channel.peakHoldTime = now
            } else if now - channel.peakHoldTime > Self.peakHoldDuration {
                channel.peakHold = max(channel.peakHold - release, channel.level)
            }
            channel.maxPeak = max(channel.maxPeak, peak)
            if peaks[index] >= 1 {
                channel.clipped = true
            }
            updated[index] = channel
        }
        // Skip the assignment when nothing moved so a silent meter doesn't redraw 60 times a second.
        if updated != channels {
            channels = updated
        }

        // Loudness only changes when a 100 ms block completes.
        let blocks = tap.drainLoudnessBlocks()
        guard !blocks.isEmpty else { return }
        for blockPower in blocks {
            loudnessMeter.add(blockPower: blockPower)
        }
        let reading = LoudnessReading(
            shortTerm: max(loudnessMeter.shortTerm, MeterScale.floor),
            integrated: max(loudnessMeter.integrated, MeterScale.floor)
        )
        if reading != loudness {
            loudness = reading
        }
    }
}
