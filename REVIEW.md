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

## Refinement review — 2026-10-14 (initial pass)

The main opportunity is to make the existing notification workflow easier to understand and recover, while keeping GitBird a small menu bar utility. This pass reviewed the current source and exercised production SwiftUI controls in test-owned windows/popovers. It does not replace visual inspection of the running signed app. Changes are local; no new release, production account mutation, login-item change, or App Store provisioning was performed. Existing icon edits were preserved.

### Implemented refinements

| Finding | Change | Evidence |
| --- | --- | --- |
| An error replaced the complete notification list, even when the model still retained valid cached items. | Show the recovery notice inside the loaded list, identify it as previously loaded data, and keep rows actionable. Empty-account failures still show setup/recovery controls. | A native test presses each provider's row action while the refresh error remains visible, then verifies one provider mutation and successful local reconciliation. |
| Hover-only row controls were hard to discover and appeared/disappeared beside repository/date metadata. The entire row was disabled if its browser URL was unavailable. | Use a native opening Button and persistent labeled read/done controls. Only browser opening is disabled for a missing detail URL; provider actions remain available. Combine status/reason badges on one line, truncate long repository names in the middle, and expose status/reason as the opening button's accessibility value. | Native row-opening dispatch is checked independently of mutations. Cached-row tests deliberately have no detail URL and never simulate hovering. VoiceOver speech and keyboard focus order remain manual checks. |
| Six header controls competed with title/status text in a fixed 420-point popup. | Keep four compact navigation controls in the top row and place labeled bulk actions below them, with the current provider identified. | Existing native window/popover confirmation and Return/Escape regressions pass against the revised header. |
| GitLab offered separate read and done controls for the same Todo API operation and displayed GitHub-style read terminology. | Expose one Todo completion action at row and bulk level, use Pending/Completed badges, and retain both underlying model aliases. The canonical visible action respects the existing show-completed setting. | GitLab UI checks reject duplicate completion controls; provider-level read/done scope and failure tests still cover both aliases. |
| The initial fetch could display a green All caught up state before any successful response. | Show a checking state until the first successful fetch; show Refreshing during explicit refresh. | Source/control-state review; first-fetch visual acceptance remains part of the runtime checklist. |
| Manual refresh restarts request ownership and could discard a running bulk action's UI result. | Disable both header refresh and inline retry while bulk work is in progress. Retry refresh uses the existing provider-delay-aware refresh method. | A gated bulk request remains owned and reconciles successfully after attempts to press both refresh controls. A separate native retry test verifies no request is sent during the provider retry interval. |

The backend/API, credential storage, polling policy, App Store purchase logic, macOS minimum, shipping sandbox, and hardened runtime were not changed. The test fixture now cancels active requests without invalidating a session before cancelled background lookups finish unwinding; the earlier teardown could raise a Foundation Objective-C exception in a subsequent test.

The design direction follows Apple's guidance to keep feedback in context and expose clear actions: [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), and [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar). The priorities below are product recommendations based on the reviewed code, not claims that Apple requires these particular features.

### Further improvements, in priority order

| Priority | Improvement and reason | Small implementation path | Acceptance evidence |
| --- | --- | --- | --- |
| P1 | Finish signed-app keyboard, VoiceOver, and supported-macOS acceptance. Hosted tests cannot prove the actual MenuBarExtra focus/dismissal behavior or rendered layout. | Exercise the signed app on macOS 14.6/15 and a current macOS release with empty, long-title, cached-error, pagination, confirmation, and completed-Todo states. Verify Tab/Space/Return/Delete/Escape, long text, increased contrast, and reduced transparency. | Recorded app screenshots and VoiceOver/focus checks; read/done actions against disposable account fixtures. |
| P1 | Expose per-item request progress. Duplicate requests are suppressed internally, but an individual row has no observable in-flight state. | Publish the existing per-thread request IDs through a small read-only query. Show a compact spinner and disable only that row's mutation controls until its request settles; keep browser opening available. | A gated request visibly enters busy state; repeated presses send one request; failure restores controls without removing the item. |
| P1 for purchase distribution | Restore reliable purchase validation on this development Mac, then validate a signed App Store build before offering live tips. | Diagnose why the local StoreKit purchase routed to Sandbox and returned item-not-found. Re-run the focused local fixture in a clean host, then independently check App Store Connect configuration and a signed sandbox/TestFlight build with local configuration disabled. | Two distinct verified consumable transactions finish; cancellation/pending/failure recovery is shown; unavailable tips never restrict notifications. |
| P2 | Keep freshness visible after success feedback. `statusMessage` currently takes precedence over loaded count/last-refresh text and can persist across later polls. | Keep count and last-updated text in a stable position; show success feedback separately with a short, cancellable lifetime. Do not hide rate-limit or account errors behind transient messages. | After read/done, another successful poll updates the visible freshness indicator; repeated actions restart feedback without stale messages clearing newer state. |
| P2 | Add a small set of high-value loaded-item filters. Text search already exists, but mentions/review requests are common triage categories. | Start with All, Mentions, and Review requested for GitHub, plus an optional repository filter. Keep filtering local, label the loaded scope, and retain Load more when no current match exists. Use provider-appropriate options for GitLab. | Mixed fixtures, empty matches with more pages, provider switching, and keyboard navigation; no extra network requests for local filtering. |
| P2 | Make GitHub updates discoverable. Users currently depend on visiting releases or hearing about a fix. | Add an About/Support action opening the latest GitHub release, alongside the installed version. Begin with a manual download flow; no updater dependency is required. | Correct current-version display, a stable latest-release destination, and usable behavior offline. |

Do the P1 acceptance/progress work before expanding the feature set. Introduce filters only if high-volume notification use warrants them; avoid adding a full Git client or multi-account architecture without a concrete user need.

### Verification and limits for this pass

- Final local run: **37 tests passed**, with the one StoreKit transaction integration explicitly excluded. This includes all 33 notification/reliability tests and four support-manager tests. New controls are exercised using fake credentials, per-session HTTP fixtures, and test-owned AppKit/SwiftUI windows. Existing read/done scope and confirmation regressions remain green.
- The full initial 38-test run did **not** pass: besides recovery-control assertions subsequently corrected, the StoreKit integration returned `ASDServerErrorDomain Code=3504` (`This item cannot be found`, Sandbox) and created no test transactions. That failure is retained, not counted as a pass. v2.1.7's earlier remote StoreKit success is historical evidence only; these refinements have not run in remote CI.
- Optimized Release build passed for **arm64 and x86_64**, with the macOS 14.6 deployment target and complete Swift concurrency checking. No new application compiler warnings were found. Xcode's existing App Intents metadata notice and StoreKitTest's SDK-header deprecation warning remain distinct from app-source warnings.
- Native desktop inspection was unavailable through the current tools; plugin discovery did not expose a relevant native control capability. Installed-app visual layout, real VoiceOver speech/focus, browser/window dismissal, live account mutations, login items, App Store purchases, and physical macOS 14.6/15 execution remain unverified.
- Evidence: `/tmp/GitBird-refinement-final-results.xcresult`, `/tmp/gitbird-refinement-final-tests.log`, `/tmp/gitbird-refinement-final-release.log`. The full-run failure is retained at `/tmp/GitBird-refinement-results.xcresult` and `/tmp/gitbird-refinement-tests.log`.


## Further review and release preparation — 2026-10-14 (2.1.8)

The requested implementation pass completes the code improvements from the preceding review. Native desktop control and App Store Connect access are still unavailable; those acceptance checks remain open. No real provider items were mutated. The existing icon appearance edit is included.

### Completed improvements

| Improvement | Result and evidence |
| --- | --- |
| Individual progress | Publish the existing active thread IDs, show a row spinner, and disable that row's mutations while retaining browser opening. Other rows remain usable. A gated HTTP regression verifies duplicate suppression, independent rows, and failure recovery. |
| Persistent freshness | Keep loaded count and refresh age in the header with a minute-based timeline. Show feedback separately for five seconds; revision-based expiry prevents an old task from clearing a newer identical message. Errors remain persistent. |
| Loaded-item filters | Compose GitHub All loaded/Mentions/Review requested, repository, and text filters locally. Show matching versus loaded counts and a clear action; retain Load more for empty matches. Reset category/repository on account changes. The filter regression covers mixed reasons, repositories, search, GitLab compatibility, and no HTTP requests. Bulk confirmation retains its explicit scope, including filtered-out items. |
| Manual update discovery | About displays the installed version and a Check for updates action opening the stable `/releases/latest` destination. The accompanying text explains manual downloads and internet access. |
| Reduced transparency | Use an opaque system background and bordered header controls when Reduce Transparency is enabled. macOS 26 glass remains availability-gated; macOS 14.6 remains the minimum. Real assistive-technology acceptance is still pending. |
| Purchase presentation | On macOS 15.2+, anchor StoreKit confirmation to the app window, retaining the older-system fallback. The integration test exercises the same purchase helper and requires verified transactions in the Xcode environment. The local environment failure remains documented below. |

### Additional defects found and fixed

- An in-flight poll could restore an item just completed by a concurrent action. Snapshot the mutation revision, discard older poll/pagination responses, and re-fetch after polling detects a stale result. Polling waits while mutations run.
- Changing page size, visibility, or refresh interval could cancel ownership of a running mutation. Defer polling renewal until all active mutations finish; account changes still invalidate old work immediately. Manual refresh and new bulk actions wait for active mutations.
- Removing an item shifted offset-based provider pages and could skip unseen items. Revisit the first page on the next load and deduplicate IDs. A regression reproduces the shifted-page case.
- Metadata-only changes were ignored if IDs/dates stayed equal. Compare repository and subject/API URLs too, and discard cached details when the subject URL changes. A regression verifies the new repository and browser destination.

The seven new regression tests cover these races, per-row progress, composed filters, and feedback expiry. Existing native window/popover tests exercise Confirm/Cancel, Return/Escape, visible row actions, cached-error recovery, and both providers. HTTP fixtures use fake credentials and isolated sessions; shipping sandbox and hardened-runtime settings remain enabled.

### Current verification

- Universal optimized Release build passed for arm64 and x86_64 with minimum macOS 14.6 and complete concurrency checking. No app-source warnings were emitted; existing App Intents metadata and StoreKitTest SDK notices remain.
- The local full 45-test run passed all 40 reliability/native-control tests and four support-manager tests. Its one transaction integration failed with `ASDServerErrorDomain Code=3504`, `This item cannot be found`, `client-environment-type=Sandbox`; no local purchase success is claimed. Opening a dedicated purchase window and using the modern confirmation API did not resolve that environment routing failure.
- Evidence: `/tmp/GitBird-218-initial-results.xcresult`, `/tmp/gitbird-218-initial-tests.log`, and `/tmp/gitbird-218-release.log`. Clean-runner CI and publication evidence will be recorded after completion.
- Outstanding external acceptance: actual signed MenuBarExtra layout/dismissal, keyboard and VoiceOver focus/speech, long text/contrast, macOS 14.6/15, login items, disposable live-account mutations, App Store product provisioning, and signed sandbox/TestFlight purchases. The unavailable checks are not counted as passed. They remain the next priority before broadening features or enabling live tips.
