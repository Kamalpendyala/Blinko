import Foundation

/// One step in the versioned store migration chain.
///
/// Migrations operate on the raw JSON object and are applied in memory. The
/// store writes the new schema only after every step succeeds, so a failure
/// leaves the previous file byte-for-byte intact (DB-03).
public struct StoreMigration {
    public let fromVersion: Int
    public let toVersion: Int
    public let apply: (inout [String: Any]) throws -> Void

    public init(
        fromVersion: Int,
        toVersion: Int,
        apply: @escaping (inout [String: Any]) throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.apply = apply
    }
}

/// Atomic, versioned JSON store.
///
/// The file is small (settings plus one row per day) and every mutation is
/// serialized on one queue, which also serializes concurrent settings writes
/// (DB-04). Writes use `Data.write(options: .atomic)`, so a crash mid-write
/// cannot leave a half-written store.
public final class JSONStore: Store {
    public static let latestSchemaVersion = 2

    public let directory: URL
    public let fileURL: URL

    private let queue = DispatchQueue(label: "blinko.store")
    private let fileManager: FileManager
    private let calendar: Calendar
    private let migrations: [StoreMigration]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var storedSchemaVersion: Int

    public init(
        directory: URL? = nil,
        fileName: String = "blinko-store.json",
        migrations: [StoreMigration] = JSONStore.defaultMigrations,
        fileManager: FileManager = .default,
        calendar: Calendar = .current
    ) throws {
        self.fileManager = fileManager
        self.calendar = calendar
        self.migrations = migrations

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()

        let directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.storedSchemaVersion = Self.latestSchemaVersion

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if !fileManager.fileExists(atPath: fileURL.path) {
            try writePayload(try defaultPayload())
        } else {
            storedSchemaVersion = (try? readPayloadVersion()) ?? Self.latestSchemaVersion
        }
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Blinko", isDirectory: true)
    }

    public static let defaultMigrations: [StoreMigration] = [
        StoreMigration(fromVersion: 1, toVersion: 2) { payload in
            var settings = payload["settings"] as? [String: Any] ?? [:]
            // v2 adds the login-item preference and the guided-calibration
            // results. Older files simply did not have these keys.
            if settings["launchAtLogin"] == nil {
                settings["launchAtLogin"] = false
            }
            if settings["calibrationBaseline"] == nil {
                settings["calibrationBaseline"] = NSNull()
            }
            if settings["calibrationDate"] == nil {
                settings["calibrationDate"] = NSNull()
            }
            payload["settings"] = settings
        }
    ]

    // MARK: - Store

    public var schemaVersion: Int {
        queue.sync { storedSchemaVersion }
    }

    public func loadSettings() throws -> Settings {
        try queue.sync {
            let payload = try currentPayload()
            let settings = try decodeSettings(from: payload)
            let issues = settings.validationIssues()
            guard issues.isEmpty else { throw StoreError.invalidSettings(issues) }
            return settings
        }
    }

    public func saveSettings(_ settings: Settings) throws {
        try queue.sync {
            try validate(settings)
            var payload = try currentPayload()
            payload["schemaVersion"] = Self.latestSchemaVersion
            payload["settings"] = try encodeObject(settings)
            try writePayload(payload)
            storedSchemaVersion = Self.latestSchemaVersion
        }
    }

    @discardableResult
    public func updateSettings(_ mutate: (inout Settings) -> Void) throws -> Settings {
        try queue.sync {
            var payload = try currentPayload()
            var settings = try decodeSettings(from: payload)
            mutate(&settings)
            try validate(settings)

            payload["schemaVersion"] = Self.latestSchemaVersion
            payload["settings"] = try encodeObject(settings)
            try writePayload(payload)
            storedSchemaVersion = Self.latestSchemaVersion
            return settings
        }
    }

    public func recordDailyAggregate(_ aggregate: DailyAggregate) throws {
        try queue.sync {
            guard aggregate.validSeconds.isFinite, aggregate.validSeconds >= 0 else {
                throw StoreError.invalidAggregate("valid seconds must be a finite, non-negative number")
            }
            guard aggregate.blinkCount >= 0, aggregate.nudgeCount >= 0 else {
                throw StoreError.invalidAggregate("counts must be non-negative")
            }

            var payload = try currentPayload()
            var aggregates = try decodeAggregates(from: payload)
            let day = calendar.startOfDay(for: aggregate.date)
            var normalized = aggregate
            normalized.date = day

            if let index = aggregates.firstIndex(where: {
                calendar.isDate($0.date, inSameDayAs: day)
            }) {
                aggregates[index] = normalized
            } else {
                aggregates.append(normalized)
            }
            aggregates.sort { $0.date < $1.date }

            payload["schemaVersion"] = Self.latestSchemaVersion
            payload["aggregates"] = try encodeObject(aggregates)
            try writePayload(payload)
            storedSchemaVersion = Self.latestSchemaVersion
        }
    }

    public func loadDailyAggregates() throws -> [DailyAggregate] {
        try queue.sync {
            let payload = try currentPayload()
            return try decodeAggregates(from: payload).sorted { $0.date < $1.date }
        }
    }

    public func deleteAllData() throws {
        try queue.sync {
            try writePayload(try defaultPayload())
            storedSchemaVersion = Self.latestSchemaVersion
        }
    }

    // MARK: - Payload

    private func defaultPayload() throws -> [String: Any] {
        [
            "schemaVersion": Self.latestSchemaVersion,
            "settings": try encodeObject(Settings()),
            "aggregates": [Any](),
        ]
    }

    private func currentPayload() throws -> [String: Any] {
        var payload = try readPayload()
        let migrated = try migrateIfNeeded(&payload)
        if migrated {
            try writePayload(payload)
            storedSchemaVersion = Self.latestSchemaVersion
        }
        return payload
    }

    private func readPayload() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return try defaultPayload()
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StoreError.corruptStore(fileURL.path)
        }

        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            throw StoreError.corruptStore(fileURL.path)
        }
        return payload
    }

    private func readPayloadVersion() throws -> Int {
        let payload = try readPayload()
        guard let version = (payload["schemaVersion"] as? NSNumber)?.intValue else {
            throw StoreError.corruptStore(fileURL.path)
        }
        return version
    }

    private func migrateIfNeeded(_ payload: inout [String: Any]) throws -> Bool {
        guard let version = (payload["schemaVersion"] as? NSNumber)?.intValue else {
            throw StoreError.corruptStore(fileURL.path)
        }
        guard version <= Self.latestSchemaVersion else {
            throw StoreError.unsupportedSchema(found: version, latest: Self.latestSchemaVersion)
        }
        guard version >= 1 else {
            throw StoreError.corruptStore(fileURL.path)
        }

        var current = version
        var changed = false

        while current < Self.latestSchemaVersion {
            guard let migration = migrations.first(where: { $0.fromVersion == current }) else {
                throw StoreError.missingMigration(from: current)
            }
            do {
                try migration.apply(&payload)
            } catch {
                throw StoreError.migrationFailed(
                    from: migration.fromVersion,
                    to: migration.toVersion,
                    reason: String(describing: error)
                )
            }
            current = migration.toVersion
            payload["schemaVersion"] = current
            changed = true
        }

        return changed
    }

    private func writePayload(_ payload: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: [.atomic])
            // The store holds only settings and counts, but keep it private
            // to the user account anyway.
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Codable helpers

    private func decodeSettings(from payload: [String: Any]) throws -> Settings {
        guard let object = payload["settings"] else {
            throw StoreError.corruptStore(fileURL.path)
        }
        return try decode(Settings.self, from: object)
    }

    private func decodeAggregates(from payload: [String: Any]) throws -> [DailyAggregate] {
        guard let raw = payload["aggregates"] else { return [] }
        guard let array = raw as? [Any] else {
            throw StoreError.corruptStore(fileURL.path)
        }
        return try decode([DailyAggregate].self, from: array)
    }

    private func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try decoder.decode(type, from: data)
        } catch {
            throw StoreError.corruptStore(fileURL.path)
        }
    }

    private func encodeObject<T: Encodable>(_ value: T) throws -> Any {
        do {
            let data = try encoder.encode(value)
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private func validate(_ settings: Settings) throws {
        let issues = settings.validationIssues()
        guard issues.isEmpty else { throw StoreError.invalidSettings(issues) }
    }
}
