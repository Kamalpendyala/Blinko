import Testing
import Foundation
@testable import BlinkoCore

private enum TestFailure: Error {
    case boom
}

private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@Suite("Persistence")
struct PersistenceTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blinko-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure.boom
        }
        return object
    }

    private func writeV1Store(
        to directory: URL,
        settings: Settings,
        aggregates: [DailyAggregate]
    ) throws {
        var settingsObject = try jsonObject(settings)
        // v1 predates the login-item preference and calibration results.
        settingsObject.removeValue(forKey: "launchAtLogin")
        settingsObject.removeValue(forKey: "calibrationBaseline")
        settingsObject.removeValue(forKey: "calibrationDate")

        let aggregateObjects = try aggregates.map { try jsonObject($0) }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "settings": settingsObject,
            "aggregates": aggregateObjects,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: directory.appendingPathComponent("blinko-store.json"))
    }

    private func readPayload(_ directory: URL) throws -> [String: Any] {
        let data = try Data(
            contentsOf: directory.appendingPathComponent("blinko-store.json")
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure.boom
        }
        return object
    }

    @Test("DB-01 fresh install starts at the latest schema")
    func freshInstall() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        let store = try JSONStore(directory: directory)
        #expect(store.schemaVersion == JSONStore.latestSchemaVersion)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try store.loadSettings() == Settings())
        #expect(try store.loadDailyAggregates().isEmpty)
    }

    @Test("DB-02 migration v1→v2 preserves data and bumps the version")
    func migrationPreservesData() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        var settings = Settings(burstSeconds: 8, intervalSeconds: 45, noBlinkInterval: 7)
        settings.soundEnabled = true
        settings.quietHours = QuietHours(
            enabled: true,
            startHour: 23,
            startMinute: 15,
            endHour: 7,
            endMinute: 30
        )
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let aggregate = DailyAggregate(
            date: day,
            validSeconds: 42,
            blinkCount: 9,
            nudgeCount: 2
        )

        try writeV1Store(to: directory, settings: settings, aggregates: [aggregate])

        let store = try JSONStore(directory: directory)
        let loaded = try store.loadSettings()
        #expect(store.schemaVersion == JSONStore.latestSchemaVersion)
        #expect(loaded.burstSeconds == 8)
        #expect(loaded.intervalSeconds == 45)
        #expect(loaded.noBlinkInterval == 7)
        #expect(loaded.soundEnabled)
        #expect(loaded.quietHours == settings.quietHours)
        #expect(loaded.launchAtLogin == false)

        let aggregates = try store.loadDailyAggregates()
        #expect(aggregates.count == 1)
        #expect(aggregates[0].validSeconds == 42)
        #expect(aggregates[0].blinkCount == 9)
        #expect(aggregates[0].nudgeCount == 2)

        let payload = try readPayload(directory)
        #expect((payload["schemaVersion"] as? NSNumber)?.intValue == 2)
    }

    @Test("DB-03 failed migration leaves the old file intact and the app starts")
    func failedMigrationRollsBack() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        let settings = Settings(burstSeconds: 8, intervalSeconds: 45)
        try writeV1Store(to: directory, settings: settings, aggregates: [])
        let before = try Data(
            contentsOf: directory.appendingPathComponent("blinko-store.json")
        )

        let failing = [
            StoreMigration(fromVersion: 1, toVersion: 2) { _ in
                throw TestFailure.boom
            }
        ]
        let store = try JSONStore(directory: directory, migrations: failing)

        #expect(throws: StoreError.self) {
            try store.loadSettings()
        }

        let after = try Data(
            contentsOf: directory.appendingPathComponent("blinko-store.json")
        )
        #expect(before == after)

        let payload = try readPayload(directory)
        #expect((payload["schemaVersion"] as? NSNumber)?.intValue == 1)
        // The app still starts with defaults.
        #expect(store.loadSettingsOrDefaults() == Settings())
    }

    @Test("DB-04 concurrent settings updates serialize without lost updates")
    func concurrentWrites() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        let store = try JSONStore(directory: directory)
        var initial = Settings()
        initial.idleThresholdSeconds = 30
        try store.saveSettings(initial)
        try store.recordDailyAggregate(
            DailyAggregate(
                date: Date(),
                validSeconds: 12,
                blinkCount: 4,
                nudgeCount: 1
            )
        )

        let failures = FailureCounter()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            do {
                _ = try store.updateSettings { $0.idleThresholdSeconds += 1 }
            } catch {
                failures.increment()
            }
        }

        #expect(failures.count == 0)
        let loaded = try store.loadSettings()
        #expect(loaded.idleThresholdSeconds == 80)
        #expect(try store.loadDailyAggregates().count == 1)
    }

    @Test("DB-05 invalid settings are rejected with a reason")
    func invalidSettingsRejected() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        let store = try JSONStore(directory: directory)
        var invalid = Settings()
        invalid.burstSeconds = 1
        invalid.intervalSeconds = 0.5
        invalid.lowBatteryThreshold = 2

        do {
            try store.saveSettings(invalid)
            Issue.record("Expected invalid settings to be rejected")
        } catch let StoreError.invalidSettings(issues) {
            #expect(issues.contains { $0.field == .burstSeconds })
            #expect(issues.contains { $0.field == .intervalSeconds })
            #expect(issues.contains { $0.field == .lowBatteryThreshold })
            #expect(issues.allSatisfy { !$0.message.isEmpty })
        }

        // The bad write did not touch the file.
        #expect(try store.loadSettings() == Settings())
    }

    @Test("DB-06 delete all data empties the store and restores defaults")
    func deleteAllData() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        let store = try JSONStore(directory: directory)
        var custom = Settings()
        custom.noBlinkInterval = 12
        custom.launchAtLogin = true
        custom.calibrationBaseline = 0.31
        custom.calibrationDate = Date()
        try store.saveSettings(custom)
        try store.recordDailyAggregate(
            DailyAggregate(
                date: Date(),
                validSeconds: 30,
                blinkCount: 7,
                nudgeCount: 3
            )
        )

        try store.deleteAllData()

        #expect(try store.loadSettings() == Settings())
        #expect(try store.loadDailyAggregates().isEmpty)
        #expect(store.schemaVersion == JSONStore.latestSchemaVersion)
    }

    @Test("DB-07 store contains no frames, images or landmarks")
    func storeContainsOnlyAggregates() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }

        let store = try JSONStore(directory: directory)
        var settings = Settings()
        settings.calibrationBaseline = 0.29
        settings.calibrationDate = Date()
        try store.saveSettings(settings)
        try store.recordDailyAggregate(
            DailyAggregate(
                date: Date(),
                validSeconds: 12,
                blinkCount: 3,
                nudgeCount: 1
            )
        )

        let data = try Data(contentsOf: store.fileURL)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["frame", "image", "landmark", "pixel", "base64", "points"] {
            #expect(!text.contains(forbidden))
        }

        let payload = try readPayload(directory)
        #expect(Set(payload.keys) == Set(["schemaVersion", "settings", "aggregates"]))
        let aggregates = try #require(payload["aggregates"] as? [[String: Any]])
        #expect(aggregates.count == 1)
        #expect(
            Set(aggregates[0].keys)
                == Set(["date", "validSeconds", "blinkCount", "nudgeCount"])
        )
    }
}
