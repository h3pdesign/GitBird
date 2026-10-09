# Changelog

All notable changes to GitBird are documented here.

## Unreleased

## [2.1.7] - 2026-10-09

### Fixed

- Keep bulk read/done confirmation inside the notification popup so confirming works reliably for GitHub and GitLab.
- Reconcile loaded items with the provider's bulk-action scope, retaining the originally confirmed GitHub read cutoff and loaded GitHub done IDs.
- Preserve GitLab bulk permission/rate-limit errors and retry delays; clear earlier errors after successful bulk completion.

### Validation

- Native confirmation controls, Return/Escape, provider scope, individual actions, errors, and retry recovery have regression coverage. HTTP test fixtures are isolated per session to prevent late requests from contaminating subsequent tests.

## [2.1.6] - 2026-09-30

### Added

- Support settings with Patreon, GitHub, and feedback links, plus optional repeatable App Store tip integration pending App Store product setup. All features remain available without a purchase.
- StoreKit 2 pricing, verified transaction handling, pending-purchase recovery, and a local StoreKit test configuration.
- Search loaded notifications by title, repository, and reason; refresh/settings/search keyboard shortcuts.
- Optional launch-at-login control and clear setup/retry actions.
- Bulk-action confirmations showing the provider’s exact affected scope and loaded-count pagination indication.
- Credential, provider, polling, pagination, stale-action, and purchase regression tests; pull-request build/test workflow.

### Improved

- Refresh the app icon appearance.

### Fixed

- Check Keychain read/write/delete failures, preserve migration sources until persistence succeeds, and load credentials away from the UI thread.
- Bind GitLab credentials and legacy migration to the original HTTPS origin; reject authenticated cross-origin redirects and require token verification after host changes.
- Persist token drafts only after provider verification and successful secure storage.
- Continue pagination when completed GitLab Todos have more pages than pending Todos, with deterministic ID deduplication.
- Respect refresh intervals up to one hour and provider polling/rate-limit retry guidance.
- Ignore stale action failures and cleanup after account changes.
- Pin the supported minimum to macOS 14.6 across build configurations.

## [2.1.5] - 2026-08-10

### Performance and reliability

- Avoid unnecessary SwiftUI list updates when polling returns unchanged notifications.
- Batch subject-detail prefetch updates and keep polling task lifetimes non-retaining.
- Deduplicate in-flight avatar downloads and decode thumbnails off the main actor.
- Prevent duplicate read/done requests for the same notification.
- Clarify Swift 6 task result types for reliable release builds.

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
