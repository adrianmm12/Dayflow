//
//  ClaudeSessionCleanup.swift
//  Dayflow
//
//  Deletes Dayflow's short resumable Claude conversation after its optional
//  correction turn. The normal Claude config remains in place so `claude -p`
//  uses the user's current auth setup.
//
//  Extracted verbatim from the retired ClaudeProvider.swift during the final
//  provider pruning pass; the retained Flow feature domain (Core/Flow) still
//  owns Claude sessions of its own.
//

import Foundation

struct ClaudeSessionCleanup {
  private let sessionID: String
  private let claudeConfigDirectory: URL

  init(
    sessionID: String,
    claudeConfigDirectory: URL? = nil
  ) {
    self.sessionID = sessionID
    self.claudeConfigDirectory =
      claudeConfigDirectory ?? ClaudeConfigDirectory.currentInLoginShell
  }

  func cleanup(fileManager: FileManager = .default) {
    removeSessionTranscript(from: claudeConfigDirectory, fileManager: fileManager)
  }

  private func removeSessionTranscript(
    from configDirectory: URL,
    fileManager: FileManager
  ) {
    let projectsDirectory = configDirectory.appendingPathComponent("projects", isDirectory: true)
    guard
      let enumerator = fileManager.enumerator(
        at: projectsDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    let expectedFilename = "\(sessionID).jsonl"
    for case let candidate as URL in enumerator
    where candidate.lastPathComponent == expectedFilename {
      do {
        try fileManager.removeItem(at: candidate)
      } catch {
        print(
          "[ClaudeSessionCleanup] Failed to remove temporary Claude session transcript: \(error.localizedDescription)"
        )
      }
    }
  }
}

enum ClaudeConfigDirectory {
  static let currentInLoginShell: URL = {
    let result = LoginShellRunner.run("printenv CLAUDE_CONFIG_DIR", timeout: 5)
    let configuredPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.exitCode == 0, !configuredPath.isEmpty {
      return URL(fileURLWithPath: NSString(string: configuredPath).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude", isDirectory: true)
  }()
}
