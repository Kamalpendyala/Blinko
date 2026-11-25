import Testing
import Foundation
@testable import BlinkoCore

@Suite("Settings")
struct SettingsTests {
    @Test("Settings defaults use the 5 s gap and 2.5 s dismissal")
    func defaults() {
        let settings = Settings()
        #expect(settings.noBlinkInterval == 5)
        #expect(settings.autoDismissSeconds == 2.5)
        #expect(settings.burstSeconds == 12)
        #expect(settings.intervalSeconds == 60)
        #expect(settings.idleThresholdSeconds == 300)
        #expect(settings.lowBatteryThreshold == 0.20)
    }

    @Test("Adjustable intervals survive a JSON round-trip")
    func codableRoundTrip() throws {
        var settings = Settings()
        settings.noBlinkInterval = 7.5
        settings.autoDismissSeconds = 0
        settings.burstSeconds = 8
        settings.intervalSeconds = 45
        settings.idleThresholdSeconds = 120
        settings.lowBatteryThreshold = 0.3

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.autoDismissSeconds == 0)
        #expect(decoded.burstSeconds == 8)
        #expect(decoded.idleThresholdSeconds == 120)
    }

    @Test("Phase D settings fields survive a JSON round-trip")
    func phaseDFieldsRoundTrip() throws {
        var settings = Settings()
        settings.launchAtLogin = true
        settings.calibrationBaseline = 0.31
        settings.calibrationDate = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.launchAtLogin)
        #expect(decoded.calibrationBaseline == 0.31)
    }

    @Test("Older settings JSON without Phase D keys still decodes")
    func olderJSONDecodes() throws {
        let legacy = """
        {
          "paused": false,
          "burstSeconds": 8,
          "intervalSeconds": 45,
          "noBlinkInterval": 7,
          "autoDismissSeconds": 2.5,
          "idleThresholdSeconds": 300,
          "lowBatteryThreshold": 0.2,
          "quietHours": {
            "enabled": false,
            "startHour": 22,
            "startMinute": 0,
            "endHour": 8,
            "endMinute": 0
          },
          "fallbackRemindersEnabled": false,
          "soundEnabled": false
        }
        """

        let decoded = try JSONDecoder().decode(
            Settings.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.burstSeconds == 8)
        #expect(decoded.noBlinkInterval == 7)
        #expect(decoded.launchAtLogin == false)
        #expect(decoded.calibrationBaseline == nil)
    }

    @Test("Invalid values produce field-specific reasons")
    func validationIssues() {
        var settings = Settings()
        settings.burstSeconds = 0
        settings.intervalSeconds = 1
        settings.noBlinkInterval = 0
        settings.autoDismissSeconds = 0.2
        settings.idleThresholdSeconds = 10
        settings.lowBatteryThreshold = 1
        settings.quietHours.startHour = 24
        settings.calibrationBaseline = 2

        let fields = Set(settings.validationIssues().map(\.field))
        #expect(fields.contains(.burstSeconds))
        #expect(fields.contains(.intervalSeconds))
        #expect(fields.contains(.noBlinkInterval))
        #expect(fields.contains(.autoDismissSeconds))
        #expect(fields.contains(.idleThresholdSeconds))
        #expect(fields.contains(.lowBatteryThreshold))
        #expect(fields.contains(.quietHours))
        #expect(fields.contains(.calibrationBaseline))
    }

    @Test("Default settings are valid")
    func defaultsAreValid() {
        #expect(Settings().isValid)
        #expect(Settings().validationIssues().isEmpty)
    }
}
