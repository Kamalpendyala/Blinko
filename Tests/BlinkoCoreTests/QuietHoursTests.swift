import Testing
import Foundation
@testable import BlinkoCore

@Suite("QuietHours")
struct QuietHoursTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 23, hour: hour, minute: minute)
        )!
    }

    @Test("QH-01 a 22:00–08:00 window covers 23:30 and 07:59 but not 08:00")
    func qh01Window() {
        let quiet = QuietHours(enabled: true, startHour: 22, startMinute: 0, endHour: 8, endMinute: 0)

        #expect(quiet.isActive(at: date(23, 30), calendar: calendar))
        #expect(quiet.isActive(at: date(7, 59), calendar: calendar))
        #expect(quiet.isActive(at: date(8, 0), calendar: calendar) == false)
        #expect(quiet.isActive(at: date(12, 0), calendar: calendar) == false)
        #expect(quiet.isActive(at: date(22, 0), calendar: calendar))
    }

    @Test("QH-02 windows that wrap midnight and zero-length windows are handled")
    func qh02WrapAndZeroLength() {
        let overnight = QuietHours(enabled: true, startHour: 23, startMinute: 0, endHour: 2, endMinute: 0)
        #expect(overnight.isActive(at: date(23, 30), calendar: calendar))
        #expect(overnight.isActive(at: date(1, 59), calendar: calendar))
        #expect(overnight.isActive(at: date(2, 0), calendar: calendar) == false)
        #expect(overnight.isActive(at: date(12, 0), calendar: calendar) == false)

        let disabled = QuietHours(enabled: false, startHour: 22, startMinute: 0, endHour: 8, endMinute: 0)
        #expect(disabled.isActive(at: date(23, 0), calendar: calendar) == false)

        let zeroLength = QuietHours(enabled: true, startHour: 8, startMinute: 0, endHour: 8, endMinute: 0)
        #expect(zeroLength.isActive(at: date(8, 0), calendar: calendar) == false)
    }

    @Test("QH-03 DST spring-forward does not crash or double-fire")
    func qh03SpringForward() {
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/New_York")!

        // 02:30 does not exist on 2026-03-08; Calendar normalizes it to 03:30.
        let nonexistent = dst.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 2, minute: 30)
        )
        #expect(nonexistent != nil)
        let normalized = dst.dateComponents([.hour], from: nonexistent!).hour
        #expect(normalized == 3)

        let quiet = QuietHours(enabled: true, startHour: 2, endHour: 4)
        #expect(quiet.isActive(at: nonexistent!, calendar: dst))
        let after = dst.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 5, minute: 0))!
        #expect(quiet.isActive(at: after, calendar: dst) == false)

        // A window covering both sides of the jump stays active once.
        let wide = QuietHours(enabled: true, startHour: 1, endHour: 4)
        let before = dst.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30))!
        #expect(wide.isActive(at: before, calendar: dst))
        #expect(wide.isActive(at: nonexistent!, calendar: dst))
    }

    @Test("QH-04 both repeated hours on DST fall-back evaluate identically")
    func qh04FallBack() {
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/New_York")!

        let formatter = ISO8601DateFormatter()
        let first = formatter.date(from: "2026-11-01T01:30:00-04:00")! // EDT
        let second = formatter.date(from: "2026-11-01T01:30:00-05:00")! // EST
        #expect(first != second)

        let quiet = QuietHours(enabled: true, startHour: 1, endHour: 2)
        #expect(quiet.isActive(at: first, calendar: dst))
        #expect(quiet.isActive(at: second, calendar: dst))
        #expect(quiet.isActive(at: first, calendar: dst) == quiet.isActive(at: second, calendar: dst))

        // A repeated hour cannot produce two reminders on its own: the policy's
        // cooldown still applies (NP-03).
        let policy = NudgePolicy(config: NudgePolicyConfig(fallbackInterval: 2 * 3600))
        #expect(policy.evaluateFallback(now: first.timeIntervalSince1970, enabled: true, cameraUnavailable: true) == .none)
        #expect(policy.evaluateFallback(now: second.timeIntervalSince1970, enabled: true, cameraUnavailable: true) == .none)
    }

    @Test("QH-05 a time-zone change recomputes the quiet window")
    func qh05TimeZoneChange() {
        let instant = ISO8601DateFormatter().date(from: "2026-11-23T23:30:00Z")!
        let quiet = QuietHours(enabled: true, startHour: 22, endHour: 8)

        // 23:30 UTC is inside; the same instant is 15:30 in Los Angeles.
        #expect(quiet.isActive(at: instant, calendar: calendar))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(quiet.isActive(at: instant, calendar: losAngeles) == false)
    }
}
