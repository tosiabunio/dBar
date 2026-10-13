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
        /// Latched once the signal reaches 0 dBFS; cleared by `resetClipIndicators()`.
        var clipped = false
        fileprivate var peakHoldTime: TimeInterval = 0
    }

    private static let releaseRate: Float = 24 // dB per second
    private static let peakHoldDuration: TimeInterval = 1.5
    private static let refreshInterval: TimeInterval = 1.0 / 60

    private(set) var channels = [Channel(), Channel()]
    private(set) var outputDeviceName: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: TimeInterval = 0

    func start() {
        guard timer == nil else { return }
        outputDeviceName = try? AudioObjectID.defaultOutputDevice().readString(kAudioObjectPropertyName)
        do {
            try tap.start()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
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
    }

    func resetClipIndicators() {
        for index in channels.indices {
            channels[index].clipped = false
        }
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
            if peaks[index] >= 1 {
                channel.clipped = true
            }
            updated[index] = channel
        }
        // Skip the assignment when nothing moved so a silent meter doesn't redraw 60 times a second.
        if updated != channels {
            channels = updated
        }
    }
}
