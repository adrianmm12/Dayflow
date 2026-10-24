//
//  FlowEarlyBirdController.swift
//  Dayflow
//
//  Shows the early-bird card for the first hour Dayflow is on each day. A day
//  runs 4am to 4am, the same as the timeline. The hour starts the first time
//  recording is seen on that day and is remembered across relaunches.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class FlowEarlyBirdController {
  static let shared = FlowEarlyBirdController()

  private static let window: TimeInterval = 60 * 60
  private static let dayKey = "flowEarlyBirdDay"
  private static let startKey = "flowEarlyBirdStartedAt"
  private static let dismissedKey = "flowEarlyBirdDismissedDay"

  private var cancellables: Set<AnyCancellable> = []
  private var timer: Timer?
  private let defaults = UserDefaults.standard

  private init() {}

  /// Call once at app launch.
  func start() {
    RecordingState.shared.$isRecording
      .map { _ in () }
      .merge(with: FlowSessionMirror.shared.$snapshot.map { _ in () })
      .merge(with: DayflowAuthManager.shared.$flowEnabled.map { _ in () })
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.evaluate() }
      .store(in: &cancellables)

    // Catches the hour running out and the day rolling over at 4am.
    let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.evaluate() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    evaluate()
  }

  private func evaluate() {
    guard DayflowAuthManager.shared.flowEnabled, RecordingState.shared.isRecording else {
      hide()
      return
    }
    let now = Date()
    let day = now.getDayInfoFor4AMBoundary().dayString
    if defaults.string(forKey: Self.dayKey) != day {
      defaults.set(day, forKey: Self.dayKey)
      defaults.set(now.timeIntervalSince1970, forKey: Self.startKey)
    }
    let deadline = Date(timeIntervalSince1970: defaults.double(forKey: Self.startKey))
      .addingTimeInterval(Self.window)

    guard deadline > now,
      defaults.string(forKey: Self.dismissedKey) != day,
      !FlowSessionMirror.shared.isSessionOn
    else {
      hide()
      return
    }
    show(deadline: deadline)
  }

  /// Closed for the rest of the day, by the X or by starting a session.
  private func dismissForToday() {
    defaults.set(Date().getDayInfoFor4AMBoundary().dayString, forKey: Self.dismissedKey)
    hide()
  }

  private func show(deadline: Date) {
    // The early-bird card UI went away with the presentation layer; nothing is
    // presented anymore. The controller keeps evaluating the day/hour window so
    // the bookkeeping (day keys, dismissal, analytics) stays intact.
  }

  private func hide() {}
}
