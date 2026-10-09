import XCTest
import Foundation
import Security
import AppKit
import SwiftUI
@testable import GitBird

private actor MemoryCredentials: CredentialStorage {
    var values: [String: String]
    var readFailure: OSStatus?
    var writeFailure: OSStatus?
    var delay: Duration = .zero
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []

    init(_ values: [String: String] = [:]) { self.values = values }
    func configure(readFailure: OSStatus? = nil, writeFailure: OSStatus? = nil, delay: Duration = .zero) {
        self.readFailure = readFailure
        self.writeFailure = writeFailure
        self.delay = delay
    }
    func token(for account: String) async throws -> String? {
        reads.append(account)
        if delay != .zero { try await Task.sleep(for: delay) }
        if let readFailure { throw CredentialError.keychain(readFailure) }
        return values[account]
    }
    func set(_ token: String, for account: String) throws {
        if let writeFailure { throw CredentialError.keychain(writeFailure) }
        writes.append(account)
        values[account] = token.isEmpty ? nil : token
    }
    func snapshot() -> [String: String] { values }
}

private struct StubReply: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
    init(_ status: Int = 200, headers: [String: String] = [:], body: String = "[]") {
        self.status = status; self.headers = headers; self.data = Data(body.utf8)
    }
}

private final class StubState: @unchecked Sendable {
    static let sessionHeader = "X-GitBird-Test-Session"
    private let lock = NSLock()
    private var handlers: [String: @Sendable (URLRequest) async throws -> StubReply] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var currentID: String?
    func configure(_ handler: @escaping @Sendable (URLRequest) async throws -> StubReply) -> String {
        lock.withLock {
            let id = UUID().uuidString
            currentID = id
            handlers[id] = handler
            requests[id] = []
            return id
        }
    }
    func reconfigureCurrent(_ handler: @escaping @Sendable (URLRequest) async throws -> StubReply) {
        lock.withLock {
            guard let id = currentID else { return }
            handlers[id] = handler
            requests[id] = []
        }
    }
    func remove(_ id: String) {
        lock.withLock { handlers[id] = nil; requests[id] = nil }
    }
    func take(_ request: URLRequest) -> (@Sendable (URLRequest) async throws -> StubReply)? {
        // URLSession may deliver a body stream to URLProtocol even when the
        // application set httpBody. Capture it before replying to the request.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        return lock.withLock {
            guard let id = request.value(forHTTPHeaderField: Self.sessionHeader), let handler = handlers[id] else { return nil }
            requests[id, default: []].append(captured)
            return handler
        }
    }
    func snapshot() -> [URLRequest] { lock.withLock { currentID.flatMap { requests[$0] } ?? [] } }
}

private final class ProviderStub: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    private var worker: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.state.take(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        worker = Task {
            do {
                let reply = try await handler(request)
                guard !Task.isCancelled, let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }
    override func stopLoading() { worker?.cancel() }
}

private actor RequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor
final class ReliabilityTests: XCTestCase {
    private func defaults(provider: NotificationProvider = .github, host: String = "https://gitlab.example") -> UserDefaults {
        let name = "GitBirdTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(host, forKey: "gitlabBaseURL")
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func session(_ handler: @escaping @Sendable (URLRequest) async throws -> StubReply = { _ in StubReply() }) -> URLSession {
        let id = ProviderStub.state.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStub.self]
        configuration.httpAdditionalHeaders = [StubState.sessionHeader: id]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); ProviderStub.state.remove(id) }
        return session
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date.now.addingTimeInterval(2)
        while !condition(), Date.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testAllSuccessfulPollingIntervalsAndProviderMinimum() {
        for interval in [30, 60, 300, 900, 1800, 3600] {
            XCTAssertEqual(PollingPolicy.delay(interval: interval, failures: 0), Double(interval))
        }
        XCTAssertEqual(PollingPolicy.delay(interval: 300, failures: 1), 600)
        XCTAssertEqual(PollingPolicy.delay(interval: 300, failures: 8), 900)
        XCTAssertEqual(PollingPolicy.delay(interval: 3600, failures: 2), 3600)
        XCTAssertEqual(PollingPolicy.delay(interval: 30, failures: 0, providerMinimum: 120), 120)
    }

    func testRetryAfterDateRateResetAndMalformedHeaders() throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/notifications"))
        let now = Date(timeIntervalSince1970: 1_000)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "60", "X-Poll-Interval": "120", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1300"]))
        XCTAssertEqual(GitHubAPIClient.minimumDelay(from: response, now: now), 300)
        let date = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:20:00 GMT"]))
        XCTAssertEqual(GitHubAPIClient.minimumDelay(from: date, now: now), 200)
        let malformed = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Retry-After": "nan", "X-Poll-Interval": "-1"]))
        XCTAssertNil(GitHubAPIClient.minimumDelay(from: malformed, now: now))
    }

    func testOriginScopingNormalizationAndRedirectBoundaries() throws {
        XCTAssertEqual(TokenStore.account(for: .gitlab, gitlabBaseURL: " HTTPS://GitLab.Example:443/ "), "gitlab:https://gitlab.example")
        XCTAssertNotEqual(TokenStore.account(for: .gitlab, gitlabBaseURL: "https://gitlab.example:8443"), TokenStore.account(for: .gitlab, gitlabBaseURL: "https://gitlab.example"))
        for host in ["http://gitlab.example", "https://user:secret@gitlab.example", "https://gitlab.example/api", "https://gitlab.example?q=1", "https://gitlab.example#f", "garbage"] {
            XCTAssertNil(TokenStore.account(for: .gitlab, gitlabBaseURL: host))
        }
        let origin = try XCTUnwrap(URL(string: "https://gitlab.example/api/v4/todos"))
        XCTAssertTrue(AuthenticatedRedirectPolicy.allows(from: origin, to: URL(string: "https://gitlab.example/api/v4/todos/1")!))
        for target in ["http://gitlab.example", "https://other.example", "https://gitlab.example:8443", "https://user@gitlab.example"] {
            XCTAssertFalse(AuthenticatedRedirectPolicy.allows(from: origin, to: URL(string: target)!))
        }
        let api = GitHubAPIClient(token: "test-token", provider: .github, gitlabBaseURL: nil, session: session())
        XCTAssertFalse(api.isAllowedAuthenticatedURL(URL(string: "https://api.github.com:8443/notifications")!))
        XCTAssertFalse(api.isAllowedAuthenticatedURL(URL(string: "https://github.com/notifications")!))
    }

    func testGitLabDoneStreamContinuesAfterPendingEndsAndDeduplicates() async throws {
        let session = session { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = query.first { $0.name == "state" }?.value
            let page = query.first { $0.name == "page" }?.value
            XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "test-token")
            if page == "2" { return StubReply(body: state == "done" ? Self.todo(3, state: "done") : "[]") }
            if state == "done" { return StubReply(headers: ["X-Next-Page": "2"], body: Self.todo(1, state: "done")) }
            return StubReply(body: Self.todo(1, state: "pending"))
        }
        let api = GitHubAPIClient(token: "test-token", provider: .gitlab, gitlabBaseURL: URL(string: "https://gitlab.example"), session: session)
        let first = try await api.fetchNotifications(page: 1, perPage: 1, includeRead: true)
        XCTAssertTrue(first.hasNext)
        XCTAssertEqual(first.threads.count, 1)
        XCTAssertFalse(first.threads[0].unread)
        let second = try await api.fetchNotifications(page: 2, perPage: 1, includeRead: true)
        XCTAssertFalse(second.hasNext)
        XCTAssertEqual(second.threads.map(\.id), ["3"])
        XCTAssertEqual(ProviderStub.state.snapshot().count, 4)
    }

    func testProviderErrorsAreActionableWithoutLeakingResponseBody() async {
        for (status, word) in [(401, "expired"), (403, "permission"), (429, "rate limiting"), (404, "host")] {
            let result = await fetchNotificationThreads(accessToken: "test-token", provider: .github, gitlabBaseURL: nil,
                session: session { _ in StubReply(status, body: "private-response-body") })
            XCTAssertFalse(result.isSuccess)
            XCTAssertTrue(result.errorMessage.contains(word))
            XCTAssertFalse(result.errorMessage.contains("private-response-body"))
        }
        let offline = await fetchNotificationThreads(accessToken: "test-token", provider: .github, gitlabBaseURL: nil,
            session: session { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertTrue(offline.errorMessage.contains("offline"))
    }

    func testHTTPFixturesRemainBoundToTheirSessionAfterAnotherTestConfigures() async {
        let first = session { _ in StubReply(401) }
        let second = session { _ in StubReply(429) }
        let firstResult = await fetchNotificationThreads(accessToken: "first", provider: .github, gitlabBaseURL: nil, session: first)
        let secondResult = await fetchNotificationThreads(accessToken: "second", provider: .github, gitlabBaseURL: nil, session: second)
        XCTAssertTrue(firstResult.errorMessage.contains("expired"))
        XCTAssertTrue(secondResult.errorMessage.contains("rate limiting"))
        XCTAssertEqual(ProviderStub.state.snapshot().count, 1, "An earlier session must not contaminate the current test's request count")
    }

    func testInitializationDoesNotReadKeychainAndDelayedLoadKeepsActorResponsive() async {
        let credentials = MemoryCredentials(["github": "test-token"])
        await credentials.configure(delay: .milliseconds(100))
        let data = RuntimeData(defaults: defaults(), credentials: credentials, apiSession: session())
        let reads = await credentials.reads
        XCTAssertTrue(reads.isEmpty)
        let load = Task { await data.loadCredentials() }
        await eventually { data.isLoadingCredentials }
        data.statusMessage = "UI remains responsive"
        XCTAssertEqual(data.statusMessage, "UI remains responsive")
        await load.value
        XCTAssertEqual(data.accessToken, "test-token")
        data.stop()
    }

    func testFailedMigrationPreservesPlaintextAndDeniedReadsCannotOverwriteIt() async {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            let defaults = defaults()
            defaults.set("legacy-test-token", forKey: "accessToken")
            let credentials = MemoryCredentials()
            await credentials.configure(writeFailure: status)
            let data = RuntimeData(defaults: defaults, credentials: credentials, apiSession: session())
            await data.loadCredentials()
            XCTAssertEqual(defaults.string(forKey: "accessToken"), "legacy-test-token")
            XCTAssertTrue(data.accessToken.isEmpty)
            XCTAssertFalse(data.credentialError.isEmpty)
            await credentials.configure(readFailure: status)
            await data.loadCredentials()
            let writes = await credentials.writes
            XCTAssertTrue(writes.isEmpty)
            data.stop()
        }
    }

    func testFailedPlaintextMigrationRemainsBoundToOriginalProviderAfterRestart() async {
        let defaults = defaults()
        defaults.set("original-test-token", forKey: "accessToken")
        let credentials = MemoryCredentials()
        await credentials.configure(writeFailure: errSecAuthFailed)
        let first = RuntimeData(defaults: defaults, credentials: credentials, apiSession: session())
        await first.loadCredentials()
        first.provider = .gitlab
        await eventually { !first.isLoadingCredentials && first.credentialAccount?.hasPrefix("gitlab:") == true }
        first.stop()
        await credentials.configure()
        let restarted = RuntimeData(defaults: defaults, credentials: credentials, apiSession: session())
        await restarted.loadCredentials()
        XCTAssertEqual(restarted.accessToken, "")
        XCTAssertEqual(defaults.string(forKey: "accessToken"), "original-test-token")
        let stored = await credentials.snapshot()
        XCTAssertTrue(stored.isEmpty)
        restarted.provider = .github
        await eventually { restarted.accessToken == "original-test-token" }
        XCTAssertNil(defaults.string(forKey: "accessToken"))
        restarted.stop()
    }

    func testRemovingCredentialsHandlesDeniedDeleteAndSuccessfulRetry() async {
        let credentials = MemoryCredentials(["github": "test-token"])
        let data = RuntimeData(defaults: defaults(), credentials: credentials, apiSession: session())
        await data.loadCredentials()
        await credentials.configure(writeFailure: errSecAuthFailed)
        await data.removeAccessToken()
        XCTAssertFalse(data.credentialError.isEmpty)
        let retained = await credentials.snapshot()
        XCTAssertEqual(retained["github"], "test-token")
        await credentials.configure()
        await data.removeAccessToken()
        XCTAssertEqual(data.accessToken, "")
        XCTAssertTrue(data.notifications.isEmpty)
        let removed = await credentials.snapshot()
        XCTAssertNil(removed["github"])
        data.stop()
    }

    func testLegacyGitLabTokenMigratesOnlyToOriginalHost() async {
        let defaults = defaults(provider: .gitlab, host: "https://original.example")
        defaults.set("legacy-test-token", forKey: "accessToken")
        let credentials = MemoryCredentials(["gitlab": "legacy-test-token"])
        let data = RuntimeData(defaults: defaults, credentials: credentials, apiSession: session())
        await data.loadCredentials()
        let migrated = await credentials.snapshot()
        XCTAssertEqual(migrated["gitlab:https://original.example"], "legacy-test-token")
        XCTAssertNil(migrated["gitlab"])
        XCTAssertNil(defaults.string(forKey: "accessToken"))
        data.gitlabBaseURL = "https://different.example"
        await eventually { !data.isLoadingCredentials && data.credentialAccount == "gitlab:https://different.example" && data.accessToken.isEmpty }
        let after = await credentials.snapshot()
        XCTAssertNil(after["gitlab:https://different.example"])
        data.stop()
    }

    func testHostChangeRequiresVerificationAndFailedSaveRetainsStoredToken() async {
        let defaults = defaults(provider: .gitlab, host: "https://original.example")
        let credentials = MemoryCredentials(["gitlab:https://original.example": "old-test-token", "gitlab:https://other.example": "other-test-token"])
        let session = session()
        let data = RuntimeData(defaults: defaults, credentials: credentials, apiSession: session)
        await data.loadCredentials()
        await eventually { data.lastPull != nil }
        data.gitlabBaseURL = "https://other.example"
        await eventually { data.accountNeedsVerification && data.accessToken == "other-test-token" }
        let count = ProviderStub.state.snapshot().count
        await Task.yield()
        XCTAssertEqual(ProviderStub.state.snapshot().count, count)
        data.accessToken = "new-test-token"
        await credentials.configure(writeFailure: errSecAuthFailed)
        let (ok, _) = await data.testAccessToken()
        XCTAssertFalse(ok)
        XCTAssertTrue(data.accountNeedsVerification)
        let stored = await credentials.snapshot()
        XCTAssertEqual(stored["gitlab:https://other.example"], "other-test-token")
        data.stop()
    }

    func testStaleItemAndBulkFailuresCannotOverwriteNewAccountState() async throws {
        for action in ["read", "done", "bulkRead", "bulkDone"] {
            let gate = RequestGate()
            let session = session { request in
                if request.httpMethod != "GET" { await gate.wait(); return StubReply(500) }
                return StubReply()
            }
            let data = RuntimeData(defaults: defaults(), credentials: MemoryCredentials(["github": "test-token"]), apiSession: session)
            await data.loadCredentials()
            await eventually { data.lastPull != nil }
            data.notifications = [try Self.thread()]
            switch action {
            case "read": data.markNotificationAsRead(threadId: "1")
            case "done": data.markNotificationAsDone(threadId: "1")
            case "bulkRead": data.markAllNotificationsAsRead()
            default: data.markAllNotificationsAsDone()
            }
            await eventually { ProviderStub.state.snapshot().contains { $0.httpMethod != "GET" } }
            data.provider = .gitlab
            await eventually { !data.isLoadingCredentials && !data.errorMessage.isEmpty }
            let currentError = data.errorMessage
            await gate.open()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(data.errorMessage, currentError)
            XCTAssertFalse(data.isPerformingBulkAction)
            data.stop()
        }
    }

    func testBulkConfirmationCannotApplyToChangedAccountAndUsesOriginalLoadedScope() async throws {
        let data = RuntimeData(defaults: defaults(), credentials: MemoryCredentials(["github": "test-token"]), apiSession: session())
        await data.loadCredentials()
        await eventually { data.lastPull != nil }
        data.notifications = [try Self.thread()]
        let context = try XCTUnwrap(data.prepareBulkAction(.done))
        XCTAssertTrue(context.message.contains("loaded"))
        data.provider = .gitlab
        data.performBulkAction(context)
        XCTAssertTrue(data.statusMessage.contains("account changed"))
        XCTAssertFalse(ProviderStub.state.snapshot().contains { $0.httpMethod == "DELETE" })
        data.stop()
    }

    func testRateLimitBlocksManualRefreshVerificationAndActions() async throws {
        let data = RuntimeData(defaults: defaults(), credentials: MemoryCredentials(["github": "test-token"]), apiSession: session { request in
            request.url?.path == "/notifications" ? StubReply(429, headers: ["Retry-After": "120"]) : StubReply()
        })
        await data.loadCredentials()
        await eventually { data.errorMessage.contains("rate limiting") }
        let count = ProviderStub.state.snapshot().count
        data.notifications = [try Self.thread()]
        data.refreshNotifications()
        data.loadMoreNotifications()
        data.markNotificationAsRead(threadId: "1")
        data.markAllNotificationsAsDone()
        let (ok, message) = await data.testAccessToken()
        XCTAssertFalse(ok)
        XCTAssertTrue(message.contains("retry interval"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ProviderStub.state.snapshot().count, count)
        XCTAssertTrue(data.loadMoreError.contains("retry interval"))
        data.stop()
    }

    func testManualRefreshDoesNotImmediatelyPollAgain() async throws {
        let data = RuntimeData(defaults: defaults(), credentials: MemoryCredentials(["github": "test-token"]), apiSession: session())
        await data.loadCredentials()
        await eventually { data.lastPull != nil }
        let before = data.lastPull
        data.refreshNotifications()
        await eventually { !data.isRefreshing && data.lastPull != before }
        let count = ProviderStub.state.snapshot().filter { $0.url?.path == "/notifications" }.count
        XCTAssertEqual(count, 2)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(ProviderStub.state.snapshot().filter { $0.url?.path == "/notifications" }.count, count)
        data.stop()
    }

    /// Exercise the production SwiftUI button and native confirmation, not just
    /// the model. All credentials and HTTP responses are local test fixtures.
    func testWindowBulkConfirmationRunsBothProvidersReadAndDone() async throws {
        try await exerciseBulkConfirmation(inPopover: false, cancel: false)
    }

    func testPopoverBulkConfirmationRunsBothProvidersReadAndDone() async throws {
        try await exerciseBulkConfirmation(inPopover: true, cancel: false)
    }

    func testPopoverCancelNeverMutatesEitherProvider() async throws {
        try await exerciseBulkConfirmation(inPopover: true, cancel: true)
    }

    func testPopoverReturnConfirmsBothProvidersReadAndDone() async throws {
        try await exerciseBulkConfirmation(inPopover: true, cancel: false, keyboard: true)
    }

    func testPopoverEscapeCancelsBothProvidersReadAndDone() async throws {
        try await exerciseBulkConfirmation(inPopover: true, cancel: true, keyboard: true)
    }

    private func exerciseBulkConfirmation(inPopover: Bool, cancel: Bool, keyboard: Bool = false) async throws {
        for provider in NotificationProvider.allCases {
            for kind in [BulkActionContext.Kind.read, .done] {
                let data = RuntimeData(defaults: defaults(provider: provider), credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session { request in
                    request.httpMethod == "GET" ? StubReply() : StubReply(205)
                })
                await data.loadCredentials()
                await eventually { data.lastPull != nil }
                data.notifications = [try Self.thread(provider: provider)]
                let host = NSHostingView(rootView: ContentView().environmentObject(data))
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                NSApp.activate()
                let popover = NSPopover()
                if inPopover {
                    // Use a visible test-owned anchor; a real status item can be
                    // hidden by the user's crowded/notched menu bar.
                    let anchor = NSButton(frame: NSRect(x: 20, y: 20, width: 80, height: 30))
                    anchor.title = "GitBird Test"
                    window.contentView?.addSubview(anchor)
                    window.makeKeyAndOrderFront(nil)
                    let controller = NSViewController()
                    controller.view = host
                    popover.contentViewController = controller
                    popover.contentSize = NSSize(width: 420, height: 520)
                    popover.behavior = .applicationDefined
                    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
                } else {
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                }
                defer { popover.close(); window.close(); data.stop() }
                if inPopover { await eventually { popover.isShown } }
                let contentRoot: [Any] = [host]
                let label = kind == .read ? "bulkRead" : "bulkDone"
                await eventually { self.accessibilityButton(named: label, roots: contentRoot) != nil }
                let action = try XCTUnwrap(accessibilityButton(named: label, roots: contentRoot))
                XCTAssertTrue(pressAccessibilityButton(action))
                let confirmationLabel = cancel ? "Cancel" : (provider == .gitlab ? "Complete all Todos" : "Confirm")
                await eventually { self.accessibilityButton(named: confirmationLabel, roots: contentRoot) != nil }
                let confirm = try XCTUnwrap(accessibilityButton(named: confirmationLabel, roots: contentRoot))
                if inPopover { XCTAssertTrue(popover.isShown, "Confirmation must retain the menu-bar host") }
                if keyboard {
                    let popupWindow = try XCTUnwrap(host.window)
                    let key = cancel ? "\u{1b}" : "\r"
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: popupWindow.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: cancel ? 53 : 36))
                    XCTAssertTrue(popupWindow.performKeyEquivalent(with: event))
                } else {
                    XCTAssertTrue(pressAccessibilityButton(confirm))
                }
                if cancel {
                    await eventually { self.accessibilityButton(named: "bulkRead", roots: contentRoot) != nil }
                    XCTAssertFalse(ProviderStub.state.snapshot().contains { $0.httpMethod != "GET" })
                    XCTAssertEqual(data.notifications.count, 1)
                } else {
                    let method = provider == .gitlab ? "POST" : (kind == .read ? "PUT" : "DELETE")
                    await eventually { ProviderStub.state.snapshot().contains { $0.httpMethod == method } }
                    await eventually { !data.isPerformingBulkAction && data.notifications.isEmpty }
                }
                XCTAssertEqual(data.errorMessage, "")
            }
        }
    }

    private func accessibilityButton(named name: String, roots: [Any]) -> NSObject? {
        // SwiftUI accessibility nodes implement the documented Objective-C
        // selectors without declaring the complete NSAccessibility protocol.
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
        func find(_ node: Any, depth: Int) -> NSObject? {
            guard depth < 20, let element = node as? NSObject else { return nil }
            if attribute(element, "accessibilityRole") as? String == "AXButton",
               attribute(element, "accessibilityLabel") as? String == name || attribute(element, "accessibilityTitle") as? String == name || attribute(element, "accessibilityIdentifier") as? String == name { return element }
            for child in attribute(element, "accessibilityChildren") as? [Any] ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        for root in roots { if let found = find(root, depth: 0) { return found } }
        return nil
    }

    private func pressAccessibilityButton(_ button: NSObject) -> Bool {
        if let control = button as? NSButton { control.performClick(nil); return true }
        if let cell = button as? NSButtonCell, let control = cell.controlView as? NSButton { control.performClick(nil); return true }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard button.responds(to: selector), let implementation = button.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(implementation, to: Press.self)(button, selector).boolValue
    }

    func testGitLabBulkFailuresPreserveHTTPGuidanceAndRateLimits() async throws {
        for status in [401, 429] {
            for kind in [BulkActionContext.Kind.read, .done] {
                let data = RuntimeData(defaults: defaults(provider: .gitlab), credentials: MemoryCredentials(["gitlab:https://gitlab.example": "test-token"]), apiSession: session { request in
                    request.httpMethod == "GET" ? StubReply() : StubReply(status, headers: status == 429 ? ["Retry-After": "120"] : [:])
                })
                await data.loadCredentials()
                await eventually { data.lastPull != nil }
                data.notifications = [try Self.thread(provider: .gitlab)]
                let context = try XCTUnwrap(data.prepareBulkAction(kind))
                data.performBulkAction(context)
                await eventually { !data.isPerformingBulkAction && !data.errorMessage.isEmpty }
                XCTAssertTrue(data.errorMessage.contains(status == 401 ? "invalid or expired" : "rate limiting"))
                XCTAssertEqual(data.notifications.count, 1)
                if status == 429 {
                    let before = ProviderStub.state.snapshot().count
                    data.performBulkAction(context)
                    await Task.yield()
                    XCTAssertEqual(ProviderStub.state.snapshot().count, before)
                }
                data.stop()
            }
        }
    }

    func testBulkReadRetainsNilConfirmedCutoffAndReconcilesLoadedScope() async throws {
        for provider in NotificationProvider.allCases {
            let data = RuntimeData(defaults: defaults(provider: provider), credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session())
            await data.loadCredentials()
            await eventually { data.lastPull != nil }
            data.lastPull = nil
            data.notifications = [try Self.thread(provider: provider)]
            let context = try XCTUnwrap(data.prepareBulkAction(.read))
            data.lastPull = .now
            data.notifications.append(try Self.thread(provider: provider, id: "2"))
            data.performBulkAction(context)
            await eventually { !data.isPerformingBulkAction && ProviderStub.state.snapshot().contains { $0.httpMethod != "GET" } }
            XCTAssertTrue(data.notifications.isEmpty, "The confirmed account-wide read action includes subsequently loaded items")
            if provider == .github {
                let request = try XCTUnwrap(ProviderStub.state.snapshot().first { $0.httpMethod == "PUT" })
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertNil(json["last_read_at"], "A nil confirmed cutoff must stay nil")
            }
            data.stop()
        }
    }

    func testBulkDoneUsesLoadedGitHubSnapshotAndCurrentGitLabScope() async throws {
        for provider in NotificationProvider.allCases {
            let data = RuntimeData(defaults: defaults(provider: provider), credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session())
            await data.loadCredentials()
            await eventually { data.lastPull != nil }
            data.notifications = [try Self.thread(provider: provider)]
            let context = try XCTUnwrap(data.prepareBulkAction(.done))
            data.notifications.append(try Self.thread(provider: provider, id: "2"))
            data.performBulkAction(context)
            await eventually { !data.isPerformingBulkAction && ProviderStub.state.snapshot().contains { $0.httpMethod != "GET" } }
            if provider == .github {
                XCTAssertEqual(data.notifications.map(\.id), ["2"])
                let requests = ProviderStub.state.snapshot().filter { $0.httpMethod == "DELETE" }
                XCTAssertEqual(requests.map { $0.url?.path }, ["/notifications/threads/1"])
            } else {
                XCTAssertTrue(data.notifications.isEmpty)
                XCTAssertEqual(ProviderStub.state.snapshot().first { $0.httpMethod == "POST" }?.url?.path, "/api/v4/todos/mark_as_done")
            }
            data.stop()
        }
    }

    func testBulkReadHonorsConfirmedCutoffAndShowReadSetting() async throws {
        for provider in NotificationProvider.allCases {
            let settings = defaults(provider: provider)
            settings.set(false, forKey: "hideReadNotifications")
            let data = RuntimeData(defaults: settings, credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session())
            await data.loadCredentials()
            await eventually { data.lastPull != nil }
            let cutoff = Date(timeIntervalSince1970: 1_700_000_010)
            data.lastPull = cutoff
            data.notifications = [try Self.thread(provider: provider)]
            let context = try XCTUnwrap(data.prepareBulkAction(.read))
            data.lastPull = cutoff.addingTimeInterval(60)
            data.notifications.append(try Self.thread(provider: provider, id: "2", updatedAt: cutoff.addingTimeInterval(-1)))
            data.notifications.append(try Self.thread(provider: provider, id: "3", updatedAt: cutoff.addingTimeInterval(1)))
            data.performBulkAction(context)
            await eventually { !data.isPerformingBulkAction && !data.statusMessage.isEmpty }
            XCTAssertEqual(data.notifications.count, 3)
            XCTAssertEqual(data.notifications.filter(\.unread).map(\.id), provider == .github ? ["3"] : [])
            if provider == .github {
                let request = try XCTUnwrap(ProviderStub.state.snapshot().first { $0.httpMethod == "PUT" })
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["last_read_at"] as? String, "2023-11-14T22:13:30Z")
                XCTAssertEqual(json["read"] as? Bool, true)
            }
            data.stop()
        }
    }

    func testBulkFailureCanRetryAndSuccessClearsOldError() async throws {
        for provider in NotificationProvider.allCases {
            for kind in [BulkActionContext.Kind.read, .done] {
                let data = RuntimeData(defaults: defaults(provider: provider), credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session { request in
                    request.httpMethod == "GET" ? StubReply() : StubReply(401)
                })
                await data.loadCredentials()
                await eventually { data.lastPull != nil }
                data.notifications = [try Self.thread(provider: provider)]
                let context = try XCTUnwrap(data.prepareBulkAction(kind))
                data.performBulkAction(context)
                await eventually { !data.isPerformingBulkAction && !data.errorMessage.isEmpty }
                XCTAssertEqual(data.notifications.count, 1)
                ProviderStub.state.reconfigureCurrent { _ in StubReply(205) }
                data.performBulkAction(context)
                await eventually { !data.isPerformingBulkAction && data.notifications.isEmpty }
                XCTAssertEqual(data.errorMessage, "")
                XCTAssertFalse(data.statusMessage.isEmpty)
                data.stop()
            }
        }
    }

    func testBulkBusyStatePreventsDuplicateAndIndividualRequests() async throws {
        for provider in NotificationProvider.allCases {
            for kind in [BulkActionContext.Kind.read, .done] {
                let gate = RequestGate()
                let data = RuntimeData(defaults: defaults(provider: provider), credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session { request in
                    if request.httpMethod != "GET" { await gate.wait() }
                    return StubReply(205)
                })
                await data.loadCredentials()
                await eventually { data.lastPull != nil }
                data.notifications = [try Self.thread(provider: provider)]
                let context = try XCTUnwrap(data.prepareBulkAction(kind))
                data.performBulkAction(context)
                await eventually { ProviderStub.state.snapshot().contains { $0.httpMethod != "GET" } }
                XCTAssertTrue(data.isPerformingBulkAction)
                data.performBulkAction(context)
                data.markNotificationAsRead(threadId: "1")
                data.markNotificationAsDone(threadId: "1")
                await gate.open()
                await eventually { !data.isPerformingBulkAction && data.notifications.isEmpty }
                XCTAssertEqual(ProviderStub.state.snapshot().filter { $0.httpMethod != "GET" }.count, 1)
                data.stop()
            }
        }
    }

    func testIndividualReadAndDoneOnlyChangeRequestedItemForBothProviders() async throws {
        for provider in NotificationProvider.allCases {
            for kind in [BulkActionContext.Kind.read, .done] {
                let data = RuntimeData(defaults: defaults(provider: provider), credentials: MemoryCredentials(["github": "test-token", "gitlab:https://gitlab.example": "test-token"]), apiSession: session { request in
                    request.httpMethod == "GET" ? StubReply() : StubReply(205)
                })
                await data.loadCredentials()
                await eventually { data.lastPull != nil }
                data.notifications = [try Self.thread(provider: provider), try Self.thread(provider: provider, id: "2")]
                if kind == .read { data.markNotificationAsRead(threadId: "1") }
                else { data.markNotificationAsDone(threadId: "1") }
                await eventually { !data.statusMessage.isEmpty }
                XCTAssertEqual(data.notifications.map(\.id), ["2"])
                let requests = ProviderStub.state.snapshot().filter { $0.httpMethod != "GET" }
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.httpMethod, provider == .gitlab ? "POST" : (kind == .read ? "PATCH" : "DELETE"))
                XCTAssertEqual(requests.first?.url?.path, provider == .gitlab ? "/api/v4/todos/1/mark_as_done" : "/notifications/threads/1")
                data.stop()
            }
        }
    }

    func testSearchMatchesTitleRepositoryAndReasonWithoutNetwork() throws {
        let thread = try Self.thread()
        for query in ["", "  ", "SEARCH", "organisation", "review_requested"] { XCTAssertTrue(thread.matchesSearch(query)) }
        XCTAssertFalse(thread.matchesSearch("no matching words"))
    }

    nonisolated private static func todo(_ id: Int, state: String) -> String {
        """
        [{"id":\(id),"body":"Todo","target_title":"Todo","target_type":"Issue","target_url":"https://gitlab.example/project/issues/1","created_at":"2026-09-30T00:00:00Z","updated_at":"2026-09-30T00:00:00Z","state":"\(state)"}]
        """
    }

    nonisolated private static func thread(provider: NotificationProvider = .github, id: String = "1", updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> GitHubNotificationThread {
        GitHubNotificationThread(id: id, repository: GitHubRepository(fullName: "organisation/repository", owner: nil),
            subject: .init(title: "Search regression", type: "Issue", url: nil, latestCommentUrl: nil), reason: "review_requested", unread: true,
            updatedAt: updatedAt, lastReadAt: nil, url: URL(string: provider == .github ? "https://api.github.com/notifications/threads/\(id)" : "https://gitlab.example/api/v4/todos/\(id)")!, subscriptionUrl: nil)
    }
}
