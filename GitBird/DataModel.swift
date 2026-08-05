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

private enum TokenStore {
    private static let service = Bundle.main.bundleIdentifier ?? "GitBird"

    static func token(for provider: NotificationProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    static func set(_ token: String, for provider: NotificationProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        if token.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

private func validatedGitLabBaseURL(_ value: String) -> URL? {
    guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme?.lowercased() == "https",
          let host = components.host,
          !host.isEmpty,
          components.path.isEmpty || components.path == "/",
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil else { return nil }
    components.scheme = "https"
    components.path = ""
    return components.url
}

// GitHub REST API: GET /notifications
// https://docs.github.com/en/rest/activity/notifications#list-notifications-for-the-authenticated-user

struct GitHubUser: Identifiable, Codable, Hashable {
    let id: Int64
    let login: String
    let avatarUrl: URL
}

struct GitHubRepository: Codable {
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

struct GitHubNotificationThread: Identifiable, Codable {
    let id: String

    let repository: GitHubRepository

    let subject: Subject
    struct Subject: Codable {
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

struct GitHubSubjectDetails: Equatable {
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
    includeRead: Bool = false
) async -> ([GitHubNotificationThread], Bool, Bool, String) {
    AppLog.debug("Fetching notification threads")
    do {
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: gitlabBaseURL)
        let (notifications, hasNext) = try await api.fetchNotifications(page: page, perPage: perPage, includeRead: includeRead)
        AppLog.debug("Fetched \(notifications.count) notification threads")
        return (notifications, true, hasNext, "")
    } catch let e as GitHubAPIClient.APIError {
        switch e {
        case .invalidResponse:
            AppLog.warning("GitHub API invalid response")
            return ([], false, false, "invalid response")
        case .httpError(let statusCode, _):
            AppLog.warning("Notification API HTTP \(statusCode)")
            return ([], false, false, "Request failed (HTTP \(statusCode))")
        }
    } catch {
        AppLog.warning("GitHub API request failed (network/firewall?)")
        return ([], false, false, "cannot request, please check network or firewall")
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
    enum APIError: Error {
        case invalidResponse
        case httpError(statusCode: Int, body: String)
    }

    let token: String
    let provider: NotificationProvider
    let baseURL: URL

    init(token: String, provider: NotificationProvider, gitlabBaseURL: URL?) {
        self.token = token
        self.provider = provider
        self.baseURL = provider == .gitlab ? (gitlabBaseURL ?? provider.defaultBaseURL) : provider.defaultBaseURL
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
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
        let (data, response) = try await Self.session.data(for: makeRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            AppLog.warning("HTTP invalid response")
            throw APIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
#if DEBUG
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.debug("HTTP \(http.statusCode) response (\(ms)ms)")
#endif
            throw APIError.httpError(statusCode: http.statusCode, body: body)
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

    private func isAllowedAuthenticatedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        switch provider {
        case .github:
            return host == "api.github.com"
        case .gitlab:
            return host == baseURL.host?.lowercased()
        }
    }

    private func linkHeaderHasNextPage(_ linkHeader: String?) -> Bool {
        guard let linkHeader, !linkHeader.isEmpty else { return false }
        // Format: <url>; rel="next", <url>; rel="last"
        return linkHeader.split(separator: ",").contains { part in
            part.contains("rel=\"next\"")
        }
    }

    func fetchNotifications(page: Int, perPage: Int, includeRead: Bool = false) async throws -> ([GitHubNotificationThread], Bool) {
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
        let (data, response) = try await Self.session.data(for: makeRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            AppLog.warning("HTTP invalid response")
            throw APIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
 #if DEBUG
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.debug("HTTP \(http.statusCode) response (\(ms)ms)")
 #endif
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }

 #if DEBUG
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.debug("HTTP 2xx response (\(ms)ms)")
 #endif

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
            let (doneData, doneResponse) = try await Self.session.data(for: makeRequest(url: doneURL))
            guard let doneHTTP = doneResponse as? HTTPURLResponse, (200...299).contains(doneHTTP.statusCode) else {
                throw APIError.invalidResponse
            }
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
        let hasNext = linkHeaderHasNextPage(http.value(forHTTPHeaderField: "Link"))
        return (visibleThreads, hasNext)
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
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw APIError.httpError(statusCode: http.statusCode, body: body)
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
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    func markAllNotificationsAsDone(urls: [URL]) async throws {
        if provider == .gitlab {
            let actionURL = baseURL.appendingPathComponent("api/v4/todos/mark_as_done")
            guard isAllowedAuthenticatedURL(actionURL) else { throw APIError.invalidResponse }
            var request = makeRequest(url: actionURL)
            request.httpMethod = "POST"
            let (_, response) = try await Self.session.data(for: request)
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
            let (_, response) = try await Self.session.data(for: request)
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

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw APIError.httpError(statusCode: http.statusCode, body: body)
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
            UserDefaults.standard.set(newValue, forKey: "listLength")
        }
        didSet(oldValue) {
            if listLength == oldValue { return }
            resetPaginationState()
            renewPullTask(interval: interval)
        }
    }

    @Published var provider: NotificationProvider {
        willSet { UserDefaults.standard.set(newValue.rawValue, forKey: "provider") }
        didSet {
            guard provider != oldValue else { return }
            accessToken = TokenStore.token(for: provider) ?? ""
            resetPaginationState()
            renewPullTask(interval: interval)
        }
    }

    @Published var gitlabBaseURL: String {
        willSet { UserDefaults.standard.set(newValue, forKey: "gitlabBaseURL") }
        didSet {
            guard gitlabBaseURL != oldValue else { return }
            renewPullTask(interval: interval)
        }
    }

    @Published var hideReadNotifications: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: "hideReadNotifications")
        }
        didSet {
            if hideReadNotifications == oldValue { return }
            resetPaginationState()
            renewPullTask(interval: interval)
        }
    }

    @Published var interval: Int  = 300 {
        willSet(newValue) {
            UserDefaults.standard.set(newValue, forKey: "interval")
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
    private var tokenDebounceTask: Task<Void, Never>?
    private var viewerFetchTask: Task<Int64?, Never>?
    private var requestGeneration = 0
    @Published var lastPull: Date?

    private var nextNotificationsPage: Int? = nil
    
    @Published var accessToken: String {
        willSet(newValue) {
            TokenStore.set(newValue, for: provider)
        }
        didSet {
            viewerFetchTask?.cancel()
            viewerFetchTask = nil
            viewerUserId = nil

            tokenDebounceTask?.cancel()
            let interval = self.interval
            tokenDebounceTask = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.renewPullTask(interval: interval)
            }
        }
    }
    
    init() {
        let defaults = UserDefaults.standard
        self.interval = (defaults.object(forKey: "interval") as? Int) ?? 300
        self.listLength = (defaults.object(forKey: "listLength") as? Int) ?? 10
        self.hideReadNotifications = defaults.object(forKey: "hideReadNotifications") as? Bool ?? true
        self.provider = NotificationProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .github
        self.gitlabBaseURL = defaults.string(forKey: "gitlabBaseURL") ?? "https://gitlab.com"
        let legacyToken = defaults.string(forKey: "accessToken") ?? defaults.string(forKey: "githubToken")
        let storedToken = TokenStore.token(for: self.provider)
        if storedToken == nil, let legacyToken {
            TokenStore.set(legacyToken, for: self.provider)
        }
        self.accessToken = storedToken ?? legacyToken ?? ""
        defaults.removeObject(forKey: "accessToken")
        defaults.removeObject(forKey: "githubToken")

        if self.interval < 30 { self.interval = 300 }
        if self.interval > 3600 { self.interval = 3600 }
        if self.listLength < 1 { self.listLength = 10 }
        if self.listLength > 50 { self.listLength = 50 }

        resetPaginationState()
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
    
    func start() {
        AppLog.info("RuntimeData start")
        renewPullTask(interval: interval)
    }
    
    func refreshNotifications() {
        guard !accessToken.isEmpty else {
            errorMessage = "Set an access token in Account settings!"
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

        let token = accessToken
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
            let (firstPage, ok, hasNext, err) = await fetchNotificationThreads(
                accessToken: token,
                provider: provider,
                gitlabBaseURL: gitlabBaseURL,
                page: 1,
                perPage: perPage,
                includeRead: includeRead
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.requestGeneration == generation else { return }
                if ok {
                    self.notifications = firstPage
                    self.lastPull = Date()
                }
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
                self.renewPullTask(interval: self.interval)
            }
        }
    }

    func renewPullTask(interval: Int) {
        AppLog.info("Renew pull task (interval=\(interval)s)")
        pullTask?.cancel()
        detailsTask?.cancel()
        loadMoreTask?.cancel()
        pullTask = nil
        detailsTask = nil
        loadMoreTask = nil
        isMarkingAllNotificationsAsRead = false
        isMarkingAllNotificationsAsDone = false
        let generation = advanceRequestGeneration()
        
        if interval < 1 {
            self.errorMessage = "Interval is too short"
            AppLog.warning("Interval too short: \(interval)")
            return
        }
        
        if accessToken.isEmpty {
            self.errorMessage = "Set an access token in Account settings!"
            AppLog.warning("Access token missing")
            return
        }
        
        let token = self.accessToken
        let provider = self.provider
        let gitlabBaseURL = validatedGitLabBaseURL(self.gitlabBaseURL)
        guard provider == .github || gitlabBaseURL != nil else {
            self.errorMessage = "Enter a valid HTTPS GitLab host."
            return
        }
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage

        ensureViewerUserId()
        pullTask = Task.detached(priority: .utility) { [weak self, token, perPage, includeRead, provider, gitlabBaseURL, generation] in
            guard let self else { return }
            var failsCount = 0
            repeat {
                AppLog.debug("Pull notifications (fails=\(failsCount))")
                let (firstPage, ok, hasNext, err) = await fetchNotificationThreads(
                    accessToken: token,
                    provider: provider,
                    gitlabBaseURL: gitlabBaseURL,
                    page: 1,
                    perPage: perPage,
                    includeRead: includeRead
                )

                if !ok {
                    AppLog.warning("Pull notifications failed: \(err)")
                }

                await MainActor.run {
                    guard self.requestGeneration == generation else { return }
                    self.errorMessage = ok ? "" : err
                    if ok {
                        self.notifications = firstPage
                        self.lastPull = Date()
                        self.nextNotificationsPage = hasNext ? 2 : nil
                        self.hasMoreNotifications = self.nextNotificationsPage != nil
                        self.isLoadingMoreNotifications = false
                        self.loadMoreError = ""

                        let ids = Set(firstPage.map { $0.id })
                        self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { ids.contains($0.key) }
                    }
                }
                
                if ok {
                    failsCount = 0
                } else {
                    failsCount += 1
                }

                if Task.isCancelled {
                    AppLog.debug("Stopping pull task (cancelled=true)")
                    return
                }

                let baseDelay = max(interval, 30)
                let retryMultiplier = 1 << min(failsCount, 4)
                let delay = min(baseDelay * retryMultiplier, 900)
                try? await Task.sleep(for: .seconds(delay))
            } while(!Task.isCancelled)
        }
    }

    func loadMoreNotifications() {
        guard !isLoadingMoreNotifications else { return }
        guard loadMoreTask == nil else { return }
        guard let page = nextNotificationsPage else { return }

        let token = accessToken
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage
        let provider = provider
        let gitlabBaseURL = validatedGitLabBaseURL(gitlabBaseURL)
        let generation = requestGeneration

        isLoadingMoreNotifications = true
        loadMoreError = ""

        loadMoreTask = Task.detached(priority: .utility) { [token, perPage, page, includeRead, provider, gitlabBaseURL, generation] in
            let (threads, ok, hasNext, err) = await fetchNotificationThreads(
                accessToken: token,
                provider: provider,
                gitlabBaseURL: gitlabBaseURL,
                page: page,
                perPage: perPage,
                includeRead: includeRead
            )

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.loadMoreTask = nil }

                guard self.requestGeneration == generation else { return }

                // Ignore stale results when pagination state changed.
                guard self.nextNotificationsPage == page else {
                    self.isLoadingMoreNotifications = false
                    return
                }

                self.isLoadingMoreNotifications = false

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

        let token = self.accessToken
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

        self.detailsTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let api = GitHubAPIClient(token: token, provider: provider, gitlabBaseURL: gitlabBaseURL)

            let maxInFlight = 4
            await withTaskGroup(of: (String, GitHubSubjectDetails?).self) { group in
                var it = targets.makeIterator()

                for _ in 0..<maxInFlight {
                    guard let (id, url) = it.next() else { break }
                    group.addTask {
                        let details = await api.fetchSubjectDetails(subjectURL: url)
                        return (id, details)
                    }
                }

                while let (id, details) = await group.next() {
                    if let details {
                        await MainActor.run {
                            guard self.requestGeneration == generation else { return }
                            self.subjectDetailsByThreadId[id] = details
                        }
                    }

                    if let (nextId, nextURL) = it.next() {
                        group.addTask {
                            let details = await api.fetchSubjectDetails(subjectURL: nextURL)
                            return (nextId, details)
                        }
                    }
                }
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
        let generation = requestGeneration
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL))
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await api.markThreadAsRead(url: thread.url)
                await MainActor.run {
                    guard let self else { return }
                    guard self.requestGeneration == generation else { return }
                    self.markThreadsAsReadLocally(Set([threadId]))
                    if self.hideReadNotifications {
                        self.notifications.removeAll { $0.id == threadId }
                    }
                    self.subjectDetailsByThreadId.removeValue(forKey: threadId)
                    self.errorMessage = ""
                    self.statusMessage = self.provider == .gitlab ? "Completed Todo" : "Marked as read"
                }
            } catch {
                AppLog.warning("Failed to mark notification as read: \(error)")
                await MainActor.run {
                    self?.errorMessage = "Failed to mark as read"
                }
            }
        }
    }

    func markNotificationAsDone(threadId: String) {
        guard let thread = notifications.first(where: { candidate in candidate.id == threadId }) else { return }
        let generation = requestGeneration
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL))
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await api.markThreadAsDone(url: thread.url)
                await MainActor.run {
                    guard let self, self.requestGeneration == generation else { return }
                    self.notifications.removeAll { candidate in candidate.id == threadId }
                    self.subjectDetailsByThreadId.removeValue(forKey: threadId)
                    self.errorMessage = ""
                    self.statusMessage = "Marked as done"
                }
            } catch {
                AppLog.warning("Failed to mark notification as done: \(error)")
                await MainActor.run {
                    self?.errorMessage = "Failed to mark as done"
                }
            }
        }
    }

    func markAllNotificationsAsDone() {
        guard !notifications.isEmpty else { return }
        guard !isMarkingAllNotificationsAsDone else { return }
        guard !accessToken.isEmpty else { return }

        let targetIDs = Set(notifications.map(\.id))
        let targetURLs = notifications.map(\.url)
        let generation = requestGeneration
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL))
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
                    self?.isMarkingAllNotificationsAsDone = false
                    self?.errorMessage = "Failed to mark all as done"
                }
            }
        }
    }

    func markAllNotificationsAsRead() {
        guard !notifications.isEmpty else { return }
        guard !isMarkingAllNotificationsAsRead else { return }
        guard !accessToken.isEmpty else { return }

        let targetIDs = Set(notifications.map(\.id))
        let targetURLs = notifications.map(\.url)
        let generation = requestGeneration
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL))
        let lastReadAt = lastPull
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
                AppLog.warning("Failed to mark all notifications as read: \(error)")
                await MainActor.run {
                    self?.isMarkingAllNotificationsAsRead = false
                    self?.errorMessage = "Failed to mark all as read"
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

        let token = accessToken
        guard !token.isEmpty else { return }

        let task = Task.detached(priority: .utility) { [token] () async -> Int64? in
            do {
                let api = GitHubAPIClient(token: token, provider: .github, gitlabBaseURL: nil)
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
            guard self.accessToken == token else { return }
            if let id {
                self.viewerUserId = id
            }
            self.viewerFetchTask = nil
        }
    }
    
    func testAccessToken() async -> (Bool, String) {
        let token = self.accessToken
        let (_, ok, _, err) = await fetchNotificationThreads(
            accessToken: token,
            provider: provider,
            gitlabBaseURL: validatedGitLabBaseURL(gitlabBaseURL),
            page: 1,
            perPage: 1,
            includeRead: !hideReadNotifications
        )
        return (ok, err)
    }
}
