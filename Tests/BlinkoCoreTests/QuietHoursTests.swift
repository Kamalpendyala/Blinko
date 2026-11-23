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
}
