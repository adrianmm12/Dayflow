//
//  TimelineFailureToast.swift
//  Dayflow
//
//  Posts the timeline failure toast notifications on the main queue.
//  TimelineFailureToastPayload (the event data) moved verbatim to
//  Core/AI/LLMServiceEvents.swift, the engine-owned seam LLMService reports
//  through; the app's DayflowLLMServiceEvents adaptor forwards to this center.
//

import Foundation

enum TimelineFailureToastCenter {
  static func post(_ payload: TimelineFailureToastPayload) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .showTimelineFailureToast,
        object: nil,
        userInfo: payload.notificationUserInfo
      )
    }
  }

  /// A batch just succeeded, so whatever the card asked the user to fix is fixed.
  static func hide() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .hideTimelineFailureToast, object: nil)
    }
  }
}
