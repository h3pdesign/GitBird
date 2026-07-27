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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
     
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MenuBarWindowSurface())
        .frame(width: 420)
        .task(id: prefetchKey) {
            guard runtimeData.message.isEmpty else { return }
            guard !runtimeData.notifications.isEmpty else { return }
            runtimeData.prefetchSubjectDetails(for: runtimeData.notifications)
        }
    }

    private var prefetchKey: String {
        "\(runtimeData.notifications.count)-\(runtimeData.notifications.first?.id ?? "")-\(runtimeData.notifications.last?.id ?? "")"
    }

    private struct NotificationGroup: Identifiable {
        let id: String
        let title: String
        let threads: [GitHubNotificationThread]
    }

    private var notificationGroups: [NotificationGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let groups = Dictionary(grouping: runtimeData.notifications) { thread in
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            headerControls
        }
    }

    private var headerControls: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 8) {
                    headerControlButtons
                }
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
                Image(systemName: "arrow.clockwise")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .modifier(GlassHeaderButtonStyle())
            .controlSize(.regular)
            .disabled(runtimeData.isRefreshing)
            .help("Refresh")

            Button {
                runtimeData.markAllNotificationsAsRead()
            } label: {
                if runtimeData.isMarkingAllNotificationsAsRead {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "checkmark.circle")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                        .frame(width: 24, height: 24)
                }
            }
            .modifier(GlassHeaderButtonStyle())
            .controlSize(.regular)
            .disabled(runtimeData.notifications.isEmpty || runtimeData.isMarkingAllNotificationsAsRead)
            .help("Mark all as read")

            Button {
                runtimeData.markAllNotificationsAsDone()
            } label: {
                if runtimeData.isMarkingAllNotificationsAsDone {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "archivebox.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .frame(width: 24, height: 24)
                }
            }
            .modifier(GlassHeaderButtonStyle())
            .controlSize(.regular)
            .disabled(runtimeData.notifications.isEmpty || runtimeData.isMarkingAllNotificationsAsDone)
            .help("Mark all as done")

            Button {
                openURL(runtimeData.provider.notificationsURL)
            } label: {
                Image(systemName: "safari")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .modifier(GlassHeaderButtonStyle())
            .controlSize(.regular)
            .help("Open in Browser")

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .modifier(GlassHeaderButtonStyle())
            .controlSize(.regular)
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .modifier(GlassHeaderButtonStyle())
            .controlSize(.regular)
            .help("Quit")
            .keyboardShortcut("q")
        }
    }

    private var subtitle: String {
        if !runtimeData.message.isEmpty {
            return "Error"
        }
        if runtimeData.notifications.isEmpty {
            return "All caught up"
        }
        let loadedCount = runtimeData.hasMoreNotifications
            ? "Loaded \(runtimeData.notifications.count)+"
            : "Loaded \(runtimeData.notifications.count)"
        guard let lastPull = runtimeData.lastPull else { return loadedCount }
        return "\(loadedCount) · Updated \(lastPull.formatted(.relative(presentation: .named)))"
    }

    private var subtitleColor: Color {
        if !runtimeData.message.isEmpty {
            return .red
        }
        if runtimeData.notifications.isEmpty {
            return .green
        }
        return .secondary
    }

    @ViewBuilder
    private var content: some View {
        if !runtimeData.message.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text(runtimeData.message)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Retry") {
                    runtimeData.renewPullTask(interval: runtimeData.interval)
                }
                .buttonStyle(.link)
                .tint(.orange)
            }
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
                                    }
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
            .frame(minHeight: 220, idealHeight: 360, maxHeight: 420)
        }
    }

    @MainActor
    private func closeMenuWindowIfPossible() {
        // MenuBarExtra(.window) windows may not support performClose, which can trigger a system beep.
        dismiss()
        NSApp.keyWindow?.orderOut(nil)
    }
}

private struct MenuBarWindowSurface: View {
    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            VisualEffectView(material: .menu, blendingMode: .withinWindow)
        }
    }
}

private struct GlassHeaderButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
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
