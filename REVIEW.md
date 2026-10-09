# GitBird review and implementation — 2026-09-30

This review covered settings, credentials, authenticated provider requests, polling and pagination, notification actions, startup, support purchases, and build configuration. The seven original findings and the six product recommendations are implemented locally. App Store provisioning and runtime accessibility validation remain open; these release checks are separate from the notarized GitHub distribution.

## Findings and fixes

| Finding / root cause | Change and restored invariant | Evidence |
| --- | --- | --- |
| Keychain update/add/delete statuses were discarded, and migration deleted plaintext even if storage failed. | Security statuses are checked; missing credentials differ from denied reads. Migration sources survive failed writes and remain pinned to their original provider and GitLab origin across restarts. Drafts activate only after provider verification and secure storage succeed. Explicit removal reports failed deletes. | `TokenStore`, `RuntimeData.loadCredentials`, `testAccessToken`, `removeAccessToken`; fake-storage tests cover denied reads/writes/deletes, successful migration, retry, and restart ownership. |
| GitLab tokens used a provider-only Keychain account, and changing host reused the same token. Redirects lacked an explicit authenticated origin policy. | GitLab credentials use a normalized HTTPS origin including port. Legacy credentials migrate only to the pinned original host. Host changes stop old requests, clear active credentials, and require verification. Authenticated API URLs and redirects retain the same origin. | Origin/port/invalid-host boundary tests, original-host migration test, host verification and failed-save tests. Redirect policy is unit-tested; a real HTTP redirect was not exercised. |
| Completed GitLab Todos were fetched, but only pending-page headers controlled pagination. | Either stream can advertise another page; merged results deduplicate by ID and order deterministically. | Stubbed empty/finished pending stream with continuing completed pages and overlapping IDs. |
| The 900-second retry cap also limited successful polling. | Successful polling honors 30–3600 seconds; failures back off with a cap that never shortens a longer selected interval. Provider poll/retry/reset headers set minimum waits. Manual refresh schedules the next poll rather than duplicating it immediately; rate limits block manual, verification, pagination, and mutation retries. | The old expression returned 900 for both 1800 and 3600 seconds. Tests cover the advertised range, failure backoff, malformed/numeric/date/reset headers, blocked retries, and manual-refresh request counts. |
| Several mutation failure and cleanup paths ignored request ownership. | Success, failure, and cleanup all check the request generation. Bulk confirmations also retain the reviewed account, generation, loaded IDs, and refresh timestamp. | Delayed failures for individual read/done and bulk read/done cannot change the new account; stale confirmations cannot run. |
| The deployment target inherited an SDK-recommended value despite an advertised 14.6 minimum. | All configurations explicitly target macOS 14.6; About/README and project guidance agree. Existing guarded newer-system styling remains. | Xcode builds target arm64-apple-macos14.6. Running on macOS 14.6 itself remains a release check. |
| Startup called `SecItemCopyMatching` synchronously in `RuntimeData.init`. | Security calls run in `TokenStore`’s actor; app initialization performs no Keychain read, and Settings exposes loading/retry state. | Original launch sample showed the main thread waiting in `RuntimeData.init → TokenStore.token → SecItemCopyMatching`. A delayed credential fake proves the UI actor remains responsive. The signed published app was not benchmarked. |

Impact is limited to GitBird’s macOS app, hosted tests, configuration, and documentation. Shared provider code affects GitHub and GitLab, initial refresh, polling, pagination, token verification, and notification mutations. Existing icon edits were retained. No Neon source, external provider data, login-item registration, or production credentials were changed by validation. No dependencies or telemetry were added.

## Product improvements delivered

- Actionable first-run, expired-token, permissions, host, offline, rate-limit, and Keychain messages, with Account settings and retry actions. Token edits remain drafts until **Verify and save token** succeeds.
- Local search of loaded title/repository/reason, clear-search control, and no-results feedback while preserving pagination. Shortcuts: ⌘F search, ⌘R refresh, ⌘, Settings.
- Menu bar labels identify loaded unread items and append `+` when more pages exist.
- Optional launch at login using `SMAppService.mainApp`, with approval guidance and service-status/error handling.
- Bulk confirmations explain that GitHub done affects loaded items including search-hidden items, GitHub read covers account items up to the last refresh, and GitLab completion covers every pending Todo including unloaded items.
- Hosted regression tests and a pull-request/main-push build/test workflow. The workflow passed on GitHub for the v2.1.6 source commit.

Keep GitBird’s focused menu bar workflow. Further expansion into a full Git client would increase scope without improving this core use case.

## Support purchase

Settings → Support contains a repeatable optional consumable tip, Patreon, repository, and feedback links. StoreKit supplies localized pricing; purchases handle cancellation, pending, failure, verified finishing, restrictions, and concurrency. The app starts transaction update/unfinished listeners. No feature is locked behind a purchase.

Proposed product ID: `com.h3p.GitBird.support.tip`. The local StoreKit fixture uses 4.99; it does not set a live price. App Store Connect is at sign-in and the user is away from their Mac, so creation of the consumable, storefront pricing/localization, commercial eligibility, review screenshot, sandbox/TestFlight purchase, and submission still require an authenticated session. README contains the concrete setup steps. Do not describe the tip as live until those checks pass.

## Verification results

- **Verification Level: 3** for GitHub release delivery (implementation verification used Level 1). Shared cross-platform code changed: **No**. Platforms affected: **macOS only**. No iOS/iPadOS target exists, and no cross-platform issue was found.
- Xcode 27.0 on macOS 27.0.1: optimized Release build succeeded with Swift 6 complete strict-concurrency checking. No Swift compiler warnings; App Intents metadata extraction reported no framework dependency.
- 21 hosted tests pass: 16 reliability tests and five support tests, including two distinct repeatable local StoreKit purchases and transaction finishing. The StoreKit test also passed ten consecutive repetitions after the harness isolated the debug app’s background services, exercised its own transaction listener, and gated overlapping purchase attempts deterministically. Cancellation/pending/error and concurrency branches use injected purchase results. Subsequent real Ask-to-Buy approval and crash-relaunch unfinished recovery have not been exercised.
- The sandbox-enabled ad-hoc test run passed all 14 reliability tests then present and four support tests; the local StoreKit product lookup returned no product. Full StoreKit verification uses an isolated bundle ID and command-only ad-hoc signing, hardened-runtime, and sandbox overrides. Production project sandbox and hardened-runtime settings remain enabled. These tests do not prove shipping signature/Keychain access or App Store sandbox behavior.
- Native computer-use inspection timed out for the temporary app; the user is currently unavailable for manual validation. Accessibility labels/native semantics and shortcut/focus declarations were reviewed in source. Visual layout, actual keyboard focus order, VoiceOver, and launch-at-login registration require runtime validation with the installed signed app.
- Project plist, scheme XML, StoreKit JSON, CI workflow structure, and `git diff --check` pass. Test evidence and build logs are saved outside DerivedData before cleanup.

Evidence: `/tmp/GitBird-improvements-results.xcresult`, `/tmp/gitbird-improvements-tests.log`, `/tmp/gitbird-improvements-release.log`, and `/tmp/gitbird-storekit-repeat.log`.

The CI runner choice matches [GitHub’s supported macOS runner images](https://github.com/actions/runner-images/blob/main/README.md). StoreKit transaction finishing follows [Apple’s unfinished-transaction contract](https://developer.apple.com/documentation/storekit/transaction/unfinished); tests assert the queue settles without manually finishing transactions in the assertion.

## Published GitHub release

[GitBird v2.1.6](https://github.com/h3pdesign/GitBird/releases/tag/v2.1.6), build 187, was published on September 30. [Remote CI](https://github.com/h3pdesign/GitBird/actions/runs/36661232258) passed the Release build and all 21 tests using Xcode 26.6. The [release workflow](https://github.com/h3pdesign/GitBird/actions/runs/36661475728) succeeded.

The downloaded universal (arm64/x86_64) archive passed its published checksum, strict code signature verification, stapled-ticket validation, and Gatekeeper assessment as Notarized Developer ID. The app reports version 2.1.6, build 187, minimum macOS 14.6, and hardened runtime. Archive SHA-256: `50380ca01b1a55e5f5fb2a3ca7bc8cc49afc457e4e02b0bebc6a86117271ab45`.

## Remaining App Store and runtime checks

Authenticate App Store Connect and complete the consumable setup, run a signed sandbox/TestFlight purchase with local StoreKit configuration disabled, and validate accessibility and login items on supported Macs (including macOS 14.6). App Review submission and live consumable provisioning remain pending.

## Bulk-action follow-up — 2026-10-09 (v2.1.7)

The user reported that confirming bulk read/done did nothing for both GitHub and GitLab. Confirmation now stays inside `ContentView` rather than opening a separate system dialog from the transient popup. The same reviewed account/generation and GitHub done IDs are retained; unrelated header controls are disabled while confirmation is visible. Cancel/Escape sends no mutation, and Confirm/Return dispatches the provider action.

Additional reproducible defects were fixed: GitLab bulk requests discarded HTTP status and retry headers; local reconciliation left newly loaded GitLab Todos behind even though the API completed them; GitHub bulk read substituted a later refresh when the confirmed cutoff was nil. Local read updates now match the confirmed cutoff, including loaded items added after confirmation opened, while newer GitHub notifications remain unread. Successful bulk done clears earlier errors and reports completion.

Validation used fake credentials, isolated defaults, and URLProtocol responses; no real GitHub notifications or GitLab Todos were changed.

- The initial local run passed 32 tests: 28 notification/reliability tests and four support-manager tests. Native production SwiftUI buttons are exercised in a test-owned NSWindow and NSPopover for both providers and both bulk actions, including cancellation, Return, and Escape. Model checks cover individual read/done endpoints, duplicate/busy guards, stale accounts, confirmed scope/cutoff, the show-read setting, HTTP failures, retry recovery, and rate-limit delays.
- The original confirmation was unreachable in the controlled popover reproduction; the replacement works in that host. This is not an end-to-end trace of the installed SwiftUI MenuBarExtra or a live-account mutation.
- The optimized universal Release build succeeds for arm64 and x86_64 with the macOS 14.6 deployment target. No Swift compiler warnings were emitted; the existing App Intents metadata notice remains. Shipping sandbox and hardened-runtime settings remain enabled. Existing Xcode project edits were preserved.
- The local StoreKit integration test **did not pass on this Mac**. The full run stalled; an isolated retry logged `SKServiceErrorDomain Code=2` / `SKInternalErrorDomain Code=4` while saving its configuration and returned no product. A fresh-directory retry timed out after 60 seconds. It was explicitly excluded from the final 32-test run, and its failure result was retained separately. September's purchase-test success is historical evidence, not a current pass.
- Native computer-use inspection did not succeed. Cached hosting-view images omitted layer-backed SwiftUI text/glass and were removed from the test harness because they were incomplete visual evidence. Installed-app layout/focus, VoiceOver, real account authentication/mutations, login-item registration, live App Store purchases, and execution on macOS 14.6/15 still require runtime validation.

Current evidence: `/tmp/GitBird-bulk-verified-results.xcresult`, `/tmp/gitbird-bulk-verified-tests.log`, `/tmp/gitbird-bulk-release.log`, `/tmp/GitBird-support-recheck-results.xcresult`, and `/tmp/GitBird-support-clean-results.xcresult`. Regression baseline logs are `/tmp/gitbird-popover-baseline.log` and `/tmp/gitbird-bulk-model-baseline.log`. README and the 2.1.7 changelog describe the changes; publication evidence is recorded below after the release completes.

Release preparation also found the previous main-branch CI run failed because the shared HTTP stub could route a late request from an earlier session into the next test. Fixtures now retain their own session identifier, handler, and request log; a regression checks both response and request-count isolation. The updated local run passes 33 tests with the StoreKit integration excluded. The clean GitHub runner subsequently passed the full suite, including that integration, as recorded below. Installed-app confirmation and accessibility on supported macOS versions remain manual acceptance checks.


## Published GitHub release — 2.1.7

[GitBird v2.1.7](https://github.com/h3pdesign/GitBird/releases/tag/v2.1.7), build 191, is published as the latest stable release. The tag points to `c6c14c9539a409bc018b62c89574e6855230f162`. [Release-source CI](https://github.com/h3pdesign/GitBird/actions/runs/37912473290) passed its optimized Release build and all 34 tests on Xcode 26.6/macOS 26, including native window/popover Confirm/Cancel, Return/Escape, and repeatable StoreKit purchases. The native harness explicitly enables SwiftUI accessibility in its test environment so the runner exposes the hosted control tree; it retains diagnostics for future lookup failures. No shipping accessibility settings were overridden.

The [notarized workflow](https://github.com/h3pdesign/GitBird/actions/runs/37912737865) completed signing, archive/export, notarization, stapling, and public asset publication. Independent verification of the downloaded ZIP passed SHA-256, strict Developer ID signature verification, stapled-ticket validation, and Gatekeeper assessment (`Notarized Developer ID`). The app contains arm64 and x86_64, reports version 2.1.7/build 191/minimum macOS 14.6, and retains hardened runtime plus App Sandbox/network-client entitlements. Archive SHA-256: `e03f951285812965463f6da05a2f3a017cab29b93a558ea5fd23e648e0eb14fc`.

Release evidence: `/tmp/gitbird-217-ci-success.log`, `/tmp/GitBird-217-local-results.xcresult`, and `/tmp/GitBird-217-published/`. Live App Store product provisioning, signed App Store purchases, real-account action acceptance, installed-app visual/VoiceOver validation, and execution on macOS 14.6/15 remain separate checks.
