import SwiftUI
import BlinkoCore

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            generalSection
            samplingSection
            reminderSection
            calibrationSection
            dataSection
            saveSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 680)
        .alert("Delete all Blinko data?", isPresented: $model.confirmDelete) {
            Button("Delete Everything", role: .destructive) {
                model.deleteAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes your settings, calibration baseline and daily blink counts. "
                + "Camera frames were never stored, so there is nothing else to delete."
            )
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("General") {
            Toggle("Pause Blinko", isOn: $model.draft.paused)
                .help("Camera off and no reminders until you resume.")

            Toggle("Play a soft sound with reminders", isOn: $model.draft.soundEnabled)

            Toggle(
                "Launch Blinko at login",
                isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            Text(model.loginItemStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(
                "Blinko runs only in the menu bar. Camera frames are processed in memory "
                + "and are never saved or sent anywhere."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var samplingSection: some View {
        Section("Sampling & Power") {
            LabeledContent("Burst length") {
                HStack(spacing: 6) {
                    TextField(
                        "Burst length",
                        value: $model.draft.burstSeconds,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
            errorText(.burstSeconds)

            LabeledContent("Interval") {
                HStack(spacing: 6) {
                    TextField(
                        "Interval",
                        value: $model.draft.intervalSeconds,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
            errorText(.intervalSeconds)

            LabeledContent("Pause after inactivity") {
                HStack(spacing: 6) {
                    TextField(
                        "Idle threshold",
                        value: $model.draft.idleThresholdSeconds,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
            errorText(.idleThresholdSeconds)

            LabeledContent("Skip below battery") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { model.draft.lowBatteryThreshold * 100 },
                            set: { model.draft.lowBatteryThreshold = $0 / 100 }
                        ),
                        in: 5...50,
                        step: 1
                    )
                    .frame(width: 180)
                    Text("\(Int((model.draft.lowBatteryThreshold * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            errorText(.lowBatteryThreshold)

            Text("The camera runs only during bursts and is fully stopped in between.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reminderSection: some View {
        Section("Reminders") {
            LabeledContent("Remind after no blink for") {
                HStack(spacing: 6) {
                    TextField(
                        "Blink interval",
                        value: $model.draft.noBlinkInterval,
                        format: .number.precision(.fractionLength(1))
                    )
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
            errorText(.noBlinkInterval)

            LabeledContent("Dismiss the card after") {
                HStack(spacing: 6) {
                    TextField(
                        "Dismiss delay",
                        value: $model.draft.autoDismissSeconds,
                        format: .number.precision(.fractionLength(1))
                    )
                    .labelsHidden()
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    Text("seconds (0 = never)")
                        .foregroundStyle(.secondary)
                }
            }
            errorText(.autoDismissSeconds)

            Toggle(
                "Offer timed reminders when the camera is unavailable",
                isOn: $model.draft.fallbackRemindersEnabled
            )

            Toggle("Quiet hours", isOn: $model.draft.quietHours.enabled)
            if model.draft.quietHours.enabled {
                DatePicker(
                    "Starts",
                    selection: quietTimeBinding(hour: \.startHour, minute: \.startMinute),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Ends",
                    selection: quietTimeBinding(hour: \.endHour, minute: \.endMinute),
                    displayedComponents: .hourAndMinute
                )
            }
            errorText(.quietHours)
        }
    }

    private var calibrationSection: some View {
        Section("Calibration") {
            Text(
                "Calibration records about five seconds of open-eye openness and sets "
                + "the detector baseline. Keep your eyes open and face the camera in "
                + "normal light."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let baseline = model.draft.calibrationBaseline {
                LabeledContent("Saved baseline") {
                    Text(String(format: "%.3f", baseline))
                        .monospacedDigit()
                }
            }
            if let date = model.draft.calibrationDate {
                LabeledContent("Calibrated") {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }

            switch model.calibration {
            case .idle:
                EmptyView()
            case let .collecting(progress):
                ProgressView(value: progress) {
                    Text("Calibrating — keep your eyes open…")
                }
                Button("Cancel Calibration") {
                    model.cancelCalibration()
                }
            case let .completed(baseline):
                Text(String(format: "Complete — baseline %.3f.", baseline))
                    .foregroundStyle(.green)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
            }

            Button("Calibrate Now (5 s)") {
                model.calibrate()
            }
            .disabled(!canCalibrate)
        }
    }

    private var dataSection: some View {
        Section("Data & Privacy") {
            LabeledContent("Store") {
                Text(model.storePath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            if let today = model.today {
                Text(
                    "Today: \(Int(today.validSeconds.rounded())) s with a valid face, "
                    + "\(today.blinkCount) blinks, \(today.nudgeCount) nudges."
                )
                .font(.callout)
            } else {
                Text("No aggregate data recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(
                "Only settings and daily aggregate counts are stored. Frames, images "
                + "and landmark arrays are never written to disk."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Delete All Blinko Data…", role: .destructive) {
                model.confirmDelete = true
            }
        }
    }

    private var saveSection: some View {
        Section {
            HStack {
                if let message = model.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(model.issues.isEmpty ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Revert") {
                    model.revert()
                }
                Button("Save") {
                    model.save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Helpers

    private var canCalibrate: Bool {
        guard let snapshot = model.snapshot else { return false }
        return snapshot.isRunning && !snapshot.isPaused && !snapshot.cameraDenied
    }

    private func errorText(_ field: SettingsIssue.Field) -> some View {
        Group {
            if let message = model.issue(for: field) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func quietTimeBinding(
        hour: WritableKeyPath<QuietHours, Int>,
        minute: WritableKeyPath<QuietHours, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: Date()
                )
                components.hour = model.draft.quietHours[keyPath: hour]
                components.minute = model.draft.quietHours[keyPath: minute]
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                model.draft.quietHours[keyPath: hour] = components.hour ?? 0
                model.draft.quietHours[keyPath: minute] = components.minute ?? 0
            }
        )
    }
}
