# AGENTS.md

Dayflow is a native macOS app (Swift 5 / SwiftUI, macOS 14+) that records screen activity and turns it into an AI-analyzed work journal. Local-first; data lives in `~/Library/Application Support/Dayflow/`.

## Project layout — read this first

- The Xcode project is at `Dayflow/Dayflow.xcodeproj` (scheme `Dayflow`). It is NOT at the repo root.
- App source: `Dayflow/Dayflow/` (entry point `App/DayflowApp.swift`; feature code in `Core/`, `Views/`, `Models/`, `Menu/`, `System/`).
- Unit tests: `Dayflow/DayflowTests/`. The repo-root `DayflowTests/` directory is **orphaned** — not part of the Xcode project. Never add tests there.
- Xcode 16 filesystem-synchronized groups: any file added under `Dayflow/Dayflow/` or `Dayflow/DayflowTests/` is automatically a target member. No `project.pbxproj` edits needed (and none are used for source files).
- Legacy "AmiTime" name lingers in test bundle IDs and an empty `AmiTime.xcodeproj/` folder inside `Dayflow.xcodeproj`. Ignore both; don't rename or delete unprompted.

## Build and test

```bash
# Build
xcodebuild -project Dayflow/Dayflow.xcodeproj -scheme Dayflow build

# All tests (unit + UI)
xcodebuild -project Dayflow/Dayflow.xcodeproj -scheme Dayflow test

# Unit tests only (skips DayflowUITests, which are slow)
xcodebuild -project Dayflow/Dayflow.xcodeproj -scheme Dayflow -only-testing:DayflowTests test

# Single test class or method
xcodebuild ... -only-testing:DayflowTests/TimeParsingTests test
xcodebuild ... -only-testing:DayflowTests/TimeParsingTests/testName test
```

- Unit tests run hosted inside `Dayflow.app` (`TEST_HOST`), so testing builds and launches the app.
- SPM dependencies resolve on first build: GRDB (SQLite), Sparkle (updates), PostHog (analytics), Sentry, MarkdownUI.

## Configuration and secrets

- Build settings come from `Dayflow/Config/Dayflow.xcconfig`, which sets `DAYFLOW_BACKEND_URL` and `POSTHOG_API_KEY`. Both empty by default — empty PostHog key disables analytics and support chat in local builds (intentional).
- For local overrides, copy `Dayflow/Config/LocalSecrets.xcconfig.example` to `LocalSecrets.xcconfig` (same dir). It is gitignored and pulled in via `#include?`.

## Localization

- User-facing strings live in `Dayflow/Dayflow/Localizable.xcstrings` and `InfoPlist.xcstrings`. Supported languages: zh-Hans, zh-Hant, ja, ko, de, ru, fr.
- `LocalizationTests` fails if any supported language is missing translations, so new user-facing strings must be localized in all seven languages.

## Releases (maintainers only)

- `scripts/release.sh` is the one-button release: bumps `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (and keeps `Info.plist` in sync), builds/signs/notarizes the DMG, Sparkle-signs it, creates the GitHub release, and prepends to `docs/appcast.xml` (the Sparkle feed, served at https://dayflow.so/appcast.xml), then pushes.
- Flags: `--major` / `--patch` (default minor), `--notes FILE`, `--dry-run`, `--no-notarize`.
- Requires: Developer ID cert in login keychain, Sparkle `sign_update` CLI, authenticated `gh`, notarytool credentials. Per-developer overrides go in gitignored `scripts/release.env` (see `release.env.example`).
- Do not hand-edit `docs/appcast.xml` or version numbers — the script keeps build numbers monotonic against the appcast. Sentry dSYM upload runs only when `SENTRY_*` env vars and `sentry-cli` are present; it is skipped otherwise.

## Other components

- `plugins/dayflow/` — an installable agent plugin (MCP server via `bin/dayflow-mcp`, skills in `skills/`), registered through `.agents/plugins/marketplace.json`. Read-only access to the local Dayflow timeline.
- `tools/dayflow-cli/` — standalone SwiftPM read-only CLI, deliberately dependency-free; build with `swift build` in that directory. Note: everything else under `tools/` is gitignored.

## Repo quirks

- `CLAUDE.md`, `claude.md`, and `agents.md` are gitignored on purpose (personal notes stay local). On this case-insensitive checkout that also matches `AGENTS.md`, so this file is local-only and won't be committed without `git add -f`.
