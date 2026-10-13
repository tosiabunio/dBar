import AppKit
import SwiftUI

struct MeterView: View {
    let model: LevelMeterModel
    @Bindable var launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ChannelRow(name: "L", channel: model.channels[0], resetPeaks: model.resetPeaks)
                ChannelRow(name: "R", channel: model.channels[1], resetPeaks: model.resetPeaks)
                ScaleRow()
            }

            Divider()

            footer
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Text("Output Level")
                .font(.headline)
            Spacer(minLength: 12)
            if let outputDeviceName = model.outputDeviceName {
                Text(outputDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Launch at Login", isOn: $launchAtLogin.isEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Reset Clip") { model.resetClipIndicators() }
                    .disabled(!model.channels.contains(where: \.clipped))
                Button("Quit dBar") { NSApp.terminate(nil) }
            }

            if launchAtLogin.requiresApproval {
                HStack(spacing: 4) {
                    Text("Allow dBar in Login Items to finish.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { launchAtLogin.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }

            if let errorMessage = launchAtLogin.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Column widths shared by the channel rows and the scale so the ticks line up with the bars.
private enum Layout {
    static let spacing: CGFloat = 8
    static let labelWidth: CGFloat = 12
    static let clipIndicatorSize: CGFloat = 8
    static let readoutWidth: CGFloat = 40
    static let barHeight: CGFloat = 12
}

private struct ChannelRow: View {
    let name: String
    let channel: LevelMeterModel.Channel
    let resetPeaks: () -> Void

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Layout.labelWidth)
            SegmentedBar(level: channel.level, peakHold: channel.peakHold)
                .frame(height: Layout.barHeight)
            Circle()
                .fill(channel.clipped ? Color.red : Color.secondary.opacity(0.25))
                .frame(width: Layout.clipIndicatorSize, height: Layout.clipIndicatorSize)
                .help("Clip indicator: lights when the signal reaches 0 dBFS")
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(channel.clipped ? .red : .primary)
                .frame(width: Layout.readoutWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: resetPeaks)
        .help("Peak since last reset. Click to reset peaks.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name == "L" ? "Left channel" : "Right channel")
        .accessibilityValue("Peak " + readout + " decibels")
        .accessibilityAction(named: "Reset peaks", resetPeaks)
    }

    private var readout: String {
        channel.maxPeak > MeterScale.floor ? String(format: "%.1f", channel.maxPeak) : "-∞"
    }
}

/// LED-style bar: lit segments up to the current level plus a single lit segment at the peak hold.
private struct SegmentedBar: View {
    let level: Float
    let peakHold: Float

    private static let segmentWidth: CGFloat = 3
    private static let gap: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let count = Int((size.width + Self.gap) / (Self.segmentWidth + Self.gap))
            guard count > 0 else { return }
            let pitch = (size.width + Self.gap) / CGFloat(count)
            let levelPosition = MeterScale.position(for: level)
            let holdPosition = MeterScale.position(for: peakHold)
            let holdIndex = holdPosition > 0 ? min(Int(holdPosition * CGFloat(count)), count - 1) : nil

            for index in 0..<count {
                let position = CGFloat(index) / CGFloat(count)
                let isLit = position < levelPosition || index == holdIndex
                let rect = CGRect(x: CGFloat(index) * pitch, y: 0, width: pitch - Self.gap, height: size.height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(MeterScale.color(atPosition: position).opacity(isLit ? 1 : 0.18))
                )
            }
        }
    }
}

private struct ScaleRow: View {
    var body: some View {
        HStack(spacing: Layout.spacing) {
            Color.clear.frame(width: Layout.labelWidth)
            Canvas { context, size in
                for tick in MeterScale.ticks {
                    let x = MeterScale.position(for: tick) * size.width
                    let anchor: UnitPoint = tick == MeterScale.ticks.first ? .leading : tick == 0 ? .trailing : .center
                    let label = Text(verbatim: "\(Int(tick))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
                }
            }
            .frame(height: 12)
            Color.clear.frame(width: Layout.clipIndicatorSize)
            Text("dB")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: Layout.readoutWidth, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }
}
