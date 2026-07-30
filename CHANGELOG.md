# Changelog

All notable changes to GitBird are documented here.

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

