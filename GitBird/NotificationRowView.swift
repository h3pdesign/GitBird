import AppKit
import ImageIO
import SwiftUI

struct NotificationRowView: View {
    let thread: GitHubNotificationThread
    let details: GitHubSubjectDetails?
    let onOpen: (GitHubNotificationThread, URL) -> Void
    let onMarkAsDone: (GitHubNotificationThread) -> Void
    let onMarkAsRead: (GitHubNotificationThread) -> Void
    let provider: NotificationProvider
    var isPerformingAction = false
    var actionsDisabled = false
    let allowedAvatarHosts: Set<String>

    @State private var isHovering = false

    var body: some View {
        let url = details?.htmlUrl ?? thread.subject.preferredWebURL()

        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let url else { return }
                onOpen(thread, url)
            } label: {
                notificationContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .accessibilityLabel("\(thread.repository.fullName): \(thread.subject.title)")
            .accessibilityValue(Text([stateBadge.title, reasonBadge?.title].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(url == nil ? "Details unavailable" : "Opens notification in your browser")
            .onKeyPress(.return) {
                guard let url else { return .ignored }
                onOpen(thread, url)
                return .handled
            }

            HStack(spacing: 12) {
                if isPerformingAction {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Updating notification")
                }
                if thread.unread {
                    Button {
                        onMarkAsRead(thread)
                    } label: {
                        Label(readActionTitle, systemImage: "checkmark.circle")
                    }
                    .help(readActionTitle)
                }
                if provider == .github {
                    Button {
                        onMarkAsDone(thread)
                    } label: {
                        Label("Mark as done", systemImage: "archivebox")
                    }
                    .help("Mark as done (Delete)")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isPerformingAction || actionsDisabled)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .onDeleteCommand {
            guard !isPerformingAction, !actionsDisabled else { return }
            onMarkAsDone(thread)
        }
        .onHover { isHovering = $0 }
    }

    private var readActionTitle: String {
        provider == .gitlab ? "Complete Todo" : "Mark as read"
    }

    private var notificationContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    Image(systemName: subjectTypeIconName(thread.subject.type))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 18)
                        .foregroundStyle(subjectTypeColor)
                }

                if thread.unread {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 7, height: 7)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.7), lineWidth: 1)
                        }
                        .shadow(color: .blue.opacity(0.45), radius: 3)
                }

                Text(thread.repository.fullName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(thread.repository.fullName)

                Spacer(minLength: 8)

                Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(thread.subject.title)
                .font(.body)
                .fontWeight(thread.unread ? .semibold : .regular)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                statusBadgeView
                if let reasonBadge {
                    Label(reasonBadge.title, systemImage: reasonBadge.symbolName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(reasonBadge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(reasonBadge.color.opacity(0.16), in: Capsule())
                }
            }

            if !participants.isEmpty {
                AvatarStackView(users: participants, allowedHosts: allowedAvatarHosts)
            }
        }
    }

    private var participants: [GitHubUser] {
        if let details, !details.participants.isEmpty {
            return Array(details.participants.prefix(5))
        }
        if let owner = thread.repository.owner {
            return [owner]
        }
        return []
    }

    private func subjectTypeIconName(_ type: String) -> String {
        switch type {
        case "PullRequest":
            return "arrow.triangle.branch"
        case "Issue":
            return "exclamationmark.circle"
        case "Commit":
            return "chevron.left.slash.chevron.right"
        case "Release":
            return "tag"
        case "Discussion":
            return "text.bubble"
        case "CheckSuite":
            return "checkmark.seal"
        case "RepositoryInvitation":
            return "person.crop.circle.badge.plus"
        default:
            return "bell"
        }
    }

    private var subjectTypeColor: Color {
        guard thread.unread else { return .secondary }

        switch thread.subject.type {
        case "PullRequest":
            return .purple
        case "Issue":
            return .orange
        case "Commit":
            return .blue
        case "Release":
            return .pink
        case "Discussion":
            return .indigo
        case "CheckSuite":
            return .green
        case "RepositoryInvitation":
            return .cyan
        default:
            return .primary
        }
    }

    private var statusBadgeView: some View {
        Label(stateBadge.title, systemImage: stateBadge.symbolName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(stateBadge.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(stateBadge.color.opacity(0.14), in: Capsule())
    }

    private var stateBadge: StatusBadge {
        if thread.unread {
            return StatusBadge(title: provider == .gitlab ? "Pending" : "Unread", symbolName: "circle.fill", color: .blue)
        }
        return StatusBadge(title: provider == .gitlab ? "Completed" : "Read", symbolName: "checkmark.circle.fill", color: .secondary)
    }

    private struct StatusBadge {
        let title: String
        let symbolName: String
        let color: Color
    }

    private var reasonBadge: ReasonBadge? {
        switch thread.reason {
        case "review_requested":
            return ReasonBadge(title: "Review requested", symbolName: "eye", color: .purple)
        case "mention", "team_mention":
            return ReasonBadge(title: "Mentioned", symbolName: "at", color: .blue)
        case "assign":
            return ReasonBadge(title: "Assigned", symbolName: "person.crop.circle.badge.checkmark", color: .orange)
        case "approval_requested":
            return ReasonBadge(title: "Approval requested", symbolName: "checkmark.seal", color: .indigo)
        case "security_alert":
            return ReasonBadge(title: "Security alert", symbolName: "exclamationmark.shield", color: .red)
        default:
            return nil
        }
    }

    private struct ReasonBadge {
        let title: String
        let symbolName: String
        let color: Color
    }
}

struct AvatarStackView: View {
    let users: [GitHubUser]
    let allowedHosts: Set<String>

    var body: some View {
        HStack(spacing: -6) {
            ForEach(users.prefix(5)) { user in
                AvatarImageView(url: user.avatarUrl, allowedHosts: allowedHosts)
            }
        }
    }
}

private struct AvatarImageView: View {
    let url: URL
    let allowedHosts: Set<String>
    @StateObject private var loader: AvatarImageLoader

    init(url: URL, allowedHosts: Set<String>) {
        self.url = url
        self.allowedHosts = allowedHosts
        _loader = StateObject(wrappedValue: AvatarImageLoader(url: url, allowedHosts: allowedHosts))
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
        )
        .task {
            await loader.load()
        }
    }
}

@MainActor
private final class AvatarImageLoader: ObservableObject {
    @Published var image: NSImage?
    private let url: URL
    private let allowedHosts: Set<String>
    private static var inFlight: [URL: Task<Data?, Never>] = [:]

    private static let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 128
        return c
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    init(url: URL, allowedHosts: Set<String>) {
        self.url = url
        self.allowedHosts = allowedHosts
    }


    func load() async {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
              url.user == nil,
              url.password == nil else { return }
        if image != nil { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        let url = self.url
        let data: Data?
        if let existing = Self.inFlight[url] {
            data = await existing.value
        } else {
            let requestTask: Task<Data?, Never> = Task.detached(priority: .utility) {
                do {
                    let (data, response) = try await Self.session.data(from: url)
                    guard !Task.isCancelled, data.count <= 2_000_000,
                          (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else { return nil }
                    return data
                } catch {
                    return nil
                }
            }
            Self.inFlight[url] = requestTask
            data = await requestTask.value
            Self.inFlight[url] = nil
        }
        guard let data else { return }
        let cgImage: CGImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 72
                ] as CFDictionary
            )
        }.value
        guard let cgImage else { return }
        let loadedImage = NSImage(cgImage: cgImage, size: NSSize(width: 36, height: 36))
        Self.cache.setObject(loadedImage, forKey: url as NSURL)
        image = loadedImage
    }
}
