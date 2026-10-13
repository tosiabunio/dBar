import SwiftUI

/// Maps dBFS values onto the meter bar and its colour zones.
enum MeterScale {
    /// Lowest level the meter shows; anything quieter reads as silence.
    static let floor: Float = -60
    static let ticks: [Float] = [-60, -40, -30, -20, -10, -6, -3, 0]

    private static let warningPosition = position(for: -12)
    private static let dangerPosition = position(for: -3)

    static func decibels(fromAmplitude amplitude: Float) -> Float {
        amplitude > 0 ? max(20 * log10(amplitude), floor) : floor
    }

    /// Bar position in 0...1 using the IEC 60268-18 deflection curve, which gives more room to
    /// the loud end of the scale, rescaled so that `floor` sits at 0.
    static func position(for decibels: Float) -> CGFloat {
        let bottom = iecDeflection(floor)
        return CGFloat(max(0, (iecDeflection(decibels) - bottom) / (1 - bottom)))
    }

    static func color(atPosition position: CGFloat) -> Color {
        switch position {
        case dangerPosition...: .red
        case warningPosition...: .yellow
        default: .green
        }
    }

    private static func iecDeflection(_ db: Float) -> Float {
        switch db {
        case ..<(-70): 0
        case ..<(-60): (db + 70) * 0.0025
        case ..<(-50): (db + 60) * 0.005 + 0.025
        case ..<(-40): (db + 50) * 0.0075 + 0.075
        case ..<(-30): (db + 40) * 0.015 + 0.15
        case ..<(-20): (db + 30) * 0.02 + 0.3
        case ..<0: (db + 20) * 0.025 + 0.5
        default: 1
        }
    }
}
