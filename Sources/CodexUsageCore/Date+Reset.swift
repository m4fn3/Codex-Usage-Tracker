//
//  Date+Reset.swift
//  Codex Usage Tracker
//
//  Formats a reset moment as a clock time (like Claude Usage Tracker):
//  "Today 3:59am" / "Tomorrow 3:59am" / "Oct 28, 12:59pm". Honors the system
//  12/24-hour preference.
//

import Foundation

extension Date {
    public func resetClockString(timezone: TimeZone = .current) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.timeZone = timezone

        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        let use24h = !template.contains("a")
        let timeFmt = use24h ? "HH:mm" : "h:mma"

        if calendar.isDateInToday(self) {
            formatter.dateFormat = "'Today' \(timeFmt)"
        } else if calendar.isDateInTomorrow(self) {
            formatter.dateFormat = "'Tomorrow' \(timeFmt)"
        } else {
            formatter.dateFormat = "MMM d, \(timeFmt)"
        }
        return formatter.string(from: self)
    }
}
