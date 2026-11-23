import Foundation

/// Injectable seam for persistence (JSON implementation lands in Phase D).
public protocol Store: AnyObject {
    var schemaVersion: Int { get }
    func loadSettings() throws -> Settings
    func saveSettings(_ settings: Settings) throws
    func recordDailyAggregate(_ aggregate: DailyAggregate) throws
    func loadDailyAggregates() throws -> [DailyAggregate]
    func deleteAllData() throws
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
}

public struct Settings: Codable, Equatable {
    public var paused: Bool
    public var burstSeconds: Double
    public var intervalSeconds: Double
    public var quietHours: QuietHours
    public var fallbackRemindersEnabled: Bool
    public var soundEnabled: Bool

    public init(
        paused: Bool = false,
        burstSeconds: Double = 12,
        intervalSeconds: Double = 60,
        quietHours: QuietHours = QuietHours(),
        fallbackRemindersEnabled: Bool = false,
        soundEnabled: Bool = false
    ) {
        self.paused = paused
        self.burstSeconds = burstSeconds
        self.intervalSeconds = intervalSeconds
        self.quietHours = quietHours
        self.fallbackRemindersEnabled = fallbackRemindersEnabled
        self.soundEnabled = soundEnabled
    }
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
