//
//  GitHubStarPrompt.swift
//  Dayflow
//
//  Stars the Dayflow repos through the user's `gh` CLI when it's available,
//  so the What's New prompt can star in one click instead of opening a browser.
//

import AppKit
import Foundation

enum GitHubStarStatus: String {
  /// `gh` is missing, not logged in, or the check failed. Fall back to the browser.
  case unavailable
  case notStarred
  case starred
}

/// Everything the star check learned, so analytics can separate "no gh" from
/// "gh but logged out" from "already starred".
struct GitHubStarCheck {
  let status: GitHubStarStatus
  let ghInstalled: Bool?
  let ghAuthenticated: Bool?
  /// Repo short name ("Dayflow") to whether it's starred. Empty when gh is unusable.
  let starredByRepo: [String: Bool]
  let durationMs: Int

  var analyticsProperties: [String: Any] {
    var props: [String: Any] = [
      "gh_status": status.rawValue,
      "check_duration_ms": durationMs,
    ]
    if let ghInstalled { props["gh_installed"] = ghInstalled }
    if let ghAuthenticated { props["gh_authenticated"] = ghAuthenticated }
    for (repo, starred) in starredByRepo {
      props["\(repo.lowercased())_starred"] = starred
    }
    return props
  }
}

struct GitHubStarResult {
  /// Repo short name to whether the PUT succeeded.
  let starredByRepo: [String: Bool]
  let durationMs: Int

  var primaryStarred: Bool {
    starredByRepo[GitHubStarPrompt.primaryRepoName] == true
  }

  var analyticsProperties: [String: Any] {
    var props: [String: Any] = [
      "repos_starred": starredByRepo.values.filter { $0 }.count,
      "star_duration_ms": durationMs,
    ]
    for (repo, succeeded) in starredByRepo {
      props["\(repo.lowercased())_star_succeeded"] = succeeded
    }
    return props
  }
}

enum GitHubStarPrompt {
  static let primaryRepo = "JerryZLiu/Dayflow"
  static let primaryRepoName = "Dayflow"
  static let primaryRepoURL = URL(string: "https://github.com/JerryZLiu/Dayflow")!

  /// Every repo a one-click star applies to.
  private static let repos = [primaryRepo, "JerryZLiu/AgentPlayback"]

  /// Users reported 1Password authorization prompts when What's New checked GitHub stars.
  /// Our interactive login shell loads their configuration, which can wrap gh with 1Password.
  /// Conservatively use the browser whenever 1Password is installed: detecting only the shell
  /// integration could itself trigger a prompt. This app lookup launches neither app nor shell.
  static var shouldUseBrowser: Bool {
    ["com.1password.1password", "com.agilebits.onepassword7"].contains {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    }
  }

  /// Starred only when every repo is starred. Blocks on shell calls, so run it off the main thread.
  static func check() -> GitHubStarCheck {
    let start = Date()
    func finish(
      _ status: GitHubStarStatus, installed: Bool?, authenticated: Bool?, starred: [String: Bool]
    ) -> GitHubStarCheck {
      GitHubStarCheck(
        status: status,
        ghInstalled: installed,
        ghAuthenticated: authenticated,
        starredByRepo: starred,
        durationMs: Int(Date().timeIntervalSince(start) * 1000)
      )
    }

    guard !shouldUseBrowser else {
      return finish(.unavailable, installed: nil, authenticated: nil, starred: [:])
    }

    guard LoginShellRunner.run("gh --version", timeout: 10).exitCode == 0 else {
      return finish(.unavailable, installed: false, authenticated: false, starred: [:])
    }

    var starred: [String: Bool] = [:]
    for repo in repos {
      let result = LoginShellRunner.run("gh api user/starred/\(repo)", timeout: 10)
      if result.exitCode == 0 {
        starred[shortName(repo)] = true
        continue
      }
      // gh reports 404 on stderr when the repo is not starred.
      if result.stderr.contains("404") {
        starred[shortName(repo)] = false
        continue
      }
      // Anything else means gh can't reach GitHub as this user (logged out, offline, scope).
      let loggedOut = result.stderr.contains("auth login") || result.stderr.contains("not logged")
      return finish(.unavailable, installed: true, authenticated: !loggedOut, starred: starred)
    }

    let allStarred = starred.values.allSatisfy { $0 }
    return finish(
      allStarred ? .starred : .notStarred, installed: true, authenticated: true, starred: starred)
  }

  /// Current stargazer count for Dayflow, for social proof. Blocks on a shell call.
  static func stargazerCount() -> Int? {
    guard !shouldUseBrowser else { return nil }
    let result = LoginShellRunner.run(
      "gh api repos/\(primaryRepo) --jq .stargazers_count", timeout: 10)
    guard result.exitCode == 0 else { return nil }
    return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Stars every repo and reports which ones took.
  static func starAll() -> GitHubStarResult {
    guard !shouldUseBrowser else {
      return GitHubStarResult(starredByRepo: [:], durationMs: 0)
    }
    let start = Date()
    var starred: [String: Bool] = [:]
    for repo in repos {
      let result = LoginShellRunner.run("gh api -X PUT user/starred/\(repo)", timeout: 10)
      starred[shortName(repo)] = result.exitCode == 0
    }
    return GitHubStarResult(
      starredByRepo: starred,
      durationMs: Int(Date().timeIntervalSince(start) * 1000)
    )
  }

  private static func shortName(_ repo: String) -> String {
    repo.split(separator: "/").last.map(String.init) ?? repo
  }
}

// MARK: - GitHub star prompt state
//
// Moved verbatim from the presentation layer (Views/UI/GitHubStarPromptCard.swift).
// The in-app survey system (Core/Surveys) once read `lastShownAt` so surveys
// stayed off the same day as the star card; it was deleted in a later
// stripping slice. The state itself is just UserDefaults bookkeeping.

enum GitHubStarPromptState {
  static let repositoryURL = URL(string: "https://github.com/jerryzliu/Dayflow")!

  /// How long to wait between asks (and between gh checks for people we can't ask).
  static let reminderInterval: TimeInterval = 3 * 24 * 60 * 60

  /// Set once the person clicks any star button or gh reports Dayflow as starred.
  /// After that we never ask again, even if the browser star can't be verified.
  private static let isDoneKey = "gitHubStarPromptDone"
  private static let lastAttemptAtKey = "gitHubStarPromptLastAttemptAt"
  private static let lastShownAtKey = "gitHubStarPromptLastShownAt"
  private static let shownCountKey = "gitHubStarPromptShownCount"
  /// The one-time prompt for people without gh. Reuses the original first-card key so
  /// anyone who already saw the old prompt isn't asked again.
  private static let hasShownBrowserPromptKey = "hasShownGitHubStarPrompt"

  static var isDone: Bool {
    UserDefaults.standard.bool(forKey: isDoneKey)
  }

  static var hasShownBrowserPrompt: Bool {
    UserDefaults.standard.bool(forKey: hasShownBrowserPromptKey)
  }

  /// When either version of the card last appeared. Surveys use it to stay off the same day.
  static var lastShownAt: Date? {
    UserDefaults.standard.object(forKey: lastShownAtKey) as? Date
  }

  static var shownCount: Int {
    UserDefaults.standard.integer(forKey: shownCountKey)
  }

  /// True when it's been at least `reminderInterval` since the last gh check.
  static var isDue: Bool {
    guard !isDone else { return false }
    guard let lastAttemptAt = UserDefaults.standard.object(forKey: lastAttemptAtKey) as? Date else {
      return true
    }
    return Date().timeIntervalSince(lastAttemptAt) >= reminderInterval
  }

  static func markDone() {
    UserDefaults.standard.set(true, forKey: isDoneKey)
  }

  /// Starts the 3-day wait, whether or not the check ended in showing the prompt.
  static func markAttempted() {
    UserDefaults.standard.set(Date(), forKey: lastAttemptAtKey)
  }

  static func markShown() {
    markAttempted()
    UserDefaults.standard.set(shownCount + 1, forKey: shownCountKey)
    UserDefaults.standard.set(Date(), forKey: lastShownAtKey)
  }

  static func markBrowserPromptShown() {
    UserDefaults.standard.set(true, forKey: hasShownBrowserPromptKey)
    UserDefaults.standard.set(Date(), forKey: lastShownAtKey)
  }
}
