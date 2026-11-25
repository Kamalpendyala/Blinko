import Foundation
import Combine
import BlinkoCore

/// Main-thread view model for the Settings window.
///
/// It holds a draft copy of `Settings` so invalid edits never reach the live
/// monitor. Every field is validated with `Settings.validationIssues()` and the
/// reasons are shown inline (DB-05).
final class SettingsModel: ObservableObject {
    @Published var draft: Settings {
        didSet { refreshIssues() }
    }
    @Published private(set) var issues: [SettingsIssue] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var loginItemEnabled: Bool
    @Published private(set) var loginItemStatus: String
    @Published private(set) var calibration: CalibrationState = .idle
    @Published private(set) var snapshot: MonitorSnapshot?
    @Published private(set) var today: DailyAggregate?
    @Published private(set) var storePath: String
    @Published var confirmDelete = false

    private var applied: Settings

    var onApply: ((Settings) -> String?)?
    var onCalibrate: (() -> Void)?
    var onCancelCalibration: (() -> Void)?
    var onDeleteAllData: (() -> String?)?
    var onSetLaunchAtLogin: ((Bool) -> String?)?

    init(
        settings: Settings,
        storePath: String,
        loginItemEnabled: Bool,
        loginItemStatus: String
    ) {
        self.draft = settings
        self.applied = settings
        self.storePath = storePath
        self.loginItemEnabled = loginItemEnabled
        self.loginItemStatus = loginItemStatus
        refreshIssues()
    }

    func reload(
        settings: Settings,
        snapshot: MonitorSnapshot?,
        today: DailyAggregate?,
        loginItemEnabled: Bool,
        loginItemStatus: String
    ) {
        draft = settings
        applied = settings
        self.snapshot = snapshot
        self.today = today
        self.loginItemEnabled = loginItemEnabled
        self.loginItemStatus = loginItemStatus
        statusMessage = nil
        refreshIssues()
    }

    func save() {
        refreshIssues()
        guard issues.isEmpty else {
            statusMessage = "Fix the highlighted values before saving."
            return
        }
        if let error = onApply?(draft) {
            statusMessage = error
        } else {
            applied = draft
            statusMessage = "Saved."
        }
    }

    func revert() {
        draft = applied
        statusMessage = nil
    }

    func calibrate() {
        calibration = .collecting(progress: 0)
        onCalibrate?()
    }

    func cancelCalibration() {
        onCancelCalibration?()
    }

    func deleteAllData() {
        if let error = onDeleteAllData?() {
            statusMessage = error
        } else {
            let defaults = Settings()
            draft = defaults
            applied = defaults
            calibration = .idle
            statusMessage = "All Blinko data deleted; defaults restored."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let error = onSetLaunchAtLogin?(enabled) {
            statusMessage = error
            loginItemEnabled = !enabled
        } else {
            loginItemEnabled = enabled
            statusMessage = enabled ? "Launch at login enabled." : "Launch at login disabled."
        }
    }

    func update(calibration: CalibrationState) {
        self.calibration = calibration
        switch calibration {
        case let .completed(baseline):
            draft.calibrationBaseline = baseline
            draft.calibrationDate = Date()
            applied.calibrationBaseline = baseline
            applied.calibrationDate = draft.calibrationDate
            statusMessage = String(format: "Calibration saved — baseline %.3f.", baseline)
        case let .failed(message):
            statusMessage = message
        case .idle, .collecting:
            break
        }
    }

    func update(snapshot: MonitorSnapshot?) {
        self.snapshot = snapshot
    }

    func update(today: DailyAggregate?) {
        self.today = today
    }

    func update(loginItemEnabled: Bool, status: String) {
        self.loginItemEnabled = loginItemEnabled
        self.loginItemStatus = status
    }

    func issue(for field: SettingsIssue.Field) -> String? {
        issues.first { $0.field == field }?.message
    }

    private func refreshIssues() {
        issues = draft.validationIssues()
    }
}
