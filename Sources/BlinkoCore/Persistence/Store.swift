import Foundation

/// Injectable seam for persistence (JSON implementation in `JSONStore`).
///
/// Only aggregate data crosses this boundary: settings, daily counts and a
/// schema version. Camera frames, images and landmark arrays are never stored.
public protocol Store: AnyObject {
    var schemaVersion: Int { get }
    func loadSettings() throws -> Settings
    func saveSettings(_ settings: Settings) throws
    /// Serialized read-modify-write, so concurrent editors cannot lose updates.
    @discardableResult
    func updateSettings(_ mutate: (inout Settings) -> Void) throws -> Settings
    /// Upserts the aggregate for its calendar day (one row per day).
    func recordDailyAggregate(_ aggregate: DailyAggregate) throws
    func loadDailyAggregates() throws -> [DailyAggregate]
    func deleteAllData() throws
}

public extension Store {
    /// Used at launch: a corrupt or unreadable store must not prevent the app
    /// from starting, it just falls back to defaults.
    func loadSettingsOrDefaults() -> Settings {
        (try? loadSettings()) ?? Settings()
    }
}

public struct QuietHours: Codable, Equatable {
    public var enabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int

    public init(
        enabled: Bool = true,
        startHour: Int = 22,
        startMinute: Int = 0,
        endHour: Int = 8,
        endMinute: Int = 0
    ) {
        self.enabled = enabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    /// Tolerant decoding lets older stores (and hand-edited files) load even
    /// when a field was added in a later schema version.
    public init(from decoder: Decoder) throws {
        let defaults = QuietHours()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        startHour = try container.decodeIfPresent(Int.self, forKey: .startHour) ?? defaults.startHour
        startMinute = try container.decodeIfPresent(Int.self, forKey: .startMinute) ?? defaults.startMinute
        endHour = try container.decodeIfPresent(Int.self, forKey: .endHour) ?? defaults.endHour
        endMinute = try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? defaults.endMinute
    }
}

public struct Settings: Codable, Equatable {
    public var paused: Bool
    public var burstSeconds: Double
    public var intervalSeconds: Double
    /// Seconds without a blink before a reminder fires. Re-arms while blinking
    /// stays absent, so the reminder repeats at this cadence.
    public var noBlinkInterval: Double
    /// How long the reminder card stays visible. Zero means "until a blink".
    public var autoDismissSeconds: Double
    /// Skip sampling bursts after this many seconds without keyboard/mouse input.
    public var idleThresholdSeconds: Double
    /// Skip bursts below this battery fraction while unplugged.
    public var lowBatteryThreshold: Double
    public var quietHours: QuietHours
    public var fallbackRemindersEnabled: Bool
    public var soundEnabled: Bool
    /// Last requested login-item state. `SMAppService` remains the source of
    /// truth; this only remembers what the user asked for across launches.
    public var launchAtLogin: Bool
    /// Baseline captured by the guided calibration flow, if any.
    public var calibrationBaseline: Double?
    public var calibrationDate: Date?

    public init(
        paused: Bool = false,
        burstSeconds: Double = 12,
        intervalSeconds: Double = 60,
        noBlinkInterval: Double = 5,
        autoDismissSeconds: Double = 2.5,
        idleThresholdSeconds: Double = 5 * 60,
        lowBatteryThreshold: Double = 0.20,
        // Off for the current tuning build; the menu bar can turn it back on.
        quietHours: QuietHours = QuietHours(enabled: false),
        fallbackRemindersEnabled: Bool = false,
        soundEnabled: Bool = false,
        launchAtLogin: Bool = false,
        calibrationBaseline: Double? = nil,
        calibrationDate: Date? = nil
    ) {
        self.paused = paused
        self.burstSeconds = burstSeconds
        self.intervalSeconds = intervalSeconds
        self.noBlinkInterval = noBlinkInterval
        self.autoDismissSeconds = autoDismissSeconds
        self.idleThresholdSeconds = idleThresholdSeconds
        self.lowBatteryThreshold = lowBatteryThreshold
        self.quietHours = quietHours
        self.fallbackRemindersEnabled = fallbackRemindersEnabled
        self.soundEnabled = soundEnabled
        self.launchAtLogin = launchAtLogin
        self.calibrationBaseline = calibrationBaseline
        self.calibrationDate = calibrationDate
    }

    public init(from decoder: Decoder) throws {
        let defaults = Settings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused
        burstSeconds = try container.decodeIfPresent(Double.self, forKey: .burstSeconds)
            ?? defaults.burstSeconds
        intervalSeconds = try container.decodeIfPresent(Double.self, forKey: .intervalSeconds)
            ?? defaults.intervalSeconds
        noBlinkInterval = try container.decodeIfPresent(Double.self, forKey: .noBlinkInterval)
            ?? defaults.noBlinkInterval
        autoDismissSeconds = try container.decodeIfPresent(Double.self, forKey: .autoDismissSeconds)
            ?? defaults.autoDismissSeconds
        idleThresholdSeconds = try container.decodeIfPresent(Double.self, forKey: .idleThresholdSeconds)
            ?? defaults.idleThresholdSeconds
        lowBatteryThreshold = try container.decodeIfPresent(Double.self, forKey: .lowBatteryThreshold)
            ?? defaults.lowBatteryThreshold
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
            ?? defaults.quietHours
        fallbackRemindersEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .fallbackRemindersEnabled
        ) ?? defaults.fallbackRemindersEnabled
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled)
            ?? defaults.soundEnabled
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
        calibrationBaseline = try container.decodeIfPresent(Double.self, forKey: .calibrationBaseline)
        calibrationDate = try container.decodeIfPresent(Date.self, forKey: .calibrationDate)
    }
}

/// A single validation failure, with a message suitable for inline UI display.
public struct SettingsIssue: Equatable, Identifiable {
    public enum Field: String, CaseIterable {
        case paused
        case burstSeconds
        case intervalSeconds
        case noBlinkInterval
        case autoDismissSeconds
        case idleThresholdSeconds
        case lowBatteryThreshold
        case quietHours
        case fallbackRemindersEnabled
        case soundEnabled
        case launchAtLogin
        case calibrationBaseline
    }

    public let field: Field
    public let message: String

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }

    public var id: String { "\(field.rawValue):\(message)" }
}

public extension Settings {
    /// All problems at once so the Settings window can show every inline error
    /// instead of failing on the first bad field.
    func validationIssues() -> [SettingsIssue] {
        var issues: [SettingsIssue] = []

        func requireFinite(_ value: Double, _ field: SettingsIssue.Field, _ message: String) {
            guard value.isFinite else {
                issues.append(SettingsIssue(field: field, message: message))
                return
            }
        }

        requireFinite(burstSeconds, .burstSeconds, "Burst length must be a number.")
        requireFinite(intervalSeconds, .intervalSeconds, "Sampling interval must be a number.")
        requireFinite(noBlinkInterval, .noBlinkInterval, "Blink interval must be a number.")
        requireFinite(autoDismissSeconds, .autoDismissSeconds, "Dismiss delay must be a number.")
        requireFinite(idleThresholdSeconds, .idleThresholdSeconds, "Idle threshold must be a number.")
        requireFinite(lowBatteryThreshold, .lowBatteryThreshold, "Battery threshold must be a number.")

        if !(3...30).contains(burstSeconds) {
            issues.append(SettingsIssue(
                field: .burstSeconds,
                message: "Burst length must be between 3 and 30 seconds."
            ))
        }
        let minimumInterval = max(3, burstSeconds)
        if !(minimumInterval...300).contains(intervalSeconds) {
            issues.append(SettingsIssue(
                field: .intervalSeconds,
                message: "The interval must be between 3 and 300 seconds and at least the burst length."
            ))
        }
        if !(1...300).contains(noBlinkInterval) {
            issues.append(SettingsIssue(
                field: .noBlinkInterval,
                message: "Blink interval must be between 1 and 300 seconds."
            ))
        }
        if autoDismissSeconds != 0, !(0.5...60).contains(autoDismissSeconds) {
            issues.append(SettingsIssue(
                field: .autoDismissSeconds,
                message: "Dismiss delay must be 0 (never) or between 0.5 and 60 seconds."
            ))
        }
        if !(30...3600).contains(idleThresholdSeconds) {
            issues.append(SettingsIssue(
                field: .idleThresholdSeconds,
                message: "Idle threshold must be between 30 and 3600 seconds."
            ))
        }
        if !(0.05...0.50).contains(lowBatteryThreshold) {
            issues.append(SettingsIssue(
                field: .lowBatteryThreshold,
                message: "Battery threshold must be between 5% and 50%."
            ))
        }
        if !(0...23).contains(quietHours.startHour) || !(0...59).contains(quietHours.startMinute) {
            issues.append(SettingsIssue(
                field: .quietHours,
                message: "Quiet-hours start time is not a valid time of day."
            ))
        }
        if !(0...23).contains(quietHours.endHour) || !(0...59).contains(quietHours.endMinute) {
            issues.append(SettingsIssue(
                field: .quietHours,
                message: "Quiet-hours end time is not a valid time of day."
            ))
        }
        if let calibrationBaseline {
            if !calibrationBaseline.isFinite || !(0.01...1.0).contains(calibrationBaseline) {
                issues.append(SettingsIssue(
                    field: .calibrationBaseline,
                    message: "Calibration baseline must be between 0.01 and 1.0."
                ))
            }
        }

        return issues
    }

    var isValid: Bool { validationIssues().isEmpty }
}

/// Aggregate only: no frames, images or landmark arrays are ever persisted.
public struct DailyAggregate: Codable, Equatable {
    public var date: Date
    public var validSeconds: Double
    public var blinkCount: Int
    public var nudgeCount: Int

    public init(date: Date, validSeconds: Double, blinkCount: Int, nudgeCount: Int) {
        self.date = date
        self.validSeconds = validSeconds
        self.blinkCount = blinkCount
        self.nudgeCount = nudgeCount
    }
}

public enum StoreError: Error, Equatable, LocalizedError {
    case invalidSettings([SettingsIssue])
    case invalidAggregate(String)
    case corruptStore(String)
    case unsupportedSchema(found: Int, latest: Int)
    case missingMigration(from: Int)
    case migrationFailed(from: Int, to: Int, reason: String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSettings(issues):
            return issues.map(\.message).joined(separator: " ")
        case let .invalidAggregate(reason):
            return "Invalid daily aggregate: \(reason)"
        case let .corruptStore(path):
            return "The Blinko data file could not be read: \(path)"
        case let .unsupportedSchema(found, latest):
            return "The Blinko data file uses schema \(found), newer than this build (\(latest))."
        case let .missingMigration(from):
            return "No migration is available from schema \(from)."
        case let .migrationFailed(from, to, reason):
            return "Could not migrate Blinko data from schema \(from) to \(to): \(reason)"
        case let .writeFailed(reason):
            return "Could not write Blinko data: \(reason)"
        }
    }
}
