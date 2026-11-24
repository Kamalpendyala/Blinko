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
    }

    @Test("Adjustable intervals survive a JSON round-trip")
    func codableRoundTrip() throws {
        var settings = Settings()
        settings.noBlinkInterval = 7.5
        settings.autoDismissSeconds = 0

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.autoDismissSeconds == 0)
    }
}
