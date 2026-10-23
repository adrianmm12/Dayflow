//
//  WeeklyContextChartsSection.swift
//  Dayflow
//
//  Data models for the weekly context-charts section. The section's SwiftUI
//  view was removed with the presentation-layer stripping slice; the models
//  stay because Core/Weekly dashboard builders construct them. They will
//  move (or go away with Core/Weekly) in a later stripping slice.
//

import Foundation

struct WeeklyContextChartsSnapshot {
  let distribution: WeeklyContextDistributionSnapshot
  let comparison: WeeklyContextComparisonSnapshot

  static let figmaPreview = WeeklyContextChartsSnapshot(
    distribution: .figmaPreview,
    comparison: .figmaPreview
  )
}

struct WeeklyContextDistributionSnapshot {
  let days: [String]
  let start: String
  let end: String
  let events: [WeeklyContextDistributionEvent]

  static let figmaPreview = WeeklyContextDistributionSnapshot(
    days: ["Mon", "Tue", "Wed", "Thur", "Fri", "Sat", "Sun"],
    start: "10:00",
    end: "18:00",
    events: [
      .init(day: "Mon", kind: .context, time: "10:45"),
      .init(day: "Mon", kind: .distraction, time: "11:55"),
      .init(day: "Mon", kind: .context, time: "13:55"),
      .init(day: "Mon", kind: .distraction, time: "15:08"),
      .init(day: "Mon", kind: .context, time: "16:40"),
      .init(day: "Tue", kind: .context, time: "12:55"),
      .init(day: "Tue", kind: .distraction, time: "14:45"),
      .init(day: "Tue", kind: .context, time: "15:50"),
      .init(day: "Wed", kind: .distraction, time: "10:55"),
      .init(day: "Wed", kind: .context, time: "11:45"),
      .init(day: "Wed", kind: .distraction, time: "13:20"),
      .init(day: "Wed", kind: .context, time: "14:55"),
      .init(day: "Wed", kind: .distraction, time: "15:55"),
      .init(day: "Thu", kind: .distraction, time: "11:20"),
      .init(day: "Thu", kind: .context, time: "14:15"),
      .init(day: "Thu", kind: .distraction, time: "16:18"),
      .init(day: "Fri", kind: .distraction, time: "10:28"),
      .init(day: "Fri", kind: .distraction, time: "11:55"),
      .init(day: "Fri", kind: .distraction, time: "14:20"),
      .init(day: "Fri", kind: .context, time: "16:58"),
      .init(day: "Sat", kind: .context, time: "12:10"),
      .init(day: "Sun", kind: .distraction, time: "15:35"),
    ]
  )
}

struct WeeklyContextDistributionEvent: Identifiable {
  let id = UUID()
  let day: String
  let kind: WeeklyContextEventKind
  let time: String
}

enum WeeklyContextEventKind {
  case context
  case distraction
}

struct WeeklyContextComparisonSnapshot {
  let days: [WeeklyContextComparisonDay]
  let insight: String

  static let figmaPreview = WeeklyContextComparisonSnapshot(
    days: [
      .init(day: "Mon", distracted: 12, shifts: 15),
      .init(day: "Tue", distracted: 8, shifts: 10),
      .init(day: "Wed", distracted: 16, shifts: 28),
      .init(day: "Thur", distracted: 12, shifts: 5),
      .init(day: "Fri", distracted: 3, shifts: 10),
      .init(day: "Sat", distracted: 12, shifts: 12),
      .init(day: "Sun", distracted: 6, shifts: 8),
    ],
    insight:
      String(
        localized: "Tue had the most interruptions, with 22 context shifts and 53 distractions.")
  )
}

struct WeeklyContextComparisonDay: Identifiable {
  let id = UUID()
  let day: String
  let distracted: Int
  let shifts: Int
}
