//
//  ContentView.swift
//  GitBird
//
//  Created by rook1e on 2023/10/6.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var runtimeData: RuntimeData
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    @AppStorage("settingsSection") private var settingsSection = "general"
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var bulkAction: BulkActionContext?
    @State private var selectedFilter: NotificationFilter = .all
    @State private var selectedRepository = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let context = bulkAction {
                bulkConfirmation(context)
            } else {
                searchField
                filters
                if !runtimeData.statusMessage.isEmpty && runtimeData.errorMessage.isEmpty {
                    Text(runtimeData.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("actionFeedback")
                }
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MenuBarWindowSurface())
        .frame(width: 420)
        .onChange(of: runtimeData.credentialAccount) { _, _ in
            selectedFilter = .all
            selectedRepository = ""
        }
        .task(id: runtimeData.statusMessageRevision) {
            guard !runtimeData.statusMessage.isEmpty else { return }
            let revision = runtimeData.statusMessageRevision
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            runtimeData.clearStatusMessage(ifRevision: revision)
        }
    }

    // A separate system dialog takes focus away from the transient menu-bar
    // host. Keep the reviewed snapshot and its actions in the same popup.
    private func bulkConfirmation(_ context: BulkActionContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(context.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(context.message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .cancel) { bulkAction = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(context.provider == .gitlab ? "Complete all Todos" : "Confirm", role: .destructive) {
                    bulkAction = nil
                    runtimeData.performBulkAction(context)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 8)
    }

    private struct NotificationGroup: Identifiable {
        let id: String
        let title: String
        let threads: [GitHubNotificationThread]
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search loaded notifications", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search loaded notifications")
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
            Button { searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("f")
                .accessibilityHidden(true)
        }
    }

    private var notificationGroups: [NotificationGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let groups = Dictionary(grouping: filteredNotifications) { thread in
            if calendar.isDateInToday(thread.updatedAt) {
                return "today"
            }
            if calendar.isDateInYesterday(thread.updatedAt) {
                return "yesterday"
            }
            return "earlier"
        }

        return [
            NotificationGroup(id: "today", title: "Today", threads: groups["today"] ?? []),
            NotificationGroup(id: "yesterday", title: "Yesterday", threads: groups["yesterday"] ?? []),
            NotificationGroup(id: "earlier", title: "Earlier", threads: groups["earlier"] ?? []),
        ].filter { !$0.threads.isEmpty }
    }

    private var filteredNotifications: [GitHubNotificationThread] {
        runtimeData.notifications.filter {
            $0.matches(search: searchText, filter: selectedFilter, repository: selectedRepository, provider: runtimeData.provider)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if runtimeData.provider == .github {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(NotificationFilter.available(for: runtimeData.provider)) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .accessibilityIdentifier("notificationFilter")
                }
                Picker("Repository", selection: $selectedRepository) {
                    Text("All repositories").tag("")
                    ForEach(repositories, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("repositoryFilter")
                .help("Filter previously loaded items without making a network request")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            HStack {
                Text("Showing \(filteredNotifications.count) of \(runtimeData.notifications.count) loaded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedFilter != .all || !selectedRepository.isEmpty || !searchText.isEmpty {
                    Button("Clear filters") {
                        selectedFilter = .all
                        selectedRepository = ""
                        searchText = ""
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var repositories: [String] {
        var names = Set(runtimeData.notifications.map { $0.repository.fullName })
        // Preserve an empty selected scope until the user clears the filter.
        if !selectedRepository.isEmpty { names.insert(selectedRepository) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Notifications").font(.headline)
                        Text(runtimeData.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                            .help(subtitle)
                    }
                }
                Spacer(minLength: 8)
                headerControls
            }
            bulkActionButtons
        }
        .disabled(bulkAction != nil)
    }

    private var headerControls: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 8) { headerControlButtons }
            } else {
                headerControlButtons
            }
        }
    }

    private var headerControlButtons: some View {
        HStack(spacing: 8) {
            Button {
                runtimeData.refreshNotifications()
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
            }
            .disabled(runtimeData.isRefreshing || runtimeData.isPerformingAnyAction)
            .accessibilityLabel("Refresh notifications")
            .help("Refresh (⌘R)")
            .keyboardShortcut("r")

            Button {
                openURL(runtimeData.providerNotificationsURL)
            } label: {
                Image(systemName: "safari").frame(width: 24, height: 24)
            }
            .accessibilityLabel("Open notifications in browser")
            .help("Open in Browser")

            Button {
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .accessibilityLabel("Open Settings")
            .help("Settings (⌘,)")
            .keyboardShortcut(",")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power").frame(width: 24, height: 24)
            }
            .accessibilityLabel("Quit GitBird")
            .help("Quit")
            .keyboardShortcut("q")
        }
        .symbolRenderingMode(.hierarchical)
        .font(.system(size: 14))
        .modifier(GlassHeaderButtonStyle())
        .controlSize(.regular)
    }

    private var bulkActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                bulkAction = runtimeData.prepareBulkAction(.read)
            } label: {
                HStack(spacing: 6) {
                    if runtimeData.isMarkingAllNotificationsAsRead {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                    Text(runtimeData.provider == .gitlab ? "Complete all Todos" : "Mark all read")
                }
            }
            .accessibilityLabel(runtimeData.provider == .gitlab ? "Complete all GitLab Todos" : "Mark all notifications as read")
            .help(runtimeData.provider == .gitlab ? "Complete every pending Todo, including unloaded items" : "Mark account notifications as read up to the last refresh")
            .accessibilityIdentifier("bulkRead")

            if runtimeData.provider == .github {
                Button {
                    bulkAction = runtimeData.prepareBulkAction(.done)
                } label: {
                    HStack(spacing: 6) {
                        if runtimeData.isMarkingAllNotificationsAsDone {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "archivebox")
                        }
                        Text("Complete loaded")
                    }
                }
                .accessibilityLabel("Complete loaded notifications")
                .help("Complete loaded notifications, including search-hidden items")
                .accessibilityIdentifier("bulkDone")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(runtimeData.notifications.isEmpty || runtimeData.isPerformingAnyAction || runtimeData.isRefreshing)
    }

    private var subtitle: String {
        if runtimeData.isLoadingCredentials { return "Loading account…" }
        if runtimeData.lastPull == nil, !runtimeData.errorMessage.isEmpty { return "Account or connection needs attention" }
        if runtimeData.notifications.isEmpty {
            return runtimeData.lastPull == nil ? "Checking notifications…" : "All caught up"
        }
        let loadedCount = runtimeData.hasMoreNotifications
            ? "Loaded \(runtimeData.notifications.count)+"
            : "Loaded \(runtimeData.notifications.count)"
        guard let lastPull = runtimeData.lastPull else { return loadedCount }
        return "\(loadedCount) · Updated \(lastPull.formatted(.relative(presentation: .named)))"
    }

    private var subtitleColor: Color {
        if !runtimeData.errorMessage.isEmpty {
            return .red
        }
        if runtimeData.notifications.isEmpty, runtimeData.lastPull != nil, !runtimeData.isLoadingCredentials {
            return .green
        }
        return .secondary
    }

    @ViewBuilder
    private var content: some View {
        if runtimeData.isLoadingCredentials {
            ProgressView("Loading your account securely…")
                .accessibilityLabel("Loading account credentials")
        } else if runtimeData.notifications.isEmpty, !runtimeData.errorMessage.isEmpty {
            errorNotice
        } else if runtimeData.notifications.isEmpty, runtimeData.lastPull == nil {
            ProgressView("Checking notifications…")
                .accessibilityLabel("Checking notifications")
        } else if runtimeData.notifications.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 8) {
                    Text("All caught up")
                        .font(.headline)
                    Text("New notifications will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !runtimeData.errorMessage.isEmpty {
                        errorNotice
                            .padding(.bottom, 10)
                    }
                    if notificationGroups.isEmpty {
                        Text("No loaded notifications match your filters.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                    ForEach(notificationGroups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, group.id == "today" ? 4 : 10)

                            ForEach(group.threads) { thread in
                                NotificationRowView(
                                    thread: thread,
                                    details: runtimeData.subjectDetailsByThreadId[thread.id],
                                    onOpen: { thread, url in
                                        closeMenuWindowIfPossible()
                                        openURL(runtimeData.urlForOpeningNotificationDetail(threadId: thread.id, baseURL: url))
                                    },
                                    onMarkAsDone: { thread in
                                        runtimeData.markNotificationAsDone(threadId: thread.id)
                                    },
                                    onMarkAsRead: { thread in
                                        runtimeData.markNotificationAsRead(threadId: thread.id)
                                    },
                                    provider: runtimeData.provider,
                                    isPerformingAction: runtimeData.isPerformingAction(for: thread.id),
                                    actionsDisabled: runtimeData.isPerformingBulkAction || runtimeData.isRefreshing,
                                    allowedAvatarHosts: runtimeData.allowedAvatarHosts
                                )
                            }
                        }
                    }

                    if runtimeData.isLoadingMoreNotifications {
                        HStack(spacing: 10) {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if runtimeData.hasMoreNotifications {
                        HStack {
                            Spacer()
                            Button("Load more") {
                                runtimeData.loadMoreNotifications()
                            }
                            .disabled(runtimeData.isPerformingAnyAction || runtimeData.isRefreshing)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }

                    if !runtimeData.loadMoreError.isEmpty {
                        HStack {
                            Spacer()
                            Text(runtimeData.loadMoreError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.bottom, 6)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
    }

    private var errorNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                Text(runtimeData.errorMessage)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Account Settings") {
                    settingsSection = "token"
                    NSApp.activate()
                    openSettings()
                }
                Button("Retry refresh") {
                    if runtimeData.credentialError.isEmpty {
                        runtimeData.refreshNotifications()
                    } else {
                        Task { await runtimeData.loadCredentials() }
                    }
                }
                .disabled(runtimeData.isRefreshing || runtimeData.isPerformingAnyAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityIdentifier("notificationError")
    }

    @MainActor
    private func closeMenuWindowIfPossible() {
        // MenuBarExtra(.window) windows may not support performClose, which can trigger a system beep.
        dismiss()
        NSApp.keyWindow?.orderOut(nil)
    }
}

private struct MenuBarWindowSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            VisualEffectView(material: .menu, blendingMode: .withinWindow)
        }
    }
}

private struct GlassHeaderButtonStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.bordered)
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderless)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RuntimeData())
}
