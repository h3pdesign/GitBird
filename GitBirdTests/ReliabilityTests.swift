import XCTest
import Foundation
import Security
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
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) async throws -> StubReply)?
    private var requests: [URLRequest] = []
    func configure(_ handler: @escaping @Sendable (URLRequest) async throws -> StubReply) {
        lock.withLock { self.handler = handler; requests = [] }
    }
    func take(_ request: URLRequest) -> (@Sendable (URLRequest) async throws -> StubReply)? {
        lock.withLock { requests.append(request); return handler }
    }
    func snapshot() -> [URLRequest] { lock.withLock { requests } }
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
        ProviderStub.state.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStub.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
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

    nonisolated private static func thread() throws -> GitHubNotificationThread {
        GitHubNotificationThread(id: "1", repository: GitHubRepository(fullName: "organisation/repository", owner: nil),
            subject: .init(title: "Search regression", type: "Issue", url: nil, latestCommentUrl: nil), reason: "review_requested", unread: true,
            updatedAt: .now, lastReadAt: nil, url: URL(string: "https://api.github.com/notifications/threads/1")!, subscriptionUrl: nil)
    }
}
