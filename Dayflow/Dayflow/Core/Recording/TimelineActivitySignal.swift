//
//  TimelineActivitySignal.swift
//  Dayflow
//
//  Engine-owned coarse invalidation signal for persisted timeline activity.
//  The storage layer posts it after a timeline-card write transaction
//  commits; MacActivityEngine re-exposes it (MacActivityEngineSignals) for
//  higher-level callers. Distinct from the UI-owned `.timelineDataUpdated`
//  notification, which Views post after re-rendering.
//

import Foundation

extension Notification.Name {
  /// Posted after a timeline_cards write transaction commits (insert, replace,
  /// extend, soft-delete, or content update). Coarse re-read invalidation:
  /// no payload, no per-card detail. One post per committed transaction.
  ///
  /// Posted synchronously on the mutating thread immediately after the
  /// transaction commits; observers should register with a queue if they
  /// need delivery on a specific execution context. Engine-owned and
  /// headless-safe: no UI involvement.
  static let timelineActivitiesChanged = Notification.Name("dayflow.timelineActivitiesChanged")
}

extension StorageManager {
  /// Emits the engine-owned activity-change signal. Timeline-card mutation
  /// methods call this exactly once, after their write transaction commits;
  /// failed transactions never signal.
  func notifyTimelineActivitiesChanged() {
    NotificationCenter.default.post(name: .timelineActivitiesChanged, object: nil)
  }
}
