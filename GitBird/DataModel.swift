//
//  DataModel.swift
//  GitBird
//
//  Created by rook1e on 2023/10/6.
//

import Foundation
import Security


enum NotificationProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case github
    case gitlab

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var defaultBaseURL: URL {
        switch self {
        case .github: return URL(string: "https://api.github.com")!
        case .gitlab: return URL(string: "https://gitlab.com")!
        }
    }
    var loginURL: URL {
        switch self {
        case .github: return URL(string: "https://github.com/settings/tokens")!
        case .gitlab: return URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")!
        }
    }
    var notificationsURL: URL {
        switch self {
        case .github: return URL(string: "https://github.com/notifications")!
        case .gitlab: return URL(string: "https://gitlab.com/dashboard/todos")!
        }
    }
}

protocol CredentialStorage: Sendable {
    func token(for account: String) async throws -> String?
    func set(_ token: String, for account: String) async throws
}

enum CredentialError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            switch status {
            case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
                return "Keychain access was denied or is unavailable. Unlock your Keychain and retry in Account settings."
            default:
                return "The token couldn’t be saved or loaded securely. Retry in Account settings."
            }
        case .invalidData:
            return "The saved token couldn’t be read. Verify and save a new token in Account settings."
        }
    }
}

/// Security calls may wait for user consent. Keep them off the UI actor.
actor TokenStore: CredentialStorage {
    static let shared = TokenStore()
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "GitBird") {
        self.service = service
    }

    static func account(for provider: NotificationProvider, gitlabBaseURL: String) -> String? {
        if provider == .github { return "github" }
        guard let url = validatedGitLabBaseURL(gitlabBaseURL) else { return nil }
        return "gitlab:\(url.absoluteString)"
    }

    private func query(for account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func token(for account: String) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw CredentialError.invalidData }
        return token.isEmpty ? nil : token
    }

    func set(_ token: String, for account: String) throws {
        let query = query(for: account)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }
}

func validatedGitLabBaseURL(_ value: String) -> URL? {
    guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty,
          components.path.isEmpty || components.path == "/",
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil else { return nil }
    components.scheme = "https"
    components.host = host.lowercased()
    if components.port == 443 { components.port = nil }
    components.path = ""
    return components.url
}

/// Authenticated redirects must keep the exact HTTPS origin, including port.
final class AuthenticatedRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static func allows(from original: URL, to destination: URL) -> Bool {
        original.scheme?.lowercased() == "https" && destination.scheme?.lowercased() == "https"
            && original.host?.lowercased() == destination.host?.lowercased()
            && (original.port ?? 443) == (destination.port ?? 443)
            && destination.user == nil && destination.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let source = original.url, let target = request.url,
              Self.allows(from: source, to: target) else { completionHandler(nil); return }
        var redirected = request
        for name in ["Authorization", "PRIVATE-TOKEN"] {
            if let value = original.value(forHTTPHeaderField: name) {
                redirected.setValue(value, forHTTPHeaderField: name)
            }
        }
        completionHandler(redirected)
    }
}

struct NotificationPage: Sendable {
    let threads: [GitHubNotificationThread]
    let hasNext: Bool
    let minimumPollDelay: TimeInterval?
}

struct NotificationFetchResult: Sendable {
    let page: NotificationPage?
    let errorMessage: String
    let minimumPollDelay: TimeInterval?
    var isSuccess: Bool { page != nil }
}

enum PollingPolicy {
    static func delay(interval: Int, failures: Int, providerMinimum: TimeInterval? = nil) -> TimeInterval {
        let base = Double(max(interval, 30))
        let delay = failures == 0 ? base : min(base * Double(1 << min(failures, 4)), max(base, 900))
        return max(delay, providerMinimum ?? 0)
    }
}

// GitHub REST API: GET /notifications
// https://docs.github.com/en/rest/activity/notifications#list-notifications-for-the-authenticated-user

struct GitHubUser: Identifiable, Codable, Hashable, Sendable {
    let id: Int64
    let login: String
    let avatarUrl: URL
}

struct GitHubRepository: Codable, Sendable {
    let fullName: String
    let owner: GitHubUser?
}

struct GitLabTodo: Codable, Sendable {
    let id: Int64
    let body: String?
    let actionName: String?
    let targetType: String?
    let targetTitle: String?
    let targetUrl: URL?
    let project: GitLabProject?
    let author: GitLabAuthor?
    let createdAt: Date
    let updatedAt: Date
    let state: String?
}

struct GitLabProject: Codable, Sendable {
    let pathWithNamespace: String?
    let webUrl: URL?
}

struct GitLabAuthor: Codable, Sendable {
    let id: Int64
    let username: String
    let avatarUrl: URL?
}

struct GitHubNotificationThread: Identifiable, Codable, Sendable {
    let id: String

    let repository: GitHubRepository

    let subject: Subject
    struct Subject: Codable, Sendable {
        let title: String
        let type: String
        let url: URL?
        let latestCommentUrl: URL?
    }

    let reason: String
    let unread: Bool
    let updatedAt: Date
    let lastReadAt: Date?
    let url: URL
    let subscriptionUrl: URL?
}

extension GitHubNotificationThread {
    func matchesSearch(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || subject.title.localizedStandardContains(query)
            || repository.fullName.localizedStandardContains(query) || reason.localizedStandardContains(query)
    }
}

extension GitHubNotificationThread.Subject {
    func preferredWebURL() -> URL? {
        guard let apiURL = url else { return nil }

        // Best-effort conversion for a few common API URLs.
        if apiURL.host == "api.github.com" {
            let parts = apiURL.pathComponents
            if parts.count >= 3, parts[1] == "repos" {
                let rest = parts.dropFirst(2).joined(separator: "/")
                var webPath = "/" + rest
                webPath = webPath.replacingOccurrences(of: "/pulls/", with: "/pull/")
                webPath = webPath.replacingOccurrences(of: "/commits/", with: "/commit/")
                return URL(string: "https://github.com" + webPath)
            }
        }

        return apiURL
    }
}

struct GitHubSubjectDetails: Equatable, Sendable {
    let htmlUrl: URL?
    let participants: [GitHubUser]
}

enum GitHubNotificationReferrerId {
    private static let queryName = "notification_referrer_id"

    static func value(threadId: String, userId: Int64) -> String {
        // Matches GitHub's tracking format used when opening a notification thread from the inbox.
        // Example raw string: "018:NotificationThread138661096:123456789"
        let raw = "018:NotificationThread\(threadId):\(userId)"
        return Data(raw.utf8).base64EncodedString()
    }

    static func appending(to url: URL, threadId: String, userId: Int64) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == queryName }) else {
            return url
        }

        items.append(URLQueryItem(name: queryName, value: value(threadId: threadId, userId: userId)))
        components.queryItems = items
        return components.url ?? url
    }
}

func fetchNotificationThreads(
    accessToken: String,
    provider: NotificationProvider,
    gitlabBaseURL: URL?,
    page: Int = 1,
    perPage: Int = 50,
    includeRead: Bool = false,
    session: URLSession = GitHubAPIClient.defaultSession
) async -> NotificationFetchResult {
    do {
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: gitlabBaseURL, session: session)
        let page = try await api.fetchNotifications(page: page, perPage: perPage, includeRead: includeRead)
        return NotificationFetchResult(page: page, errorMessage: "", minimumPollDelay: page.minimumPollDelay)
    } catch let error as GitHubAPIClient.APIError {
        return NotificationFetchResult(page: nil, errorMessage: error.localizedDescription, minimumPollDelay: error.retryAfter)
    } catch is CancellationError {
        return NotificationFetchResult(page: nil, errorMessage: "", minimumPollDelay: nil)
    } catch let error as URLError {
        let message: String
        switch error.code {
        case .notConnectedToInternet: message = "You’re offline. GitBird will retry when the connection returns."
        case .timedOut: message = "The provider timed out. Check your connection or GitLab host and retry."
        case .cannotFindHost, .cannotConnectToHost: message = "The provider host is unreachable. Check the host and your connection."
        case .cancelled: message = ""
        default: message = "Couldn’t connect securely to the provider. Check your connection and retry."
        }
        return NotificationFetchResult(page: nil, errorMessage: message, minimumPollDelay: nil)
    } catch {
        return NotificationFetchResult(page: nil, errorMessage: "The provider returned an unreadable response. Please retry.", minimumPollDelay: nil)
    }
}

enum GitHubDate {
    private static let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true).parseStrategy
    private static let withoutFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: false).parseStrategy

    static func parse(_ value: String) -> Date? {
        if let d = try? withFractional.parse(value) { return d }
        if let d = try? withoutFractional.parse(value) { return d }
        return nil
    }
}

struct GitHubAPIClient: Sendable {
    enum APIError: LocalizedError {
        case invalidResponse
        case httpError(statusCode: Int, body: String, retryAfter: TimeInterval? = nil)

        var retryAfter: TimeInterval? {
            if case .httpError(_, _, let delay) = self { return delay }
            return nil
        }
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The provider returned an invalid response. Check your Account settings and retry."
            case .httpError(let status, _, let delay):
                if delay != nil || status == 429 { return "The provider is rate limiting requests. GitBird will wait before retrying." }
                switch status {
                case 401: return "Your token is invalid or expired. Verify and save a new token in Account settings."
                case 403: return "Your token lacks permission for notifications. Check its scopes and repository access in Account settings."
                case 404: return "The provider endpoint wasn’t found. Check the GitLab host or account access."
                default: return "The provider request failed (HTTP \(status)). Please retry."
                }
            }
        }
    }

    static func minimumDelay(from response: HTTPURLResponse, now: Date = .now, includePollInterval: Bool = true) -> TimeInterval? {
        var delays: [TimeInterval] = []
        for header in (includePollInterval ? ["X-Poll-Interval", "Retry-After"] : ["Retry-After"]) {
            if let raw = response.value(forHTTPHeaderField: header) {
                if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
                    delays.append(seconds)
                } else if header == "Retry-After" {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let date = formatter.date(from: raw) { delays.append(max(0, date.timeIntervalSince(now))) }
                }
            }
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let reset = Double(raw), reset.isFinite {
            delays.append(max(0, reset - now.timeIntervalSince1970))
        }
        return delays.max()
    }

    static func responseError(_ http: HTTPURLResponse, data: Data) -> APIError {
        let body = String(decoding: data, as: UTF8.self)
        let delay = minimumDelay(from: http, includePollInterval: false)
            ?? ((http.statusCode == 429 || (http.statusCode == 403 && body.localizedStandardContains("rate limit"))) ? 60 : nil)
        return .httpError(statusCode: http.statusCode, body: body, retryAfter: delay)
    }

    static func hasNextPage(_ response: HTTPURLResponse) -> Bool {
        if let next = response.value(forHTTPHeaderField: "X-Next-Page"), let page = Int(next), page > 0 { return true }
        guard let link = response.value(forHTTPHeaderField: "Link") else { return false }
        return link.split(separator: ",").contains { $0.contains("rel=\"next\"") }
    }

    let token: String
    let provider: NotificationProvider
    let baseURL: URL
    let session: URLSession

    init(token: String, provider: NotificationProvider, gitlabBaseURL: URL?, session: URLSession = Self.defaultSession) {
        self.token = token
        self.session = session
        self.provider = provider
        self.baseURL = provider == .gitlab ? (gitlabBaseURL ?? provider.defaultBaseURL) : provider.defaultBaseURL
    }

    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config, delegate: AuthenticatedRedirectPolicy(), delegateQueue: nil)
    }()

    func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue(provider == .gitlab ? "application/json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        if provider == .gitlab {
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        } else {
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func fetch<T: Decodable>(_ url: URL) async throws -> T {
        guard isAllowedAuthenticatedURL(url) else {
            throw APIError.invalidResponse
        }
        let started = Date()
#if DEBUG
        AppLog.debug("HTTP GET request")
#endif
        let (data, response) = try await session.data(for: makeRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            AppLog.warning("HTTP invalid response")
            throw APIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
#if DEBUG
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.debug("HTTP \(http.statusCode) response (\(ms)ms)")
#endif
            throw Self.responseError(http, data: data)
        }

#if DEBUG
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.debug("HTTP 2xx response (\(ms)ms)")
#endif

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = GitHubDate.parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        return try decoder.decode(T.self, from: data)
    }

    func fetchNotifications() async throws -> [GitHubNotificationThread] {
        try await fetch(baseURL.appendingPathComponent("notifications"))
    }

    func fetchViewer() async throws -> GitHubUser {
        guard provider == .github else { throw APIError.invalidResponse }
        return try await fetch(baseURL.appendingPathComponent("user"))
    }

    func isAllowedAuthenticatedURL(_ url: URL) -> Bool {
        AuthenticatedRedirectPolicy.allows(from: baseURL, to: url)
    }

    func fetchNotifications(page: Int, perPage: Int, includeRead: Bool = false) async throws -> NotificationPage {
        let endpoint = provider == .gitlab ? baseURL.appendingPathComponent("api/v4/todos") : baseURL.appendingPathComponent("notifications")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = provider == .gitlab ? [
            URLQueryItem(name: "state", value: "pending"),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "per_page", value: String(min(max(perPage, 1), 50)))
        ] : [
            URLQueryItem(name: "all", value: includeRead ? "true" : "false"),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "per_page", value: String(min(max(perPage, 1), 50)))
        ]
        let url = components.url!
        guard isAllowedAuthenticatedURL(url) else { throw APIError.invalidResponse }

        let started = Date()
 #if DEBUG
        AppLog.debug("HTTP GET request")
 #endif
        let (data, response) = try await session.data(for: makeRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            AppLog.warning("HTTP invalid response")
            throw APIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
 #if DEBUG
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.debug("HTTP \(http.statusCode) response (\(ms)ms)")
 #endif
            throw Self.responseError(http, data: data)
        }

 #if DEBUG
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.debug("HTTP 2xx response (\(ms)ms)")
 #endif

        var hasNext = Self.hasNextPage(http)
        var minimumPollDelay = Self.minimumDelay(from: http)
        var responsePayloads = [data]
        if provider == .gitlab && includeRead {
            var doneComponents = components
            doneComponents.queryItems = [
                URLQueryItem(name: "state", value: "done"),
                URLQueryItem(name: "page", value: String(max(page, 1))),
                URLQueryItem(name: "per_page", value: String(min(max(perPage, 1), 50)))
            ]
            let doneURL = doneComponents.url!
            guard isAllowedAuthenticatedURL(doneURL) else { throw APIError.invalidResponse }
            let (doneData, doneResponse) = try await session.data(for: makeRequest(url: doneURL))
            guard let doneHTTP = doneResponse as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200...299).contains(doneHTTP.statusCode) else { throw Self.responseError(doneHTTP, data: doneData) }
            hasNext = hasNext || Self.hasNextPage(doneHTTP)
            if let delay = Self.minimumDelay(from: doneHTTP) { minimumPollDelay = max(minimumPollDelay ?? 0, delay) }
            responsePayloads.append(doneData)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = GitHubDate.parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        let threads: [GitHubNotificationThread]
        if provider == .gitlab {
            let todos = try responsePayloads.flatMap { try decoder.decode([GitLabTodo].self, from: $0) }
            threads = todos.map { todo in
                let author = todo.author.map { GitHubUser(id: $0.id, login: $0.username, avatarUrl: $0.avatarUrl ?? URL(string: "https://gitlab.com/uploads/-/system/user/avatar/0/avatar.png")!) }
                let repository = GitHubRepository(fullName: todo.project?.pathWithNamespace ?? "GitLab", owner: author)
                let subject = GitHubNotificationThread.Subject(title: todo.targetTitle ?? todo.body ?? "GitLab notification", type: todo.targetType ?? "Todo", url: todo.targetUrl, latestCommentUrl: nil)
                let todoURL = baseURL.appendingPathComponent("api/v4/todos/\(todo.id)")
                return GitHubNotificationThread(id: String(todo.id), repository: repository, subject: subject, reason: todo.actionName ?? "Todo", unread: todo.state != "done", updatedAt: todo.updatedAt, lastReadAt: todo.state == "done" ? todo.updatedAt : nil, url: todoURL, subscriptionUrl: nil)
            }
        } else {
            threads = try decoder.decode([GitHubNotificationThread].self, from: data)
        }
        let visibleThreads = includeRead ? threads : threads.filter(\.unread)
        AppLog.debug("Notification visibility: fetched=\(threads.count), visible=\(visibleThreads.count), includeRead=\(includeRead)")
        var unique: [String: GitHubNotificationThread] = [:]
        for thread in visibleThreads {
            if let previous = unique[thread.id], previous.updatedAt > thread.updatedAt { continue }
            unique[thread.id] = thread
        }
        let merged = provider == .gitlab ? unique.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        } : visibleThreads
        return NotificationPage(threads: merged, hasNext: hasNext, minimumPollDelay: minimumPollDelay)
    }

    func markThreadAsRead(url: URL) async throws {
        guard isAllowedAuthenticatedURL(url) else { throw APIError.invalidResponse }
        var request = makeRequest(url: url)
        if provider == .gitlab {
            let actionURL = url.appendingPathComponent("mark_as_done")
            guard isAllowedAuthenticatedURL(actionURL) else { throw APIError.invalidResponse }
            request = makeRequest(url: actionURL)
            request.httpMethod = "POST"
        } else {
            request.httpMethod = "PATCH"
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.responseError(http, data: data)
        }
    }

    func markThreadAsDone(url: URL) async throws {
        guard isAllowedAuthenticatedURL(url) else { throw APIError.invalidResponse }
        var request = makeRequest(url: url)
        if provider == .gitlab {
            let actionURL = url.appendingPathComponent("mark_as_done")
            guard isAllowedAuthenticatedURL(actionURL) else { throw APIError.invalidResponse }
            request = makeRequest(url: actionURL)
            request.httpMethod = "POST"
        } else {
            request.httpMethod = "DELETE"
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.responseError(http, data: data)
        }
    }

    func markAllNotificationsAsDone(urls: [URL]) async throws {
        if provider == .gitlab {
            let actionURL = baseURL.appendingPathComponent("api/v4/todos/mark_as_done")
            guard isAllowedAuthenticatedURL(actionURL) else { throw APIError.invalidResponse }
            var request = makeRequest(url: actionURL)
            request.httpMethod = "POST"
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw APIError.invalidResponse }
            return
        }

        var iterator = urls.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                guard let url = iterator.next() else { break }
                group.addTask { try await markThreadAsDone(url: url) }
            }
            while try await group.next() != nil {
                if let url = iterator.next() {
                    group.addTask { try await markThreadAsDone(url: url) }
                }
            }
        }
    }

    func markAllNotificationsAsRead(lastReadAt: Date?, urls: [URL] = []) async throws {
        if provider == .gitlab {
            let actionURL = baseURL.appendingPathComponent("api/v4/todos/mark_as_done")
            guard isAllowedAuthenticatedURL(actionURL) else { throw APIError.invalidResponse }
            var request = makeRequest(url: actionURL)
            request.httpMethod = "POST"
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw APIError.invalidResponse }
            return
        }


        struct RequestBody: Encodable {
            let read: Bool
            let lastReadAt: String?

            enum CodingKeys: String, CodingKey {
                case read
                case lastReadAt = "last_read_at"
            }
        }

        let notificationsURL = baseURL.appendingPathComponent("notifications")
        guard isAllowedAuthenticatedURL(notificationsURL) else { throw APIError.invalidResponse }
        var request = makeRequest(url: notificationsURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                read: true,
                lastReadAt: lastReadAt.map {
                    Date.ISO8601FormatStyle(includingFractionalSeconds: false).format($0)
                }
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.responseError(http, data: data)
        }
    }

    func fetchSubjectDetails(subjectURL: URL) async -> GitHubSubjectDetails? {
        guard provider == .github, subjectURL.host?.lowercased() == "api.github.com" else {
            return nil
        }
        struct SubjectResource: Codable {
            let htmlUrl: URL?
            let user: GitHubUser?
            let assignees: [GitHubUser]?
            let requestedReviewers: [GitHubUser]?
            let author: GitHubUser?
            let committer: GitHubUser?
        }

        do {
            let res: SubjectResource = try await fetch(subjectURL)
            var seen: Set<Int64> = []
            var participants: [GitHubUser] = []

            func append(_ user: GitHubUser?) {
                guard let user else { return }
                guard !seen.contains(user.id) else { return }
                seen.insert(user.id)
                participants.append(user)
            }

            append(res.user)
            append(res.author)
            append(res.committer)
            for u in res.requestedReviewers ?? [] { append(u) }
            for u in res.assignees ?? [] { append(u) }
            return GitHubSubjectDetails(htmlUrl: res.htmlUrl, participants: participants)
        } catch {
#if DEBUG
            AppLog.debug("Subject details fetch failed")
#endif
            return nil
        }
    }
}

struct BulkActionContext: Identifiable {
    enum Kind { case read, done }
    let id = UUID()
    let kind: Kind
    let provider: NotificationProvider
    let account: String
    let generation: Int
    let threads: [GitHubNotificationThread]
    let lastPull: Date?

    var title: String {
        if provider == .gitlab { return "Complete all GitLab Todos?" }
        return kind == .done ? "Complete \(threads.count) loaded notifications?" : "Mark GitHub notifications as read?"
    }
    var message: String {
        if provider == .gitlab {
            return "This completes every pending Todo on this GitLab account, including items that haven’t been loaded. GitLab uses the same completion action for read and done."
        }
        if kind == .done {
            return "This completes the \(threads.count) loaded notifications, including those hidden by the search. Items on unloaded pages aren’t included."
        }
        if let lastPull {
            return "This marks notifications updated on or before \(lastPull.formatted(date: .abbreviated, time: .shortened)) as read across the GitHub account, including unloaded pages."
        }
        return "This marks notifications as read across the GitHub account, including unloaded pages."
    }
}

@MainActor class RuntimeData: ObservableObject {
    static let shared = RuntimeData()
    @Published var errorMessage: String = ""
    @Published var statusMessage: String = ""
    @Published var notifications: [GitHubNotificationThread] = []
    @Published var subjectDetailsByThreadId: [String: GitHubSubjectDetails] = [:]

    @Published private(set) var viewerUserId: Int64? = nil

    @Published private(set) var isLoadingMoreNotifications: Bool = false
    @Published private(set) var hasMoreNotifications: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var loadMoreError: String = ""
    @Published private(set) var isMarkingAllNotificationsAsRead: Bool = false
    @Published private(set) var isMarkingAllNotificationsAsDone: Bool = false

    @Published var listLength: Int = 10 {
        willSet(newValue) {
            defaults.set(newValue, forKey: "listLength")
        }
        didSet(oldValue) {
            if listLength == oldValue { return }
            resetPaginationState()
            renewPullTask(interval: interval)
        }
    }

    @Published var provider: NotificationProvider {
        willSet { defaults.set(newValue.rawValue, forKey: "provider") }
        didSet {
            guard provider != oldValue else { return }
            switchAccount(requireVerification: provider == .gitlab)
        }
    }

    @Published var gitlabBaseURL: String {
        willSet { defaults.set(newValue, forKey: "gitlabBaseURL") }
        didSet {
            guard TokenStore.account(for: .gitlab, gitlabBaseURL: gitlabBaseURL) != TokenStore.account(for: .gitlab, gitlabBaseURL: oldValue) else { return }
            if provider == .gitlab { switchAccount(requireVerification: true) }
        }
    }

    @Published var hideReadNotifications: Bool {
        willSet {
            defaults.set(newValue, forKey: "hideReadNotifications")
        }
        didSet {
            if hideReadNotifications == oldValue { return }
            resetPaginationState()
            renewPullTask(interval: interval)
        }
    }

    @Published var interval: Int  = 300 {
        willSet(newValue) {
            defaults.set(newValue, forKey: "interval")
        }
        didSet(oldValue) {
            if self.interval == oldValue {
                return
            }
            renewPullTask(interval: self.interval)
        }
    }
    
    private var pullTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var viewerFetchTask: Task<Int64?, Never>?
    private var requestGeneration = 0
    private var nextProviderRequestAt: Date?
    private var retryBlockedUntil: Date?
    private var actionTaskIDs = Set<String>()
    @Published var lastPull: Date?

    private var nextNotificationsPage: Int? = nil
    
    @Published var accessToken: String = ""
    @Published private(set) var isLoadingCredentials = false
    @Published private(set) var credentialError = ""
    @Published private(set) var accountNeedsVerification = false
    private var activeToken = ""
    private let credentials: any CredentialStorage
    private let defaults: UserDefaults
    private let apiSession: URLSession
    private let legacyProvider: NotificationProvider
    private let legacyGitLabAccount: String?
    private var credentialTask: Task<Void, Never>?
    private var credentialGeneration = 0
    private var didStart = false

    init(defaults: UserDefaults = .standard,
         credentials: any CredentialStorage = TokenStore.shared,
         apiSession: URLSession = GitHubAPIClient.defaultSession) {
        self.defaults = defaults
        self.credentials = credentials
        self.apiSession = apiSession
        self.interval = min(max((defaults.object(forKey: "interval") as? Int) ?? 300, 30), 3600)
        self.listLength = min(max((defaults.object(forKey: "listLength") as? Int) ?? 10, 1), 50)
        self.hideReadNotifications = defaults.object(forKey: "hideReadNotifications") as? Bool ?? true
        let selectedProvider = NotificationProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .github
        self.provider = selectedProvider
        let legacyProviderName = defaults.string(forKey: "legacyAccessTokenProvider") ?? selectedProvider.rawValue
        self.legacyProvider = NotificationProvider(rawValue: legacyProviderName) ?? selectedProvider
        if defaults.string(forKey: "accessToken") != nil, defaults.string(forKey: "legacyAccessTokenProvider") == nil {
            defaults.set(legacyProviderName, forKey: "legacyAccessTokenProvider")
        }
        let savedHost = defaults.string(forKey: "gitlabBaseURL") ?? "https://gitlab.com"
        self.gitlabBaseURL = savedHost
        // Pin the legacy provider-only token to its original saved host, even if cleanup is denied.
        let origin = defaults.string(forKey: "legacyGitLabTokenOrigin") ?? savedHost
        self.legacyGitLabAccount = TokenStore.account(for: .gitlab, gitlabBaseURL: origin)
        if defaults.string(forKey: "legacyGitLabTokenOrigin") == nil {
            defaults.set(origin, forKey: "legacyGitLabTokenOrigin")
        }
    }

    var credentialAccount: String? {
        TokenStore.account(for: provider, gitlabBaseURL: gitlabBaseURL)
    }

    private func switchAccount(requireVerification: Bool) {
        stopRequests()
        credentialTask?.cancel()
        credentialGeneration &+= 1
        activeToken = ""
        accessToken = ""
        notifications = []
        subjectDetailsByThreadId = [:]
        viewerUserId = nil
        lastPull = nil
        nextProviderRequestAt = nil
        retryBlockedUntil = nil
        statusMessage = ""
        errorMessage = ""
        credentialError = ""
        accountNeedsVerification = requireVerification
        credentialTask = Task { [weak self] in
            await self?.loadCredentials(requireVerification: requireVerification)
        }
    }

    func loadCredentials(requireVerification: Bool? = nil) async {
        let requireVerification = requireVerification ?? accountNeedsVerification
        credentialGeneration &+= 1
        let generation = credentialGeneration
        guard let account = credentialAccount else {
            isLoadingCredentials = false
            errorMessage = "Enter a valid HTTPS GitLab host in Account settings."
            return
        }
        isLoadingCredentials = true
        credentialError = ""
        let provider = provider
        do {
            var token = try await credentials.token(for: account)
            if token == nil, provider == .gitlab, account == legacyGitLabAccount,
               let legacy = try await credentials.token(for: "gitlab") {
                try await credentials.set(legacy, for: account)
                token = legacy
                // The scoped write succeeded. If removal fails, retain the original host marker.
                try await credentials.set("", for: "gitlab")
            }
            let legacyKey: String? = {
                if provider == legacyProvider, (provider == .github || account == legacyGitLabAccount), defaults.string(forKey: "accessToken") != nil { return "accessToken" }
                if provider == .github, defaults.string(forKey: "githubToken") != nil { return "githubToken" }
                return nil
            }()
            if let legacyKey, let legacy = defaults.string(forKey: legacyKey) {
                if token == nil {
                    try await credentials.set(legacy, for: account)
                    token = legacy
                }
                // Remove plaintext only after a secure value is known to exist.
                defaults.removeObject(forKey: legacyKey)
                if provider == .github { defaults.removeObject(forKey: "githubToken") }
            }
            guard generation == credentialGeneration, account == credentialAccount else { return }
            accessToken = token ?? ""
            activeToken = requireVerification ? "" : (token ?? "")
            accountNeedsVerification = requireVerification && token != nil
            isLoadingCredentials = false
            renewPullTask(interval: interval)
        } catch {
            guard generation == credentialGeneration, account == credentialAccount else { return }
            isLoadingCredentials = false
            credentialError = error.localizedDescription
            errorMessage = credentialError
        }
    }

    private func stopRequests() {
        pullTask?.cancel()
        detailsTask?.cancel()
        loadMoreTask?.cancel()
        viewerFetchTask?.cancel()
        pullTask = nil
        detailsTask = nil
        loadMoreTask = nil
        viewerFetchTask = nil
        isRefreshing = false
        actionTaskIDs.removeAll()
        _ = advanceRequestGeneration()
        resetPaginationState()
    }

    func stop() {
        credentialTask?.cancel()
        credentialGeneration &+= 1
        isLoadingCredentials = false
        stopRequests()
    }

    private var notificationsPerPage: Int {
        min(max(listLength, 1), 50)
    }

    var providerNotificationsURL: URL {
        guard provider == .gitlab,
              let baseURL = validatedGitLabBaseURL(gitlabBaseURL) else {
            return provider.notificationsURL
        }
        return baseURL.appendingPathComponent("dashboard/todos")
    }

    var providerLoginURL: URL {
        guard provider == .gitlab,
              let baseURL = validatedGitLabBaseURL(gitlabBaseURL) else {
            return provider.loginURL
        }
        return baseURL.appendingPathComponent("-/user_settings/personal_access_tokens")
    }

    var allowedAvatarHosts: Set<String> {
        switch provider {
        case .github:
            return ["github.com", "githubusercontent.com"]
        case .gitlab:
            var hosts = ["gitlab.com"]
            if let host = validatedGitLabBaseURL(gitlabBaseURL)?.host?.lowercased() {
                hosts.append(host)
            }
            return Set(hosts)
        }
    }

    private func resetPaginationState() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        nextNotificationsPage = nil
        hasMoreNotifications = false
        isLoadingMoreNotifications = false
        loadMoreError = ""
        isMarkingAllNotificationsAsRead = false
        isMarkingAllNotificationsAsDone = false
    }

    private func advanceRequestGeneration() -> Int {
        requestGeneration &+= 1
        return requestGeneration
    }

    private func notificationsDiffer(_ lhs: [GitHubNotificationThread], _ rhs: [GitHubNotificationThread]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        return zip(lhs, rhs).contains { old, new in
            old.id != new.id || old.unread != new.unread || old.updatedAt != new.updatedAt ||
            old.subject.title != new.subject.title || old.subject.type != new.subject.type || old.reason != new.reason
        }
    }
    
    func start() {
        AppLog.info("RuntimeData start")
        guard !didStart else { return }
        didStart = true
        credentialTask = Task { [weak self] in await self?.loadCredentials() }
    }

    private func honorProviderDelay(_ delay: TimeInterval?, failed: Bool) {
        guard let delay else { return }
        let deadline = Date.now.addingTimeInterval(delay)
        nextProviderRequestAt = max(nextProviderRequestAt ?? deadline, deadline)
        if failed { retryBlockedUntil = max(retryBlockedUntil ?? deadline, deadline) }
    }

    private var remainingProviderDelay: TimeInterval {
        max(0, nextProviderRequestAt?.timeIntervalSinceNow ?? 0)
    }

    func refreshNotifications() {
        if remainingProviderDelay > 0 {
            statusMessage = "Waiting for the provider’s retry interval. GitBird will retry automatically."
            return
        }
        guard !isLoadingCredentials else { return }
        guard !activeToken.isEmpty else {
            errorMessage = accountNeedsVerification ? "Verify this host’s token in Account settings before using it." : "Add an access token in Account settings to get started."
            return
        }

        pullTask?.cancel()
        detailsTask?.cancel()
        loadMoreTask?.cancel()
        pullTask = nil
        detailsTask = nil
        loadMoreTask = nil
        resetPaginationState()
        let generation = advanceRequestGeneration()

        let token = activeToken
        let apiSession = apiSession
        let provider = provider
        let gitlabBaseURL = validatedGitLabBaseURL(gitlabBaseURL)
        guard provider == .github || gitlabBaseURL != nil else {
            errorMessage = "Enter a valid HTTPS GitLab host."
            isRefreshing = false
            return
        }
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage
        isRefreshing = true
        errorMessage = ""
        statusMessage = ""

        pullTask = Task.detached(priority: .userInitiated) { [weak self, token, perPage, includeRead, provider, gitlabBaseURL, generation] in
            let result = await fetchNotificationThreads(
                accessToken: token,
                provider: provider,
                gitlabBaseURL: gitlabBaseURL,
                page: 1,
                perPage: perPage,
                includeRead: includeRead,
                session: apiSession
            )
            let firstPage = result.page?.threads ?? []
            let ok = result.isSuccess
            let hasNext = result.page?.hasNext ?? false
            let err = result.errorMessage

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.requestGeneration == generation else { return }
                if ok {
                    if self.notificationsDiffer(self.notifications, firstPage) {
                        self.notifications = firstPage
                    }
                    self.lastPull = Date()
                }
                self.honorProviderDelay(result.minimumPollDelay, failed: !ok)
                self.errorMessage = ok ? "" : err
                self.nextNotificationsPage = ok && hasNext ? 2 : nil
                self.hasMoreNotifications = ok && hasNext
                self.isLoadingMoreNotifications = false
                self.loadMoreError = ""
                self.isRefreshing = false

                let ids = Set(self.notifications.map(\.id))
                self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { details in ids.contains(details.key) }
                if ok {
                    self.prefetchSubjectDetails(for: Array(firstPage.prefix(12)))
                }
                // Manual refresh replaces the polling task. Start it again so
                // one explicit refresh cannot silently disable background sync.
                self.renewPullTask(interval: self.interval, initialDelay: PollingPolicy.delay(interval: self.interval, failures: ok ? 0 : 1, providerMinimum: result.minimumPollDelay))
            }
        }
    }

    func renewPullTask(interval: Int, initialDelay: TimeInterval = 0) {
        AppLog.info("Renew pull task (interval=\(interval)s)")
        pullTask?.cancel()
        detailsTask?.cancel()
        loadMoreTask?.cancel()
        pullTask = nil
        detailsTask = nil
        loadMoreTask = nil
        isMarkingAllNotificationsAsRead = false
        isMarkingAllNotificationsAsDone = false
        isRefreshing = false
        actionTaskIDs.removeAll()
        let generation = advanceRequestGeneration()
        
        if interval < 1 {
            self.errorMessage = "Interval is too short"
            AppLog.warning("Interval too short: \(interval)")
            return
        }
        
        if isLoadingCredentials { return }
        if activeToken.isEmpty {
            self.errorMessage = accountNeedsVerification ? "Verify this host’s token in Account settings before using it." : "Add an access token in Account settings to get started."
            AppLog.warning("Access token missing")
            return
        }
        
        let token = self.activeToken
        let apiSession = apiSession
        let provider = self.provider
        let gitlabBaseURL = validatedGitLabBaseURL(self.gitlabBaseURL)
        guard provider == .github || gitlabBaseURL != nil else {
            self.errorMessage = "Enter a valid HTTPS GitLab host."
            return
        }
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage
        let initialDelay = max(initialDelay, remainingProviderDelay)

        ensureViewerUserId()
        pullTask = Task.detached(priority: .utility) { [token, perPage, includeRead, provider, gitlabBaseURL, generation] in
            var failsCount = 0
            if initialDelay > 0 { try? await Task.sleep(for: .seconds(initialDelay)) }
            guard !Task.isCancelled else { return }
            repeat {
                let providerWait = await MainActor.run { [weak self] in self?.remainingProviderDelay ?? 0 }
                if providerWait > 0 { try? await Task.sleep(for: .seconds(providerWait)) }
                guard !Task.isCancelled else { return }
                AppLog.debug("Pull notifications (fails=\(failsCount))")
                let result = await fetchNotificationThreads(
                    accessToken: token,
                    provider: provider,
                    gitlabBaseURL: gitlabBaseURL,
                    page: 1,
                    perPage: perPage,
                    includeRead: includeRead,
                    session: apiSession
                )
                let firstPage = result.page?.threads ?? []
                let ok = result.isSuccess
                let hasNext = result.page?.hasNext ?? false
                let err = result.errorMessage

                if !ok {
                    AppLog.warning("Pull notifications failed: \(err)")
                }

                let shouldContinue = await MainActor.run { [weak self] in
                    guard let self, self.requestGeneration == generation else { return false }
                    self.honorProviderDelay(result.minimumPollDelay, failed: !ok)
                    self.errorMessage = ok ? "" : err
                    if ok {
                        let changed = self.notificationsDiffer(self.notifications, firstPage)
                        if changed {
                            self.notifications = firstPage
                        }
                        self.lastPull = Date()
                        self.nextNotificationsPage = hasNext ? 2 : nil
                        self.hasMoreNotifications = self.nextNotificationsPage != nil
                        self.isLoadingMoreNotifications = false
                        self.loadMoreError = ""

                        if changed {
                            let ids = Set(firstPage.map { $0.id })
                            self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { ids.contains($0.key) }
                            self.prefetchSubjectDetails(for: Array(firstPage.prefix(12)))
                        }
                    }
                    return true
                }

                guard shouldContinue else { return }

                
                if ok {
                    failsCount = 0
                } else {
                    failsCount += 1
                }

                if Task.isCancelled {
                    AppLog.debug("Stopping pull task (cancelled=true)")
                    return
                }

                let delay = PollingPolicy.delay(interval: interval, failures: failsCount, providerMinimum: result.minimumPollDelay)
                try? await Task.sleep(for: .seconds(delay))
            } while(!Task.isCancelled)
        }
    }

    func loadMoreNotifications() {
        if (retryBlockedUntil?.timeIntervalSinceNow ?? 0) > 0 {
            loadMoreError = "Waiting for the provider’s retry interval. Please try again later."
            return
        }
        guard !isLoadingMoreNotifications else { return }
        guard loadMoreTask == nil else { return }
        guard let page = nextNotificationsPage else { return }

        let token = activeToken
        let apiSession = apiSession
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage
        let provider = provider
        let gitlabBaseURL = validatedGitLabBaseURL(gitlabBaseURL)
        let generation = requestGeneration

        isLoadingMoreNotifications = true
        loadMoreError = ""

        loadMoreTask = Task.detached(priority: .utility) { [token, perPage, page, includeRead, provider, gitlabBaseURL, generation] in
            let result = await fetchNotificationThreads(
                accessToken: token,
                provider: provider,
                gitlabBaseURL: gitlabBaseURL,
                page: page,
                perPage: perPage,
                includeRead: includeRead,
                session: apiSession
            )
            let threads = result.page?.threads ?? []
            let ok = result.isSuccess
            let hasNext = result.page?.hasNext ?? false
            let err = result.errorMessage

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.requestGeneration == generation else { return }
                defer { self.loadMoreTask = nil }

                // Ignore stale results when pagination state changed.
                guard self.nextNotificationsPage == page else {
                    self.isLoadingMoreNotifications = false
                    return
                }

                self.isLoadingMoreNotifications = false
                self.honorProviderDelay(result.minimumPollDelay, failed: !ok)

                guard ok else {
                    self.loadMoreError = err
                    return
                }

                var seen = Set(self.notifications.map { $0.id })
                var merged = self.notifications
                for t in threads {
                    guard !seen.contains(t.id) else { continue }
                    seen.insert(t.id)
                    merged.append(t)
                }
                self.notifications = merged

                self.nextNotificationsPage = hasNext ? (page + 1) : nil
                self.hasMoreNotifications = self.nextNotificationsPage != nil

                let ids = Set(merged.map { $0.id })
                self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { ids.contains($0.key) }
            }
        }
    }

    func prefetchSubjectDetails(for threads: [GitHubNotificationThread]) {
        self.detailsTask?.cancel()

        let token = self.activeToken
        let apiSession = apiSession
        let generation = requestGeneration
        let provider = self.provider
        let gitlabBaseURL = validatedGitLabBaseURL(self.gitlabBaseURL)
        var seenURLs = Set<URL>()
        let targets = threads.compactMap { thread -> (String, URL)? in
            guard subjectDetailsByThreadId[thread.id] == nil else { return nil }
            guard let url = thread.subject.url else { return nil }
            guard seenURLs.insert(url).inserted else { return nil }
            return (thread.id, url)
        }

        guard !targets.isEmpty, !token.isEmpty else {
            return
        }

#if DEBUG
        AppLog.debug("Prefetch subject details: \(targets.count) targets")
#endif

        self.detailsTask = Task.detached(priority: .utility) {
            let api = GitHubAPIClient(token: token, provider: provider, gitlabBaseURL: gitlabBaseURL, session: apiSession)
            var fetchedDetails: [String: GitHubSubjectDetails] = [:]

            await withTaskGroup(of: (String, GitHubSubjectDetails?).self) { group in
                var it = targets.makeIterator()
                for _ in 0..<4 {
                    guard let (id, url) = it.next() else { break }
                    group.addTask { (id, await api.fetchSubjectDetails(subjectURL: url)) }
                }
                while let (id, details) = await group.next() {
                    if let details { fetchedDetails[id] = details }
                    if let (nextId, nextURL) = it.next() {
                        group.addTask { (nextId, await api.fetchSubjectDetails(subjectURL: nextURL)) }
                    }
                }
            }

            guard !Task.isCancelled, !fetchedDetails.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.requestGeneration == generation else { return }
                var merged = self.subjectDetailsByThreadId
                for (id, details) in fetchedDetails { merged[id] = details }
                self.subjectDetailsByThreadId = merged
            }
        }
    }

    private func markThreadsAsReadLocally(_ ids: Set<String>) {
        let readAt = Date.now
        for index in notifications.indices where ids.contains(notifications[index].id) {
            let thread = notifications[index]
            notifications[index] = GitHubNotificationThread(
                id: thread.id,
                repository: thread.repository,
                subject: thread.subject,
                reason: thread.reason,
                unread: false,
                updatedAt: thread.updatedAt,
                lastReadAt: readAt,
                url: thread.url,
                subscriptionUrl: thread.subscriptionUrl
            )
        }
    }

    func markNotificationAsRead(threadId: String) {
        guard let thread = notifications.first(where: { $0.id == threadId }) else { return }
        guard !activeToken.isEmpty, !isPerformingBulkAction else { return }
        guard mayPerformProviderAction(), actionTaskIDs.insert(threadId).inserted else { return }
        let generation = requestGeneration
        let api = GitHubAPIClient(token: activeToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL), session: apiSession)
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await api.markThreadAsRead(url: thread.url)
                await MainActor.run {
                    guard let self else { return }
                    guard self.requestGeneration == generation else { return }
                    self.actionTaskIDs.remove(threadId)
                    self.markThreadsAsReadLocally(Set([threadId]))
                    if self.hideReadNotifications {
                        self.notifications.removeAll { $0.id == threadId }
                    }
                    self.subjectDetailsByThreadId.removeValue(forKey: threadId)
                    self.errorMessage = ""
                    self.statusMessage = self.provider == .gitlab ? "Completed Todo" : "Marked as read"
                }
            } catch {
                AppLog.warning("Failed to mark notification as read")
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.actionTaskIDs.remove(threadId)
                    self.recordActionFailure(error, fallback: "Failed to mark as read")
                }
            }
        }
    }

    func markNotificationAsDone(threadId: String) {
        guard let thread = notifications.first(where: { candidate in candidate.id == threadId }) else { return }
        guard !activeToken.isEmpty, !isPerformingBulkAction else { return }
        guard mayPerformProviderAction(), actionTaskIDs.insert(threadId).inserted else { return }
        let generation = requestGeneration
        let api = GitHubAPIClient(token: activeToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL), session: apiSession)
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await api.markThreadAsDone(url: thread.url)
                await MainActor.run {
                    guard let self else { return }
                    guard self.requestGeneration == generation else { return }
                    self.actionTaskIDs.remove(threadId)
                    self.notifications.removeAll { candidate in candidate.id == threadId }
                    self.subjectDetailsByThreadId.removeValue(forKey: threadId)
                    self.errorMessage = ""
                    self.statusMessage = "Marked as done"
                }
            } catch {
                AppLog.warning("Failed to mark notification as done")
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.actionTaskIDs.remove(threadId)
                    self.recordActionFailure(error, fallback: "Failed to mark as done")
                }
            }
        }
    }

    private func mayPerformProviderAction() -> Bool {
        guard (retryBlockedUntil?.timeIntervalSinceNow ?? 0) <= 0 else {
            errorMessage = "Waiting for the provider’s retry interval. Please try again later."
            return false
        }
        return true
    }

    private func recordActionFailure(_ error: Error, fallback: String) {
        if let error = error as? GitHubAPIClient.APIError {
            honorProviderDelay(error.retryAfter, failed: true)
            errorMessage = error.localizedDescription
        } else if let error = error as? URLError, error.code == .notConnectedToInternet {
            errorMessage = "You are offline. Connect to the internet and retry the action."
        } else {
            errorMessage = fallback
        }
    }

    var isPerformingBulkAction: Bool { isMarkingAllNotificationsAsRead || isMarkingAllNotificationsAsDone }

    func prepareBulkAction(_ kind: BulkActionContext.Kind) -> BulkActionContext? {
        guard let account = credentialAccount, !activeToken.isEmpty, !notifications.isEmpty else { return nil }
        return BulkActionContext(kind: kind, provider: provider, account: account,
            generation: requestGeneration, threads: notifications, lastPull: lastPull)
    }

    func performBulkAction(_ context: BulkActionContext) {
        guard context.account == credentialAccount, context.generation == requestGeneration else {
            statusMessage = "The account changed. Review the current notifications and try again."
            return
        }
        switch context.kind {
        case .read: markAllNotificationsAsRead(context: context)
        case .done: markAllNotificationsAsDone(context: context)
        }
    }

    func markAllNotificationsAsDone(context: BulkActionContext? = nil) {
        guard !notifications.isEmpty else { return }
        guard !isPerformingBulkAction else { return }
        guard !activeToken.isEmpty else { return }

        guard mayPerformProviderAction() else { return }
        let targets = context?.threads ?? notifications
        let targetIDs = Set(targets.map(\.id))
        let targetURLs = targets.map(\.url)
        let generation = requestGeneration
        let api = GitHubAPIClient(token: activeToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL), session: apiSession)
        isMarkingAllNotificationsAsDone = true

        Task.detached(priority: .utility) { [weak self, targetIDs, targetURLs] in
            do {
                try await api.markAllNotificationsAsDone(urls: targetURLs)
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.isMarkingAllNotificationsAsDone = false
                    self.notifications.removeAll { targetIDs.contains($0.id) }
                    self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { !targetIDs.contains($0.key) }
                }
            } catch {
                AppLog.warning("Failed to mark all notifications as done")
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.isMarkingAllNotificationsAsDone = false
                    self.recordActionFailure(error, fallback: "Failed to mark all as done")
                }
            }
        }
    }

    func markAllNotificationsAsRead(context: BulkActionContext? = nil) {
        guard !notifications.isEmpty else { return }
        guard !isPerformingBulkAction else { return }
        guard !activeToken.isEmpty else { return }

        guard mayPerformProviderAction() else { return }
        let targets = context?.threads ?? notifications
        let targetIDs = Set(targets.map(\.id))
        let targetURLs = targets.map(\.url)
        let generation = requestGeneration
        let api = GitHubAPIClient(token: activeToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL), session: apiSession)
        let lastReadAt = context?.lastPull ?? lastPull
        isMarkingAllNotificationsAsRead = true

        Task.detached(priority: .utility) { [weak self, targetURLs] in
            do {
                try await api.markAllNotificationsAsRead(lastReadAt: lastReadAt, urls: targetURLs)
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    if self.hideReadNotifications {
                        self.notifications.removeAll { targetIDs.contains($0.id) }
                    } else {
                        self.markThreadsAsReadLocally(targetIDs)
                    }
                    self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { !targetIDs.contains($0.key) }
                    self.errorMessage = ""
                    self.statusMessage = self.provider == .gitlab ? "Completed Todos" : "Marked all as read"
                    self.isMarkingAllNotificationsAsRead = false
                }
            } catch {
                AppLog.warning("Failed to mark all notifications as read")
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.isMarkingAllNotificationsAsRead = false
                    self.recordActionFailure(error, fallback: "Failed to mark all as read")
                }
            }
        }
    }

    func urlForOpeningNotificationDetail(threadId: String, baseURL: URL) -> URL {
        guard let viewerUserId else {
            ensureViewerUserId()
            return baseURL
        }
        return GitHubNotificationReferrerId.appending(to: baseURL, threadId: threadId, userId: viewerUserId)
    }

    private func ensureViewerUserId() {
        guard provider == .github else { return }
        guard viewerUserId == nil else { return }
        guard viewerFetchTask == nil else { return }

        let token = activeToken
        let apiSession = apiSession
        let generation = requestGeneration
        guard !token.isEmpty else { return }

        let task = Task.detached(priority: .utility) { [token] () async -> Int64? in
            do {
                let api = GitHubAPIClient(token: token, provider: .github, gitlabBaseURL: nil, session: apiSession)
                let viewer = try await api.fetchViewer()
                guard !Task.isCancelled else { return nil }
                return viewer.id
            } catch {
                // Best-effort only. The app still works without this value.
                return nil
            }
        }

        viewerFetchTask = task
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = await task.value
            guard self.requestGeneration == generation, self.activeToken == token else { return }
            if let id {
                self.viewerUserId = id
            }
            self.viewerFetchTask = nil
        }
    }
    
    func removeAccessToken() async {
        guard !isLoadingCredentials, let account = credentialAccount else { return }
        credentialTask?.cancel()
        credentialGeneration &+= 1
        let generation = credentialGeneration
        let provider = provider
        stopRequests()
        activeToken = ""
        do {
            try await credentials.set("", for: account)
            if provider == .gitlab, account == legacyGitLabAccount {
                try await credentials.set("", for: "gitlab")
            }
            if provider == .github { defaults.removeObject(forKey: "githubToken") }
            if provider == legacyProvider, provider == .github || account == legacyGitLabAccount {
                defaults.removeObject(forKey: "accessToken")
            }
            guard generation == credentialGeneration, account == credentialAccount else { return }
            accessToken = ""
            notifications = []
            subjectDetailsByThreadId = [:]
            viewerUserId = nil
            lastPull = nil
            accountNeedsVerification = false
            credentialError = ""
            errorMessage = "Add an access token in Account settings to get started."
        } catch {
            guard generation == credentialGeneration, account == credentialAccount else { return }
            credentialError = error.localizedDescription
            errorMessage = credentialError
        }
    }

    func testAccessToken() async -> (Bool, String) {
        guard !isLoadingCredentials else { return (false, "Wait for saved credentials to finish loading.") }
        if (retryBlockedUntil?.timeIntervalSinceNow ?? 0) > 0 { return (false, "Wait for the provider’s retry interval before verifying again.") }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return (false, "Enter a token before verifying it.") }
        guard let account = credentialAccount else { return (false, "Enter a valid HTTPS GitLab host.") }
        let generation = credentialGeneration
        let result = await fetchNotificationThreads(accessToken: token, provider: provider,
            gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL), page: 1, perPage: 1,
            includeRead: false, session: apiSession)
        guard generation == credentialGeneration, account == credentialAccount,
              token == accessToken.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (false, "The account changed. Verify the current token again.")
        }
        honorProviderDelay(result.minimumPollDelay, failed: !result.isSuccess)
        guard result.isSuccess else { return (false, result.errorMessage) }
        do {
            try await credentials.set(token, for: account)
            guard generation == credentialGeneration, account == credentialAccount,
                  token == accessToken.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return (false, "The account changed. Verify the current token again.")
            }
            activeToken = token
            accessToken = token
            accountNeedsVerification = false
            credentialError = ""
            renewPullTask(interval: interval)
            return (true, "Token verified and saved securely.")
        } catch {
            guard generation == credentialGeneration, account == credentialAccount else { return (false, "The account changed.") }
            credentialError = error.localizedDescription
            return (false, credentialError)
        }
    }
}
