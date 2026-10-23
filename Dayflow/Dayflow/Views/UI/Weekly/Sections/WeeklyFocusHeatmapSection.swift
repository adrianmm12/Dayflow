//
//  WeeklyFocusHeatmapSection.swift
//  Dayflow
//
//  Data models for the weekly focus-heatmap section. The section's SwiftUI
//  view was removed with the presentation-layer stripping slice; the models
//  stay because Core/Weekly dashboard builders construct them. They will
//  move (or go away with Core/Weekly) in a later stripping slice.
//

import Foundation

struct WeeklyFocusHeatmapSnapshot {
  let title: String
  let focusedLabel: String
  let distractedLabel: String
  let startMinute: Double
  let endMinute: Double
  let bucketMinutes: Double
  let timeLabels: [WeeklyWorkflowTimeLabel]
  let rows: [WeeklyFocusHeatmapRow]

  static let figmaPreview = WeeklyFocusHeatmapSnapshot(
    title: String(localized: "Focus and distraction heat map"),
    focusedLabel: String(localized: "Focused work"),
    distractedLabel: String(localized: "Distracted"),
    startMinute: 9.0 * 60.0,
    endMinute: 18.0 * 60.0,
    bucketMinutes: 5.0,
    timeLabels: [
      .init(id: "9", label: String(localized: "9am"), minute: 9.0 * 60.0),
      .init(id: "10", label: String(localized: "10am"), minute: 10.0 * 60.0),
      .init(id: "11", label: String(localized: "11am"), minute: 11.0 * 60.0),
      .init(id: "12", label: String(localized: "12pm"), minute: 12.0 * 60.0),
      .init(id: "13", label: String(localized: "1pm"), minute: 13.0 * 60.0),
      .init(id: "14", label: String(localized: "2pm"), minute: 14.0 * 60.0),
      .init(id: "15", label: String(localized: "3pm"), minute: 15.0 * 60.0),
      .init(id: "16", label: String(localized: "4pm"), minute: 16.0 * 60.0),
      .init(id: "17", label: String(localized: "5pm"), minute: 17.0 * 60.0),
      .init(id: "18", label: String(localized: "6pm"), minute: 18.0 * 60.0),
    ],
    rows: [
      .init(
        id: "sun",
        label: String(localized: "Sun"),
        values: buckets(
          runs: [
            .neutral(0..<19),
            .distracted(19..<22, 0.34),
            .neutral(22..<31),
            .focused(31..<34, 0.18),
            .neutral(34..<108),
          ]
        )
      ),
      .init(
        id: "mon",
        label: String(localized: "Mon"),
        values: buckets(
          runs: [
            .focused(2..<11, 0.20),
            .focused(11..<20, 0.78),
            .focused(20..<37, 0.42),
            .distracted(37..<41, 0.40),
            .focused(41..<49, 0.24),
            .distracted(49..<54, 0.36),
            .focused(54..<102, 0.82),
            .focused(102..<108, 0.18),
          ]
        )
      ),
      .init(
        id: "tue",
        label: String(localized: "Tue"),
        values: buckets(
          runs: [
            .focused(0..<7, 0.12),
            .focused(7..<22, 0.62),
            .focused(22..<29, 0.20),
            .focused(29..<42, 0.88),
            .distracted(42..<45, 0.44),
            .neutral(45..<53),
            .distracted(53..<57, 0.42),
            .focused(57..<103, 0.92),
            .focused(103..<108, 0.22),
          ]
        )
      ),
      .init(
        id: "wed",
        label: String(localized: "Wed"),
        values: buckets(
          runs: [
            .focused(0..<10, 0.10),
            .focused(10..<18, 0.58),
            .focused(18..<24, 0.72),
            .neutral(24..<31),
            .focused(31..<40, 0.66),
            .focused(40..<60, 0.32),
            .distracted(60..<76, 0.86),
            .neutral(76..<82),
            .distracted(82..<88, 0.62),
            .focused(88..<98, 0.54),
            .focused(98..<104, 0.24),
          ]
        )
      ),
      .init(
        id: "thu",
        label: String(localized: "Thu"),
        values: buckets(
          runs: [
            .focused(8..<14, 0.96),
            .distracted(14..<19, 0.32),
            .neutral(19..<22),
            .focused(22..<40, 0.94),
            .neutral(40..<58),
            .distracted(58..<73, 0.92),
            .neutral(73..<83),
            .focused(83..<101, 0.88),
            .focused(101..<105, 0.24),
          ]
        )
      ),
      .init(
        id: "fri",
        label: String(localized: "Fri"),
        values: buckets(
          runs: [
            .focused(0..<5, 0.24),
            .focused(5..<9, 0.54),
            .distracted(9..<12, 0.48),
            .focused(12..<17, 0.32),
            .focused(17..<23, 0.86),
            .distracted(23..<27, 0.72),
            .neutral(27..<33),
            .focused(33..<49, 0.90),
            .focused(49..<58, 0.46),
            .neutral(58..<69),
            .focused(69..<84, 0.84),
            .focused(84..<98, 0.46),
            .focused(98..<103, 0.16),
          ]
        )
      ),
      .init(
        id: "sat",
        label: String(localized: "Sat"),
        values: buckets(
          runs: [
            .neutral(0..<6),
            .focused(6..<10, 0.24),
            .neutral(10..<45),
            .focused(45..<49, 0.34),
            .focused(49..<53, 0.54),
            .focused(53..<58, 0.34),
            .neutral(58..<108),
          ]
        )
      ),
    ]
  )

  private enum Run {
    case neutral(Range<Int>)
    case focused(Range<Int>, Double)
    case distracted(Range<Int>, Double)
  }

  private static func buckets(runs: [Run]) -> [Double] {
    var values = Array(repeating: 0.0, count: 108)

    for run in runs {
      switch run {
      case .neutral(let range):
        for index in range where values.indices.contains(index) {
          values[index] = 0
        }
      case .focused(let range, let intensity):
        for index in range where values.indices.contains(index) {
          values[index] = -intensity
        }
      case .distracted(let range, let intensity):
        for index in range where values.indices.contains(index) {
          values[index] = intensity
        }
      }
    }

    return values
  }
}

struct WeeklyFocusHeatmapRow: Identifiable {
  let id: String
  let label: String
  let values: [Double]
}
