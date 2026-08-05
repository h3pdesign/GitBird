# Changelog

All notable changes to GitBird are documented here.

## [2.1.4] - 2026-08-05

### Security and reliability

- Store GitHub and GitLab access tokens in the macOS Keychain and migrate legacy UserDefaults tokens.
- Restrict authenticated API mutations and provider requests to approved HTTPS hosts.
- Prevent stale refresh and bulk-action results from overwriting newer account state.

### Provider support and usability

- Use configured self-hosted GitLab URLs for browser and token-settings links.
- Clarify GitLab Todo completion actions and provider-neutral settings guidance.
- Improve keyboard activation, accessibility labels, avatar loading, and unread menu-bar counts.

## [2.1.3] - 2026-08-02

### Distribution

- Added the GitHub-hosted Developer ID build, notarization, stapling, and release-asset verification workflow.
- Prepared distribution metadata for the notarized macOS app release.

## [2.1.2] - 2026-08-01

### Fixed

- Manual refresh now restarts the automatic background polling task.
- Temporary network failures retry with exponential backoff instead of permanently stopping refresh.
- Refresh interval guidance now explains automatic polling and retry behavior.

## [2.1.1] - 2026-07-30

### Performance

- Replaced per-row AppKit hover tracking with native SwiftUI hover handling.
- Bounded subject-detail prefetching to the first 12 visible notifications.
- Deduplicated subject-detail requests by URL.
- Reduced view and network overhead while scrolling and opening the menu bar window.

## [2.1.0] - 2026-07-27

### Added

- Explicit **Unread** and **Read** status badges on notification rows.
- Strict provider-state filtering when **Hide read notifications** is enabled.
- GitHub and GitLab notification actions remain synchronized with provider state.
- Liquid Glass notification window and refreshed status/action controls.

### Fixed

- Read notifications were incorrectly treated as unread when `last_read_at` was missing.
- Read notifications could remain visible while the hide-read filter was enabled.
- Read items remain available for completion until the provider marks them done.
- Refresh and bulk actions now reconcile local state with the provider response.

### Distribution

- Standalone GitBird repository and release process.
- Release asset: `GitBird-2.1.0.zip`.

## [2.0.3] - 2026-07-27

- Prepared the previous maintenance release line.

## [2.0.2] - 2026-07-27

- Kept read notifications available for the done action.
