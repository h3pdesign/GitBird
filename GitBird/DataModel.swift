//
//  DataModel.swift
//  GitBird
//
//  Created by rook1e on 2023/10/6.
//

import Foundation


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
    provider: NotificationProvider? = nil,
    gitlabBaseURL: URL? = nil,
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
        case .httpError(let statusCode, let body):
            let preview = body.prefix(512)
            AppLog.warning("GitHub API HTTP \(statusCode), body: \(preview)")
            return ([], false, false, "bad request: \(statusCode), \(preview)")
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

struct GitHubAPIClient {
    enum APIError: Error {
        case invalidResponse
        case httpError(statusCode: Int, body: String)
    }

    let token: String
    let provider: NotificationProvider
    let baseURL: URL

    init(token: String, provider: NotificationProvider? = nil, gitlabBaseURL: URL? = nil) {
        self.token = token
        let storedProvider = NotificationProvider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .github
        let selectedProvider = provider ?? storedProvider
        self.provider = selectedProvider
        self.baseURL = selectedProvider == .gitlab ? (gitlabBaseURL ?? selectedProvider.defaultBaseURL) : selectedProvider.defaultBaseURL
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
        let started = Date()
#if DEBUG
        AppLog.debug("HTTP GET \(url.absoluteString)")
#endif
        let (data, response) = try await Self.session.data(for: makeRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            AppLog.warning("HTTP invalid response for \(url.absoluteString)")
            throw APIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
#if DEBUG
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let preview = body.prefix(1024)
            AppLog.debug("HTTP \(http.statusCode) \(url.absoluteString) (\(ms)ms), body: \(preview)")
#endif
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }

#if DEBUG
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.debug("HTTP 2xx \(url.absoluteString) (\(ms)ms)")
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
        try await fetch(URL(string: "https://api.github.com/user")!)
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
            URLQueryItem(name: "all", value: "true"),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "per_page", value: String(min(max(perPage, 1), 50)))
        ]
        let url = components.url!

        let started = Date()
 #if DEBUG
        AppLog.debug("HTTP GET \(url.absoluteString)")
 #endif
        let (data, response) = try await Self.session.data(for: makeRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            AppLog.warning("HTTP invalid response for \(url.absoluteString)")
            throw APIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
 #if DEBUG
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let preview = body.prefix(1024)
            AppLog.debug("HTTP \(http.statusCode) \(url.absoluteString) (\(ms)ms), body: \(preview)")
 #endif
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }

 #if DEBUG
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.debug("HTTP 2xx \(url.absoluteString) (\(ms)ms)")
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
        let visibleThreads = includeRead ? threads : threads.filter { $0.unread || $0.lastReadAt == nil }
        AppLog.debug("Notification visibility: fetched=\(threads.count), visible=\(visibleThreads.count), includeRead=\(includeRead)")
        let hasNext = linkHeaderHasNextPage(http.value(forHTTPHeaderField: "Link"))
        return (visibleThreads, hasNext)
    }

    func markThreadAsRead(url: URL) async throws {
        var request = makeRequest(url: url)
        if provider == .gitlab {
            request = makeRequest(url: url.appendingPathComponent("mark_as_done"))
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
        var request = makeRequest(url: url)
        if provider == .gitlab {
            request = makeRequest(url: url.appendingPathComponent("mark_as_done"))
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
            var request = makeRequest(url: baseURL.appendingPathComponent("api/v4/todos/mark_as_done"))
            request.httpMethod = "POST"
            let (_, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw APIError.invalidResponse }
            return
        }

        for url in urls {
            try await markThreadAsDone(url: url)
        }
    }

    func markAllNotificationsAsRead(lastReadAt: Date?, urls: [URL] = []) async throws {
        if provider == .gitlab {
            var request = makeRequest(url: baseURL.appendingPathComponent("api/v4/todos/mark_as_done"))
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

        var request = makeRequest(url: baseURL.appendingPathComponent("notifications"))
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
            AppLog.debug("Subject details fetch failed: \(subjectURL.absoluteString)")
#endif
            return nil
        }
    }
}

@MainActor class RuntimeData: ObservableObject {
    static let shared = RuntimeData()
    @Published var message: String = ""
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
    @Published var lastPull: Date?

    private var nextNotificationsPage: Int? = nil
    
    @Published var accessToken: String {
        willSet(newValue) {
            UserDefaults.standard.set(newValue, forKey: "accessToken")
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
        self.accessToken = defaults.string(forKey: "accessToken") ?? defaults.string(forKey: "githubToken") ?? ""

        if self.interval < 30 { self.interval = 300 }
        if self.interval > 3600 { self.interval = 3600 }
        if self.listLength < 1 { self.listLength = 10 }
        if self.listLength > 50 { self.listLength = 50 }

        resetPaginationState()
    }

    private var notificationsPerPage: Int {
        min(max(listLength, 1), 50)
    }

    private func resetPaginationState() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        nextNotificationsPage = nil
        hasMoreNotifications = false
        isLoadingMoreNotifications = false
        loadMoreError = ""
    }
    
    func start() {
        AppLog.info("RuntimeData start")
        renewPullTask(interval: interval)
    }
    
    func refreshNotifications() {
        guard !accessToken.isEmpty else {
            message = "Set an access token in Account settings!"
            return
        }

        pullTask?.cancel()
        detailsTask?.cancel()
        loadMoreTask?.cancel()
        pullTask = nil
        detailsTask = nil
        loadMoreTask = nil
        resetPaginationState()

        let token = accessToken
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage
        isRefreshing = true
        message = ""

        pullTask = Task.detached(priority: .userInitiated) { [weak self, token, perPage, includeRead] in
            let (firstPage, ok, hasNext, err) = await fetchNotificationThreads(
                accessToken: token,
                page: 1,
                perPage: perPage,
                includeRead: includeRead
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                if ok {
                    self.notifications = firstPage
                    self.lastPull = Date()
                }
                self.message = err
                self.nextNotificationsPage = ok && hasNext ? 2 : nil
                self.hasMoreNotifications = ok && hasNext
                self.isLoadingMoreNotifications = false
                self.loadMoreError = ""
                self.isRefreshing = false

                let ids = Set(self.notifications.map(\.id))
                self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { details in ids.contains(details.key) }
                if ok {
                    self.prefetchSubjectDetails(for: firstPage)
                }
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
        
        if interval < 1 {
            self.message = "Interval is too short"
            AppLog.warning("Interval too short: \(interval)")
            return
        }
        
        if accessToken.isEmpty {
            self.message = "Set an access token in Account settings!"
            AppLog.warning("Access token missing")
            return
        }
        
        let token = self.accessToken
        let includeRead = !hideReadNotifications
        let perPage = notificationsPerPage

        ensureViewerUserId()
        pullTask = Task.detached(priority: .utility) { [weak self, token, perPage, includeRead] in
            guard let self else { return }
            var failsCount = 0
            repeat {
                AppLog.debug("Pull notifications (fails=\(failsCount))")
                let (firstPage, ok, hasNext, err) = await fetchNotificationThreads(
                    accessToken: token,
                    page: 1,
                    perPage: perPage,
                    includeRead: includeRead
                )

                if !ok {
                    AppLog.warning("Pull notifications failed: \(err)")
                }

                await MainActor.run {
                    self.notifications = firstPage
                    self.message = err
                    if ok {
                        self.lastPull = Date()
                    }

                    self.nextNotificationsPage = hasNext ? 2 : nil
                    self.hasMoreNotifications = self.nextNotificationsPage != nil
                    self.isLoadingMoreNotifications = false
                    self.loadMoreError = ""

                    let ids = Set(firstPage.map { $0.id })
                    self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { ids.contains($0.key) }
                }
                
                if ok {
                    failsCount = 0
                } else {
                    failsCount += 1
                }

                if Task.isCancelled || failsCount >= 3 {
                    AppLog.debug("Stopping pull task (cancelled=\(Task.isCancelled), fails=\(failsCount))")
                    return
                }
                
                try? await Task.sleep(for: .seconds(interval))
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

        isLoadingMoreNotifications = true
        loadMoreError = ""

        loadMoreTask = Task.detached(priority: .utility) { [token, perPage, page, includeRead] in
            let (threads, ok, hasNext, err) = await fetchNotificationThreads(
                accessToken: token,
                page: page,
                perPage: perPage,
                includeRead: includeRead
            )

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.loadMoreTask = nil }

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
        let targets = threads.compactMap { thread -> (String, URL)? in
            guard subjectDetailsByThreadId[thread.id] == nil else { return nil }
            guard let url = thread.subject.url else { return nil }
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
            let api = GitHubAPIClient(token: token)

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

    func markNotificationAsRead(threadId: String) {
        guard let thread = notifications.first(where: { $0.id == threadId }) else { return }
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: URL(string: gitlabBaseURL))
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await api.markThreadAsRead(url: thread.url)
                await MainActor.run {
                    self?.notifications.removeAll { $0.id == threadId }
                    self?.subjectDetailsByThreadId.removeValue(forKey: threadId)
                    self?.refreshNotifications()
                }
            } catch {
                AppLog.warning("Failed to mark notification as read: \(error)")
                await MainActor.run {
                    self?.message = "Failed to mark as read"
                }
            }
        }
    }

    func markNotificationAsDone(threadId: String) {
        guard let thread = notifications.first(where: { candidate in candidate.id == threadId }) else { return }
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: URL(string: gitlabBaseURL))
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await api.markThreadAsDone(url: thread.url)
                await MainActor.run {
                    self?.notifications.removeAll { candidate in candidate.id == threadId }
                    self?.subjectDetailsByThreadId.removeValue(forKey: threadId)
                    self?.refreshNotifications()
                }
            } catch {
                AppLog.warning("Failed to mark notification as done: \(error)")
                await MainActor.run {
                    self?.message = "Failed to mark as done"
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
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: URL(string: gitlabBaseURL))
        isMarkingAllNotificationsAsDone = true

        Task.detached(priority: .utility) { [weak self, targetIDs, targetURLs] in
            do {
                try await api.markAllNotificationsAsDone(urls: targetURLs)
                await MainActor.run {
                    guard let self else { return }
                    self.isMarkingAllNotificationsAsDone = false
                    self.notifications.removeAll { targetIDs.contains($0.id) }
                    self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { !targetIDs.contains($0.key) }
                    self.refreshNotifications()
                }
            } catch {
                AppLog.warning("Failed to mark all notifications as done")
                await MainActor.run {
                    self?.isMarkingAllNotificationsAsDone = false
                    self?.message = "Failed to mark all as done"
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
        let api = GitHubAPIClient(token: accessToken, provider: provider, gitlabBaseURL: URL(string: gitlabBaseURL))
        let lastReadAt = lastPull
        isMarkingAllNotificationsAsRead = true

        Task.detached(priority: .utility) { [weak self, targetURLs] in
            do {
                try await api.markAllNotificationsAsRead(lastReadAt: lastReadAt, urls: targetURLs)
                await MainActor.run {
                    guard let self else { return }
                    self.notifications.removeAll { targetIDs.contains($0.id) }
                    self.subjectDetailsByThreadId = self.subjectDetailsByThreadId.filter { !targetIDs.contains($0.key) }
                    self.nextNotificationsPage = nil
                    self.hasMoreNotifications = false
                    self.isMarkingAllNotificationsAsRead = false
                    self.refreshNotifications()
                }
            } catch {
                AppLog.warning("Failed to mark all notifications as read: \(error)")
                await MainActor.run {
                    self?.isMarkingAllNotificationsAsRead = false
                    self?.message = "Failed to mark all as read"
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
        guard viewerUserId == nil else { return }
        guard viewerFetchTask == nil else { return }

        let token = accessToken
        guard !token.isEmpty else { return }

        let task = Task.detached(priority: .utility) { [token] () async -> Int64? in
            do {
                let api = GitHubAPIClient(token: token)
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
            page: 1,
            perPage: 1,
            includeRead: !hideReadNotifications
        )
        return (ok, err)
    }
}
