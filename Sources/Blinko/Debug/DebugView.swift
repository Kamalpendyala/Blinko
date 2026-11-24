import SwiftUI
import BlinkoCore

struct DebugView: View {
    @ObservedObject var model: DebugModel
    let onPreviewNudge: () -> Void
    let onSampleNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                metric("Blinks", "\(model.blinkCount)", emphasized: true)
                metric("Openness", number(model.latestOpenness))
                metric("Baseline", number(model.baseline))
                metric("Closed <", number(model.closedThreshold))
                metric("Open >", number(model.openThreshold))
                metric("Valid face", percent(model.validFraction))
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 26) {
                metric("Rate", rate(model.smoothedRate))
                metric("Last burst", rate(model.lastBurstRate))
                metric("No blink", noBlink())
                metric("Dismiss", dismissText())
                metric("Nudges", "\(model.nudgeCount)", emphasized: true)
                Spacer()
                if model.quietHoursActive {
                    Text("QUIET HOURS")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                if model.isPaused {
                    Text("PAUSED")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 26) {
                metric("Sampling", samplingText())
                metric("Duty", dutyText())
                if let reason = model.suppression.shortDescription {
                    Text("CAMERA OFF — \(reason.uppercased())")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Sample Now") {
                    onSampleNow()
                }
                .controlSize(.small)
                .disabled(model.isPaused)
                Button("Preview Nudge") {
                    onPreviewNudge()
                }
                .controlSize(.small)
            }

            SparklineView(
                samples: model.samples,
                closedThreshold: model.closedThreshold,
                openThreshold: model.openThreshold,
                baseline: model.baseline,
                blinkTimestamps: model.blinkTimestamps,
                windowSeconds: model.windowSeconds
            )
            .frame(minHeight: 210)

            HStack(spacing: 18) {
                legend(.blue, "openness")
                legend(.orange, "baseline")
                legend(.red, "closed threshold")
                legend(.green, "open threshold")
                Spacer()
                Text("phase: \(phaseLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top) {
                Text(model.monitorStatus.isEmpty ? model.status : model.monitorStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.isRecording {
                    Text("REC")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                Text("\(model.framesSeen) frames")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("Camera runs only during short bursts (12 s every 60 s by default) and is fully stopped in between. Frames are processed in memory and never written to disk.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 400)
    }

    private var phaseLabel: String {
        switch model.phase {
        case .calibrating: return "calibrating"
        case .open: return "open"
        case .closed: return "closed"
        }
    }

    private func metric(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(emphasized ? .system(size: 26, weight: .semibold, design: .rounded) : .system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 14, height: 2)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f/min", value)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func noBlink() -> String {
        guard model.facePresent, let gap = model.secondsSinceBlink else { return "—" }
        return String(format: "%.1f / %@s", gap, secondsText(model.noBlinkInterval))
    }

    private func dismissText() -> String {
        model.autoDismissSeconds <= 0
            ? "Never"
            : "\(secondsText(model.autoDismissSeconds))s"
    }

    private func samplingText() -> String {
        if model.isBursting, let elapsed = model.burstElapsed {
            return String(
                format: "on %.1f/%@s",
                elapsed,
                secondsText(model.burstSeconds)
            )
        }
        if model.isBursting { return "on" }
        if let remaining = model.secondsUntilNextBurst {
            return String(format: "off %.0fs", remaining.rounded(.up))
        }
        return "off"
    }

    private func dutyText() -> String {
        "\(secondsText(model.burstSeconds))s / \(secondsText(model.intervalSeconds))s"
    }

    private func secondsText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private struct SparklineView: View {
    let samples: [DebugModel.PlotSample]
    let closedThreshold: Double?
    let openThreshold: Double?
    let baseline: Double?
    let blinkTimestamps: [TimeInterval]
    let windowSeconds: TimeInterval

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let lastTime = samples.last?.timestamp ?? windowSeconds
                let start = lastTime - windowSeconds
                let maxValue = max(0.45, (samples.compactMap(\.openness).max() ?? 0) * 1.15)

                func point(_ timestamp: TimeInterval, _ value: Double) -> CGPoint {
                    CGPoint(
                        x: (timestamp - start) / windowSeconds * size.width,
                        y: size.height - (value / maxValue) * size.height
                    )
                }

                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black.opacity(0.05))
                )

                var grid = Path()
                for step in stride(from: 0.1, through: maxValue, by: 0.1) {
                    let y = size.height - (step / maxValue) * size.height
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.14)), lineWidth: 1)

                drawThreshold(closedThreshold, color: .red, size: size, maxValue: maxValue, context: context)
                drawThreshold(openThreshold, color: .green, size: size, maxValue: maxValue, context: context)
                drawThreshold(baseline, color: .orange, size: size, maxValue: maxValue, context: context)

                var signal = Path()
                var drawing = false
                for sample in samples where sample.timestamp >= start {
                    guard sample.valid, let openness = sample.openness else {
                        drawing = false
                        continue
                    }
                    let p = point(sample.timestamp, openness)
                    if drawing {
                        signal.addLine(to: p)
                    } else {
                        signal.move(to: p)
                        drawing = true
                    }
                }
                context.stroke(signal, with: .color(.blue), lineWidth: 1.6)

                for timestamp in blinkTimestamps where timestamp >= start {
                    let x = (timestamp - start) / windowSeconds * size.width
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: 12))
                    context.stroke(marker, with: .color(.red), lineWidth: 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private func drawThreshold(
        _ value: Double?,
        color: Color,
        size: CGSize,
        maxValue: Double,
        context: GraphicsContext
    ) {
        guard let value, value.isFinite else { return }
        let y = size.height - (value / maxValue) * size.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(
            path,
            with: .color(color.opacity(0.65)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    }
}
