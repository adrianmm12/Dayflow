//
//  WeeklySuggestionsSection.swift
//  Dayflow
//
//  Data models for the weekly suggestions section. The section's SwiftUI view
//  was removed with the presentation-layer stripping slice; the models stay
//  because Core/Weekly dashboard builders construct them. They will move (or
//  go away with Core/Weekly) in a later stripping slice.
//

import Foundation

struct WeeklySuggestionsSnapshot {
  let title: String
  let topLevelUpdatesTitle: String
  let topLevelUpdates: [WeeklySuggestionEntry]
  let nextStepsTitle: String
  let nextSteps: [WeeklySuggestionEntry]

  static let figmaPreview = WeeklySuggestionsSnapshot(
    title: String(localized: "1:1 suggestions"),
    topLevelUpdatesTitle: String(localized: "Top level updates"),
    topLevelUpdates: [
      WeeklySuggestionEntry(
        id: "top-level-editorial-nls",
        label: String(localized: "Editorial NLS"),
        detail:
          String(
            localized:
              "Iterated on ZSR and sparse results design explorations (zero-result states, best match redirects, query rephrasing guidance)"
          )
      ),
      WeeklySuggestionEntry(
        id: "top-level-editorial-video-nls",
        label: String(localized: "Editorial video NLS"),
        detail:
          String(
            localized:
              "Conducted competitive analysis of NLS video search tools (TwelveLabs, WayinVideo, AP Moments, YouTube Ask) during Pod 1 Review"
          )
      ),
      WeeklySuggestionEntry(
        id: "top-level-editorial-sbi-1",
        label: String(localized: "Editorial SBI"),
        detail:
          String(
            localized:
              "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
          )
      ),
      WeeklySuggestionEntry(
        id: "top-level-editorial-sbi-2",
        label: String(localized: "Editorial SBI"),
        detail:
          String(
            localized:
              "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
          )
      ),
    ],
    nextStepsTitle: String(localized: "Next steps"),
    nextSteps: [
      WeeklySuggestionEntry(
        id: "next-steps-editorial-nls",
        label: String(localized: "Editorial NLS"),
        detail:
          String(
            localized:
              "Iterated on ZSR and sparse results design explorations (zero-result states, best match redirects, query rephrasing guidance)"
          )
      ),
      WeeklySuggestionEntry(
        id: "next-steps-editorial-video-nls",
        label: String(localized: "Editorial video NLS"),
        detail:
          String(
            localized:
              "Conducted competitive analysis of NLS video search tools (TwelveLabs, WayinVideo, AP Moments, YouTube Ask) during Pod 1 Review"
          )
      ),
      WeeklySuggestionEntry(
        id: "next-steps-editorial-sbi",
        label: String(localized: "Editorial SBI"),
        detail:
          String(
            localized:
              "Reviewed scope-switching and SBI handling flows; drafted \"Areas requiring additional PD input\" spec with ClickUp links; synced with Jason Ross on SBI UX details"
          )
      ),
    ]
  )
}

struct WeeklySuggestionEntry: Identifiable {
  let id: String
  let label: String
  let detail: String
}
