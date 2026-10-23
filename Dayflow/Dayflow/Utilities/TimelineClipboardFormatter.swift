import Foundation

/// Builds the plain-text and Markdown exports of the timeline. Labels, headings
/// and dates are localized; card titles, summaries and the stored "h:mm a" card
/// times are copied through exactly as stored.
struct TimelineClipboardFormatter {
  static func makeClipboardText(for date: Date, cards: [TimelineCard], now: Date = Date()) -> String
  {
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let header = exportHeader(formattedTimelineDay(timelineDate, now: now))

    guard !cards.isEmpty else {
      return [header, String(localized: "No timeline activities were recorded for this day.")]
        .joined(separator: "\n\n")
    }

    let entries = cards.enumerated().map { index, card in
      textEntry(for: card, index: index)
    }

    return ([header, ""] + entries).joined(separator: "\n\n")
  }

  static func makeClipboardText(
    for weekRange: TimelineWeekRange,
    cards: [TimelineCard],
    now: Date = Date()
  ) -> String {
    let header = exportHeader(weekRange.title)

    guard !cards.isEmpty else {
      return [header, String(localized: "No timeline activities were recorded for this week.")]
        .joined(separator: "\n\n")
    }

    let cardsByDay = Dictionary(grouping: cards, by: \.day)
    let sections = weekRange.days.compactMap { day -> String? in
      guard let dayCards = cardsByDay[day.dayString], !dayCards.isEmpty else { return nil }

      let sortedCards = dayCards.sorted(by: cardSort)
      let heading = formattedTimelineDay(day.date, now: now)
      let entries = sortedCards.enumerated().map { index, card in
        textEntry(for: card, index: index)
      }

      return ([heading, ""] + entries).joined(separator: "\n\n")
    }

    return ([header, ""] + sections).joined(separator: "\n\n")
  }

  static func makeMarkdown(for date: Date, cards: [TimelineCard], now: Date = Date()) -> String {
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let header = "## " + exportHeader(formattedTimelineDay(timelineDate, now: now))

    guard !cards.isEmpty else {
      let emptyMessage = String(localized: "No timeline activities were recorded for this day.")
      return [header, "_\(emptyMessage)_"].joined(separator: "\n\n")
    }

    let summaryLabel = String(localized: "Summary")
    let detailsLabel = String(localized: "Details")

    let entries = cards.enumerated().map { index, card -> String in
      var lines: [String] = []

      let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
      let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let bulletTitle = timeRange.isEmpty ? titleText : "\(timeRange) — \(titleText)"
      lines.append("\(index + 1). **\(bulletTitle)**")

      let metaParts = metadataParts(for: card)
      if !metaParts.isEmpty {
        lines.append("   - _\(metaParts.joined(separator: " • "))_")
      }

      if let summary = cleanedParagraph(card.summary) {
        let summaryLines = normalizedLines(summary)
        if summaryLines.count == 1 {
          lines.append("   - \(summaryLabel): \(summaryLines[0])")
        } else {
          lines.append("   - \(summaryLabel):")
          summaryLines.forEach { lines.append("      \($0)") }
        }
      }

      if let details = cleanedParagraph(card.detailedSummary),
        details != cleanedParagraph(card.summary)
      {
        let detailLines = normalizedLines(details)
        if detailLines.count == 1 {
          lines.append("   - \(detailsLabel): \(detailLines[0])")
        } else {
          lines.append("   - \(detailsLabel):")
          detailLines.forEach { lines.append("      \($0)") }
        }
      }

      return lines.joined(separator: "\n")
    }

    return ([header, ""] + entries).joined(separator: "\n\n")
  }

  /// "Dayflow timeline · <day or week>" in the current language.
  private static func exportHeader(_ period: String) -> String {
    String(
      localized: "Dayflow timeline · \(period)",
      comment:
        "First line of the copied/exported timeline. The argument is a formatted day or week range."
    )
  }

  private static func formattedRange(start: String, end: String) -> String {
    let trimmedStart = start.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEnd = end.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedStart.isEmpty && trimmedEnd.isEmpty { return "" }
    if trimmedEnd.isEmpty { return trimmedStart }
    if trimmedStart.isEmpty { return trimmedEnd }
    return "\(trimmedStart) – \(trimmedEnd)"
  }

  private static func metadataParts(for card: TimelineCard) -> [String] {
    var parts: [String] = []
    let category = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
    if !category.isEmpty {
      parts.append(category)
    }
    return parts
  }

  private static func block(label: String, text: String) -> String {
    let lines = normalizedLines(text)
    guard !lines.isEmpty else { return "" }
    if lines.count == 1 {
      return "   \(label): \(lines[0])"
    } else {
      var blockLines: [String] = ["   \(label):"]
      for line in lines {
        blockLines.append("      \(line)")
      }
      return blockLines.joined(separator: "\n")
    }
  }

  private static func cleanedParagraph(_ value: String?) -> String? {
    guard let value = value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lines = normalizedLines(trimmed)
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n")
  }

  private static func normalizedLines(_ text: String) -> [String] {
    return
      text
      .components(separatedBy: CharacterSet.newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Abbreviated month and day, e.g. "Sep 11" / "11. Sept." / "9月11日".
  private static let todayDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  /// Full weekday plus abbreviated month and day, e.g. "Thursday, Sep 11".
  private static let otherDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
    return formatter
  }()

  private static func formattedTimelineDay(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let timelineToday = timelineDisplayDate(from: now, now: now)

    if calendar.isDate(date, inSameDayAs: timelineToday) {
      return String(localized: "Today, \(todayDayFormatter.string(from: date))")
    }
    return otherDayFormatter.string(from: date)
  }

  private static func textEntry(for card: TimelineCard, index: Int) -> String {
    var lines: [String] = []

    let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
    let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let bullet = "\(index + 1). \(timeRange.isEmpty ? "" : "\(timeRange) — ")\(titleText)"
    lines.append(bullet.trimmingCharacters(in: .whitespaces))

    let metaParts = metadataParts(for: card)
    if !metaParts.isEmpty {
      lines.append("   " + metaParts.joined(separator: " • "))
    }

    if let summary = cleanedParagraph(card.summary) {
      lines.append(block(label: String(localized: "Summary"), text: summary))
    }

    if let details = cleanedParagraph(card.detailedSummary),
      details != cleanedParagraph(card.summary)
    {
      lines.append(block(label: String(localized: "Details"), text: details))
    }

    return lines.joined(separator: "\n")
  }

  private static func cardSort(lhs: TimelineCard, rhs: TimelineCard) -> Bool {
    if lhs.day != rhs.day {
      return lhs.day < rhs.day
    }
    if let leftDate = sortDate(for: lhs), let rightDate = sortDate(for: rhs), leftDate != rightDate
    {
      return leftDate < rightDate
    }
    return lhs.title < rhs.title
  }

  private static func sortDate(for card: TimelineCard) -> Date? {
    guard
      let dayDate = DateFormatter.yyyyMMdd.date(from: card.day),
      let parsedStart = timeFormatter.date(from: card.startTimestamp)
    else {
      return nil
    }

    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute], from: parsedStart)
    return calendar.date(
      bySettingHour: components.hour ?? 0,
      minute: components.minute ?? 0,
      second: 0,
      of: dayDate
    )
  }

  /// Parser for the stored English "h:mm a" card times. Not a display formatter.
  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
}

// MARK: - Timeline day helpers
//
// Moved verbatim from the presentation layer (Views/UI/MainView/Support.swift
// and Views/UI/MainView/TimelineShellModels.swift) so the clipboard exports
// keep their timeline-day semantics (a day runs 4am to 4am) without depending
// on UI code.

func normalizedTimelineDate(_ date: Date) -> Date {
  let calendar = Calendar.current
  if let normalized = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) {
    return normalized
  }
  let startOfDay = calendar.startOfDay(for: date)
  return calendar.date(byAdding: DateComponents(hour: 12), to: startOfDay) ?? date
}

func timelineDisplayDate(from date: Date, now: Date = Date()) -> Date {
  let calendar = Calendar.current
  var normalizedDate = normalizedTimelineDate(date)
  let normalizedNow = normalizedTimelineDate(now)
  let nowHour = calendar.component(.hour, from: now)

  if nowHour < 4 && calendar.isDate(normalizedDate, inSameDayAs: normalizedNow) {
    normalizedDate = calendar.date(byAdding: .day, value: -1, to: normalizedDate) ?? normalizedDate
  }

  return normalizedDate
}

// MARK: - Timeline week range

struct TimelineWeekDay: Identifiable, Equatable, Sendable {
  let date: Date
  let dayString: String
  let weekdayLabel: String
  let dayNumber: String

  var id: String { dayString }
}

struct TimelineWeekRange: Equatable, Sendable {
  let weekStart: Date
  let weekEnd: Date
  let days: [TimelineWeekDay]

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    calendar.firstWeekday = 2
    return calendar
  }()

  private static let titleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMMd")
    return formatter
  }()

  private static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "E"
    return formatter
  }()

  private static let dayNumberFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d"
    return formatter
  }()

  private init(weekStart: Date, weekEnd: Date) {
    self.weekStart = weekStart
    self.weekEnd = weekEnd
    self.days = Self.buildDays(weekStart: weekStart)
  }

  private static func buildDays(weekStart: Date) -> [TimelineWeekDay] {
    let calendar = Self.calendar
    return (0..<7).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
        return nil
      }
      let normalizedDate = normalizedTimelineDate(date)
      return TimelineWeekDay(
        date: normalizedDate,
        dayString: DateFormatter.yyyyMMdd.string(from: normalizedDate),
        weekdayLabel: Self.weekdayFormatter.string(from: normalizedDate),
        dayNumber: Self.dayNumberFormatter.string(from: normalizedDate)
      )
    }
  }

  static func containing(_ date: Date, calendar: Calendar = Self.calendar) -> TimelineWeekRange {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let anchorDay = calendar.startOfDay(for: timelineDate)
    let weekday = calendar.component(.weekday, from: anchorDay)
    let daysFromWeekStart = (weekday - calendar.firstWeekday + 7) % 7
    let weekStartDay =
      calendar.date(byAdding: .day, value: -daysFromWeekStart, to: anchorDay)
      ?? anchorDay
    let weekStart =
      calendar.date(bySettingHour: 4, minute: 0, second: 0, of: weekStartDay) ?? weekStartDay
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    return TimelineWeekRange(weekStart: weekStart, weekEnd: weekEnd)
  }

  func shifted(byWeeks weeks: Int, calendar: Calendar = Self.calendar) -> TimelineWeekRange {
    let shiftedStart = calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) ?? weekStart
    let shiftedEnd = calendar.date(byAdding: .day, value: 7, to: shiftedStart) ?? shiftedStart
    return TimelineWeekRange(weekStart: shiftedStart, weekEnd: shiftedEnd)
  }

  var title: String {
    let displayedWeekEnd = Self.calendar.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd
    return
      String(
        localized:
          "\(Self.titleFormatter.string(from: weekStart)) - \(Self.titleFormatter.string(from: displayedWeekEnd))"
      )
  }

  var canNavigateForward: Bool {
    weekStart < Self.containing(Date()).weekStart
  }

  var containsToday: Bool {
    contains(Date())
  }

  func contains(_ date: Date) -> Bool {
    let timelineDate = timelineDisplayDate(from: date, now: date)
    let dayStart = timelineDate.getDayInfoFor4AMBoundary().startOfDay
    return dayStart >= weekStart && dayStart < weekEnd
  }
}
