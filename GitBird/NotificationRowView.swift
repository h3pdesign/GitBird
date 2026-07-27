import AppKit
import SwiftUI

struct NotificationRowView: View {
    let thread: GitHubNotificationThread
    let details: GitHubSubjectDetails?
    let onOpen: (GitHubNotificationThread, URL) -> Void
    let onMarkAsRead: (GitHubNotificationThread) -> Void

    @State private var isHovering = false

    var body: some View {
        let url = details?.htmlUrl ?? thread.subject.preferredWebURL()

        Button {
            guard let url else { return }
            onOpen(thread, url)
        } label: {
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
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }

                    Text(thread.repository.fullName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    if isHovering {
                        Button {
                            onMarkAsRead(thread)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 13))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mark as read")
                        .help("Mark as read")
                        .frame(width: 24, height: 24)
                        .padding(.trailing, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(thread.subject.title)
                    .font(.body)
                    .fontWeight(thread.unread ? .semibold : .regular)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let reasonBadge {
                    Label(reasonBadge.title, systemImage: reasonBadge.symbolName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(reasonBadge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(reasonBadge.color.opacity(0.16), in: Capsule())
                }

                if !participants.isEmpty {
                    AvatarStackView(users: participants)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.08))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .focusable()
        .onDeleteCommand {
            guard thread.unread else { return }
            onMarkAsRead(thread)
        }
        .help("Open notification. Press Delete to mark as read.")
        .background(HoverTrackingView(isHovering: $isHovering))
        .animation(.easeOut(duration: 0.12), value: isHovering)
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

    var body: some View {
        HStack(spacing: -6) {
            ForEach(users.prefix(5)) { user in
                AvatarImageView(url: user.avatarUrl)
            }
        }
    }
}

private struct AvatarImageView: View {
    let url: URL
    @StateObject private var loader: AvatarImageLoader

    init(url: URL) {
        self.url = url
        _loader = StateObject(wrappedValue: AvatarImageLoader(url: url))
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

private struct HoverTrackingView: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onHoverChanged = { hovering in
            scheduleHoverStateUpdate(hovering)
        }
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onHoverChanged = { hovering in
            scheduleHoverStateUpdate(hovering)
        }
        nsView.updateHoverState()
    }

    private func scheduleHoverStateUpdate(_ hovering: Bool) {
        Task { @MainActor in
            await Task.yield()
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
    }

    final class TrackingNSView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }

            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area

            updateHoverState()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor in
                await Task.yield()
                updateHoverState()
            }
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            onHoverChanged?(false)
        }

        func updateHoverState() {
            guard let window else { return }

            let mouseOnScreen = NSEvent.mouseLocation
            let mouseInWindow = window.convertPoint(fromScreen: mouseOnScreen)
            let mouseInView = convert(mouseInWindow, from: nil)
            onHoverChanged?(bounds.contains(mouseInView))
        }
    }
}

@MainActor
private final class AvatarImageLoader: ObservableObject {
    @Published var image: NSImage?
    private let url: URL
    private var task: Task<Data?, Never>?

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

    init(url: URL) {
        self.url = url
    }

    deinit {
        task?.cancel()
    }

    func load() async {
        if image != nil { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        if task != nil { return }
        let url = self.url
        task = Task.detached(priority: .utility) {
            do {
                let (data, response) = try await Self.session.data(from: url)
                guard !Task.isCancelled else { return nil }
                guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else { return nil }
                return data
            } catch {
                return nil
            }
        }

        let data = await task?.value
        task = nil
        guard let data, let img = NSImage(data: data) else { return }
        Self.cache.setObject(img, forKey: url as NSURL)
        image = img
    }
}
