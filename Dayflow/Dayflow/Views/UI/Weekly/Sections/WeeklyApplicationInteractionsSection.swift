//
//  WeeklyApplicationInteractionsSection.swift
//  Dayflow
//
//  Data models for the weekly application-interactions section. The section's
//  SwiftUI view was removed with the presentation-layer stripping slice; the
//  models stay because Core/Weekly dashboard builders construct them. They
//  will move (or go away with Core/Weekly) in a later stripping slice.
//

import SwiftUI

struct WeeklyApplicationInteractionsSnapshot {
  let subtitle: String
  let nodes: [WeeklyApplicationNode]
  let edges: [WeeklyApplicationEdge]
  let patterns: [WeeklyWorkPattern]
  let rabbitHole: WeeklyRabbitHoleSnapshot

  static let figmaPreview = WeeklyApplicationInteractionsSnapshot(
    subtitle: String(
      localized: "More than 80% of recorded time was spent using these applications."),
    nodes: [
      .init(
        id: "figma", name: "Figma", x: 256.5, y: 253.3, size: 76, kind: .work, mark: "F",
        isPrimary: true),
      .init(
        id: "slack", name: "Slack", x: 106.5, y: 411.3, size: 48, kind: .work, mark: "S",
        isMuted: true),
      .init(
        id: "runway", name: "Runway", x: 134, y: 154.3, size: 57, kind: .work, mark: "R",
        isMuted: true),
      .init(
        id: "flora", name: "Flora", x: 220, y: 136.8, size: 41, kind: .work, mark: "F",
        isMuted: true),
      .init(id: "x", name: "X", x: 308.5, y: 167.8, size: 48, kind: .distraction, mark: "X"),
      .init(
        id: "substack", name: "Substack", x: 342.5, y: 108.8, size: 36, kind: .distraction,
        mark: "S"),
      .init(id: "reddit", name: "Reddit", x: 436.1, y: 142.8, size: 34, kind: .personal, mark: "R"),
      .init(
        id: "youtube", name: "YouTube", x: 501.5, y: 255.8, size: 48, kind: .distraction, mark: "Y"),
      .init(
        id: "cube", name: "Workspace", x: 391.1, y: 310.8, size: 49, kind: .work, mark: "C",
        isMuted: true),
      .init(
        id: "claude", name: "Claude", x: 391.5, y: 415.8, size: 56, kind: .personal, mark: "C",
        isMuted: true),
      .init(
        id: "chatgpt", name: "ChatGPT", x: 296, y: 380.3, size: 33, kind: .personal, mark: "G",
        isMuted: true),
      .init(
        id: "notion", name: "Notion", x: 62, y: 304.8, size: 31, kind: .work, mark: "N",
        isMuted: true),
      .init(
        id: "clock", name: "Calendar", x: 111, y: 233.8, size: 37, kind: .work, mark: "C",
        isMuted: true),
      .init(
        id: "browser", name: "Browser", x: 179.5, y: 343.3, size: 30, kind: .work, mark: "B",
        isMuted: true),
    ],
    edges: [
      .init(from: "runway", to: "flora", kind: .work, weight: 0.5, curveOffset: -20),
      .init(from: "runway", to: "figma", kind: .work, weight: 0.9, curveOffset: -42),
      .init(from: "flora", to: "figma", kind: .work, weight: 0.72, curveOffset: 24),
      .init(from: "notion", to: "figma", kind: .work, weight: 0.64, curveOffset: -30),
      .init(from: "slack", to: "figma", kind: .work, weight: 0.82, curveOffset: -55),
      .init(from: "browser", to: "figma", kind: .work, weight: 0.46, curveOffset: -24),
      .init(from: "figma", to: "x", kind: .work, weight: 0.78, curveOffset: -38),
      .init(from: "x", to: "substack", kind: .distraction, weight: 0.64, curveOffset: -14),
      .init(from: "substack", to: "reddit", kind: .distraction, weight: 0.5, curveOffset: -22),
      .init(from: "x", to: "youtube", kind: .distraction, weight: 0.74, curveOffset: -62),
      .init(from: "reddit", to: "youtube", kind: .personal, weight: 0.3, curveOffset: 30),
      .init(from: "figma", to: "youtube", kind: .distraction, weight: 0.72, curveOffset: -22),
      .init(from: "figma", to: "cube", kind: .work, weight: 0.34, curveOffset: 20),
      .init(from: "figma", to: "claude", kind: .work, weight: 0.54, curveOffset: 52),
      .init(from: "figma", to: "chatgpt", kind: .personal, weight: 0.3, curveOffset: 26),
      .init(from: "cube", to: "claude", kind: .personal, weight: 0.26, curveOffset: 8),
      .init(from: "slack", to: "browser", kind: .work, weight: 0.42, curveOffset: -10),
      .init(from: "chatgpt", to: "claude", kind: .personal, weight: 0.32, curveOffset: -14),
    ],
    patterns: [
      WeeklyWorkPattern(
        id: "slack-figma",
        from: .slack(avg: "12m avg"),
        via: nil,
        to: .figma(avg: "1h 25m avg"),
        count: 9,
        description:
          String(
            localized:
              "Moves between communicating on project progress on Slack and designing mockups on Figma an average of 9 times per day."
          )
      ),
      WeeklyWorkPattern(
        id: "runway-flora-figma",
        from: .runway(avg: "32m avg"),
        via: .flora(),
        to: .figma(avg: "42m avg"),
        count: 4,
        description:
          String(
            localized:
              "Moves between generating visuals on xyz and designing mockups on Figma an average of 4 times per day."
          )
      ),
    ],
    rabbitHole: WeeklyRabbitHoleSnapshot(
      from: .figma(avg: "45m avg"),
      targets: [.reddit(), .x(), .substack(), .youtube()],
      avg: "3h 25m avg"
    )
  )
}

struct WeeklyApplicationNode: Identifiable {
  let id: String
  let name: String
  let x: CGFloat
  let y: CGFloat
  let size: CGFloat
  let kind: WeeklyApplicationKind
  let mark: String
  let isPrimary: Bool
  let isMuted: Bool

  init(
    id: String,
    name: String,
    x: CGFloat,
    y: CGFloat,
    size: CGFloat,
    kind: WeeklyApplicationKind,
    mark: String,
    isPrimary: Bool = false,
    isMuted: Bool = false
  ) {
    self.id = id
    self.name = name
    self.x = x
    self.y = y
    self.size = size
    self.kind = kind
    self.mark = mark
    self.isPrimary = isPrimary
    self.isMuted = isMuted
  }

  var point: CGPoint { CGPoint(x: x, y: y) }
  var border: Color { kind.borderColor }
  var fill: LinearGradient {
    switch kind {
    case .work:
      return LinearGradient(colors: [Color(hex: "EEF3FF")], startPoint: .top, endPoint: .bottom)
    case .personal:
      return LinearGradient(
        colors: [Color(hex: "FFDCCF"), Color(hex: "E6E6E6")], startPoint: .top, endPoint: .bottom)
    case .distraction:
      return LinearGradient(
        colors: [Color(hex: "FFDCCF"), Color(hex: "E6E6E6"), Color(hex: "EEF3FF")],
        startPoint: .top, endPoint: .bottom)
    }
  }
  var markColor: Color { kind == .work ? Color(hex: "4779E9") : Color(hex: "8D8C8A") }
  var shadowColor: Color { Color(hex: "EEF3FF").opacity(0.76) }
}

struct WeeklyApplicationEdge: Identifiable {
  let id = UUID()
  let from: String
  let to: String
  let kind: WeeklyApplicationKind
  let weight: Double
  let curveOffset: CGFloat

  var color: Color {
    switch kind {
    case .work:
      return Color(hex: "A9C3FF")
    case .personal:
      return Color(hex: "D5D0CA")
    case .distraction:
      return Color(hex: "FC7645")
    }
  }

  var opacity: Double {
    switch kind {
    case .work:
      return 0.24 + weight * 0.24
    case .personal:
      return 0.18 + weight * 0.2
    case .distraction:
      return 0.66 + weight * 0.34
    }
  }

  var width: CGFloat {
    switch kind {
    case .work:
      return 0.9 + CGFloat(weight) * 0.95
    case .personal:
      return 0.8 + CGFloat(weight) * 0.75
    case .distraction:
      return 0.95 + CGFloat(weight) * 1.05
    }
  }
}

enum WeeklyApplicationKind: Equatable {
  case work
  case personal
  case distraction

  var borderColor: Color {
    switch self {
    case .work:
      return Color(hex: "4779E9")
    case .personal:
      return Color(hex: "B8B8B8")
    case .distraction:
      return Color(hex: "FC7645")
    }
  }
}

struct WeeklyWorkPattern: Identifiable {
  let id: String
  let from: WeeklyPatternApp
  let via: WeeklyPatternApp?
  let to: WeeklyPatternApp
  let count: Int
  let description: String
}

struct WeeklyRabbitHoleSnapshot {
  let from: WeeklyPatternApp
  let targets: [WeeklyPatternApp]
  let avg: String
}

struct WeeklyPatternApp: Identifiable {
  let id: String
  let name: String
  let initial: String
  let color: Color
  let avg: String

  static func slack(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "slack", name: "Slack", initial: "S", color: Color(hex: "36C5F0"), avg: avg)
  }

  static func figma(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "figma", name: "Figma", initial: "F", color: Color(hex: "FF7262"), avg: avg)
  }

  static func runway(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "runway", name: "Runway ML", initial: "R", color: Color(hex: "111111"), avg: avg)
  }

  static func flora(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "flora", name: "Flora", initial: "F", color: Color(hex: "767676"), avg: avg)
  }

  static func reddit(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "reddit", name: "Reddit", initial: "R", color: Color(hex: "FF613C"), avg: avg)
  }

  static func x(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(id: "x", name: "X", initial: "X", color: Color(hex: "111111"), avg: avg)
  }

  static func substack(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "substack", name: "Substack", initial: "S", color: Color(hex: "FF6E3E"), avg: avg)
  }

  static func youtube(avg: String = "") -> WeeklyPatternApp {
    WeeklyPatternApp(
      id: "youtube", name: "YouTube", initial: "Y", color: Color(hex: "FF0000"), avg: avg)
  }
}
