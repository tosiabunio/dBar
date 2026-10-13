import Foundation
import os

/// Loudness measurement as defined by ITU-R BS.1770 (the basis of EBU R128 and of the
/// normalization streaming services apply). `LoudnessAnalyzer` K-weights the audio on the IO
/// thread and emits 100 ms blocks of power; `LoudnessMeter` turns those into readings.
enum Loudness {
    /// Integrated loudness most streaming services normalize to.
    static let target: Float = -14

    /// Loudness in LUFS of a mean-square power summed over channels.
    static func lufs(fromPower power: Double) -> Float {
        power > 0 ? Float(-0.691 + 10 * log10(power)) : -.infinity
    }
}

/// Runs on the audio IO thread: K-weights both channels and emits the mean-square power of
/// every 100 ms block, the step BS.1770's 400 ms windows and gating advance by.
final class LoudnessAnalyzer: @unchecked Sendable {
    private var leftFilter: KWeightingFilter
    private var rightFilter: KWeightingFilter
    private let framesPerBlock: Int
    private var blockEnergy = 0.0
    private var blockFrames = 0
    private let completedBlocks: OSAllocatedUnfairLock<[Double]>

    init(sampleRate: Double) {
        leftFilter = KWeightingFilter(sampleRate: sampleRate)
        rightFilter = KWeightingFilter(sampleRate: sampleRate)
        framesPerBlock = max(1, Int((sampleRate / 10).rounded()))
        var blocks: [Double] = []
        blocks.reserveCapacity(64)
        completedBlocks = OSAllocatedUnfairLock(initialState: blocks)
    }

    /// Strides let the same code read interleaved and planar buffers.
    func process(
        left: UnsafePointer<Float>, leftStride: Int,
        right: UnsafePointer<Float>, rightStride: Int,
        frameCount: Int
    ) {
        for frame in 0..<frameCount {
            let l = leftFilter.process(Double(left[frame * leftStride]))
            let r = rightFilter.process(Double(right[frame * rightStride]))
            blockEnergy += l * l + r * r
            blockFrames += 1
            if blockFrames == framesPerBlock {
                let power = blockEnergy / Double(framesPerBlock)
                completedBlocks.withLock { $0.append(power) }
                blockEnergy = 0
                blockFrames = 0
            }
        }
    }

    /// Power of each 100 ms block completed since the previous call, oldest first.
    func drainBlocks() -> [Double] {
        completedBlocks.withLock { blocks in
            defer { blocks.removeAll(keepingCapacity: true) }
            return blocks
        }
    }
}

/// Short-term and gated integrated loudness, fed with `LoudnessAnalyzer`'s 100 ms blocks.
struct LoudnessMeter {
    private static let blocksPerMomentaryWindow = 4 // 400 ms
    private static let blocksPerShortTermWindow = 30 // 3 s
    private static let absoluteGatePower = pow(10, (-70 + 0.691) / 10) // -70 LUFS

    private var recentBlocks: [Double] = []
    /// Power of every 400 ms window (75% overlap) above the absolute gate since the last reset.
    private var gatingWindows: [Double] = []

    /// Loudness of the last 3 s in LUFS (of what's available until 3 s have passed).
    private(set) var shortTerm = -Float.infinity
    /// Gated loudness since the meter started or `resetIntegrated()` was called, in LUFS.
    private(set) var integrated = -Float.infinity

    mutating func add(blockPower: Double) {
        recentBlocks.append(blockPower)
        if recentBlocks.count > Self.blocksPerShortTermWindow {
            recentBlocks.removeFirst()
        }
        shortTerm = Loudness.lufs(fromPower: Self.mean(recentBlocks[...]))

        guard recentBlocks.count >= Self.blocksPerMomentaryWindow else { return }
        let windowPower = Self.mean(recentBlocks.suffix(Self.blocksPerMomentaryWindow))
        guard windowPower > Self.absoluteGatePower else { return }
        gatingWindows.append(windowPower)
        updateIntegrated()
    }

    mutating func resetIntegrated() {
        gatingWindows.removeAll()
        integrated = -.infinity
    }

    /// BS.1770 gating: ignore windows more than 10 LU below the average of those above -70 LUFS.
    private mutating func updateIntegrated() {
        let relativeGatePower = Self.mean(gatingWindows[...]) / 10
        let gated = gatingWindows.filter { $0 > relativeGatePower }
        integrated = Loudness.lufs(fromPower: Self.mean(gated[...]))
    }

    private static func mean(_ values: ArraySlice<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// BS.1770's two-stage K-weighting: a high shelf modelling the head's acoustic effect, then a
/// high-pass. Coefficients are derived for the actual sample rate; at 48 kHz they match the
/// values tabulated in the standard.
struct KWeightingFilter {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        let shelfFrequency = 1681.974450955533
        let shelfGain = 3.999843853973347
        let shelfQ = 0.7071752369554196
        var k = tan(.pi * shelfFrequency / sampleRate)
        let vh = pow(10, shelfGain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / shelfQ + k * k
        shelf = Biquad(
            b0: (vh + vb * k / shelfQ + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / shelfQ + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / shelfQ + k * k) / a0
        )

        let highPassFrequency = 38.13547087602444
        let highPassQ = 0.5003270373238773
        k = tan(.pi * highPassFrequency / sampleRate)
        a0 = 1 + k / highPassQ + k * k
        highPass = Biquad(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / highPassQ + k * k) / a0
        )
    }

    mutating func process(_ sample: Double) -> Double {
        highPass.process(shelf.process(sample))
    }
}

/// Second-order IIR section in transposed direct form II.
struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
