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
}
