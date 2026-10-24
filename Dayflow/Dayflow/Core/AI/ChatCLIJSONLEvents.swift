//
//  ChatCLIJSONLEvents.swift
//  Dayflow
//
//  Wire-format DTOs for the codex/claude CLI JSONL streaming output the
//  retained ChatCLIProcessRunner parses (used by the retained Flow feature
//  domain's streaming conversations).
//
//  Extracted verbatim from the retired ChatCLIConfigManager.swift during the
//  final provider pruning pass; only the config-manager half of that file
//  was orphaned.
//

import Foundation

// MARK: - JSONL Event Types

/// Codex `--json` event format
struct CodexJSONLEvent: Decodable {
  let type: String
  let thread_id: String?
  let item: CodexItem?
  let message: String?
  let error: CodexError?

  struct CodexError: Decodable {
    let message: String?
  }

  struct CodexItem: Decodable {
    let type: String
    let text: String?
    let command: String?
    let status: String?
    let aggregated_output: String?
    let exit_code: Int?
  }
}

/// Claude `--output-format stream-json` event format
struct ClaudeJSONLEvent: Decodable {
  let type: String
  let session_id: String?
  let event: ClaudeEvent?
  let result: String?

  struct ClaudeEvent: Decodable {
    let type: String
    let delta: ClaudeDelta?
  }

  struct ClaudeDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
  }
}
