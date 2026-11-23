import Foundation

extension QuietHours {
    /// Whether `date` falls inside the configured quiet window.
    ///
    /// Windows that cross midnight are supported (QH-02). A zero-length window
    /// is treated as disabled so it cannot suppress reminders all day. The
    /// calendar supplies the time zone, so a zone change is picked up on the
    /// next evaluation.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }

        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        guard start != end else { return false }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if start < end {
            return minuteOfDay >= start && minuteOfDay < end
        }
        return minuteOfDay >= start || minuteOfDay < end
    }
}
