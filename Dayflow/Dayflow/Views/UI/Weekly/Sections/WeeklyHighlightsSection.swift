//
//  WeeklyHighlightsSection.swift
//  Dayflow
//
//  Data models for the weekly highlights section. The section's SwiftUI view
//  was removed with the presentation-layer stripping slice; the models stay
//  because Core/Weekly dashboard builders construct them. They will move (or
//  go away with Core/Weekly) in a later stripping slice.
//

import Foundation

struct WeeklyHighlightsSnapshot {
  let highlights: [WeeklyHighlight]

  static let figmaPreview = WeeklyHighlightsSnapshot(
    highlights: [
      WeeklyHighlight(
        id: "editorial-nls",
        tag: "EDITORIAL NLS",
        text:
          String(
            localized:
              "Iterated on ZSR and sparse results design explorations (zero-result states, best match redirects, query rephrasing guidance)"
          )
      ),
      WeeklyHighlight(
        id: "editorial-video-nls",
        tag: "EDITORIAL VIDEO NLS",
        text:
          String(
            localized:
              "Conducted competitive analysis of NLS video search tools (TwelveLabs, WayinVideo, AP Moments, YouTube Ask) during Pod 1 Review"
          )
      ),
      WeeklyHighlight(
        id: "editorial-sbi",
        tag: "EDITORIAL SBI",
        text:
          String(
            localized:
              "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
          )
      ),
    ]
  )
}

struct WeeklyHighlight: Identifiable {
  let id: String
  let tag: String
  let text: String
}
