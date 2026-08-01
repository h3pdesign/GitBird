//
//  SettingView.swift
//  GitBird
//

import AppKit
import SwiftUI

private enum AppVersion {
    static func formatted(versionPrefix: String, buildPrefix: String) -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (v, b) {
        case let (v?, b?):
            return "\(versionPrefix)\(v) (\(b))"
        case let (v?, nil):
            return "\(versionPrefix)\(v)"
        case let (nil, b?):
            return "\(buildPrefix)\(b)"
        default:
            return ""
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case token
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .token: return "Account"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .token: return "key.horizontal"
        case .about: return "info.circle"
        }
    }
}

struct SettingView: View {
    @EnvironmentObject private var runtimeData: RuntimeData
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .withinWindow)

                VStack(alignment: .leading, spacing: 12) {
                    header

                    List(SettingsSection.allCases, selection: $selection) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            ZStack {
                VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)

                switch selection {
                case .general:
                    GeneralSettingsView()
                        .environmentObject(runtimeData)
                case .token:
                    TokenSettingsView()
                        .environmentObject(runtimeData)
                case .about:
                    AboutSettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SettingsAppIconView(size: 28, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text("GitBird")
                    .font(.headline)
                Text(versionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
    }

    private var versionString: String {
        AppVersion.formatted(versionPrefix: "v", buildPrefix: "Build ")
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var runtimeData: RuntimeData

    private var listLengthBinding: Binding<Int> {
        Binding(
            get: { runtimeData.listLength },
            set: { runtimeData.listLength = min(max($0, 1), 50) }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { runtimeData.interval },
            set: { runtimeData.interval = min(max($0, 30), 3600) }
        )
    }
 
    var body: some View {
        ScrollView {
            Form {
                Section {
                    LabeledContent("Items per page") {
                        HStack(spacing: 10) {
                            TextField("", value: listLengthBinding, format: .number)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                                .textFieldStyle(.roundedBorder)
                                .help("How many notifications to fetch per page")

                            Stepper(value: listLengthBinding, in: 1...50, step: 1) {
                                EmptyView()
                            }
                            .labelsHidden()
                        }
                    }

                    LabeledContent("Refresh interval") {
                        HStack(spacing: 10) {
                            TextField("", value: intervalBinding, format: .number)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                                .textFieldStyle(.roundedBorder)
                                .help("How often to refresh GitHub notifications")

                            Text("s")
                                .foregroundStyle(.secondary)

                            Stepper(value: intervalBinding, in: 30...3600, step: 30) {
                                EmptyView()
                            }
                            .labelsHidden()
                        }
                    }
                    Toggle("Hide read notifications", isOn: Binding(
                        get: { runtimeData.hideReadNotifications },
                        set: { newValue in runtimeData.hideReadNotifications = newValue }
                    ))
                    .help("When enabled, only notifications GitHub still marks unread are shown.")

                } header: {
                    Text("Notifications")
                } footer: {
                    Text("GitBird refreshes automatically while it is running. The interval applies to successful polls; temporary failures retry with a backoff. GitHub API has rate limits (commonly 5000 requests/hour per user).")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .navigationTitle("General")
    }
}

private struct TokenSettingsView: View {
    @EnvironmentObject private var runtimeData: RuntimeData
    @State private var tokenChecking = false
    @State private var showTokenAlert = false
    @State private var tokenAlertTitle = ""
    @State private var tokenAlertContent = ""

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Picker("Provider", selection: $runtimeData.provider) {
                        ForEach(NotificationProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    if runtimeData.provider == .gitlab {
                        TextField("GitLab host", text: $runtimeData.gitlabBaseURL)
                            .textContentType(.URL)
                    }

                    SecureField(runtimeData.provider == .github ? "Personal access token" : "Personal access token", text: $runtimeData.accessToken)
                        .textContentType(.password)
                        .disabled(tokenChecking)

                    HStack(spacing: 10) {
                        Button("Verify token") {
                            tokenChecking = true
                            Task {
                                let (ok, err) = await runtimeData.testAccessToken()
                                tokenChecking = false
                                showTokenAlert = true
                                tokenAlertTitle = ok ? "Token verified" : "Access token verification failed"
                                tokenAlertContent = err

                                if ok {
                                    AppLog.info("Access token verification succeeded")
                                } else {
                                    AppLog.warning("Access token verification failed: \(err)")
                                }
                            }
                        }
                        .disabled(tokenChecking)

                        if tokenChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .alert(isPresented: $showTokenAlert) {
                        Alert(title: Text(tokenAlertTitle), message: Text(tokenAlertContent))
                    }
                } header: {
                    Text("Access Token")
                } footer: {
                    Text(runtimeData.provider == .github ? "GitHub notifications and read state use the GitHub API." : "GitLab Todos are used as notifications; marking read completes the Todo on GitLab.")
                }

                Section("Help") {
                    Link("Open \(runtimeData.provider.displayName) token settings", destination: runtimeData.provider.loginURL)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .navigationTitle("Account")
    }
}

private struct AboutSettingsView: View {
    private let repositoryURL = URL(string: "https://github.com/h3pdesign/GitBird")!
    private let releasesURL = URL(string: "https://github.com/h3pdesign/GitBird/releases")!
    private let issuesURL = URL(string: "https://github.com/h3pdesign/GitBird/issues")!
    private let originalProjectURL = URL(string: "https://github.com/0x2E/GitStatus")!
    private let iconParkURL = URL(string: "https://github.com/bytedance/IconPark")!
    private let lucideURL = URL(string: "https://lucide.dev/icons/git-branch")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                appSummary

                Form {
                    Section("GitBird") {
                        LabeledContent("Version", value: versionString)
                        LabeledContent("Platform", value: "macOS 14.6+")
                        LabeledContent("Providers", value: "GitHub · GitLab")
                    }

                    Section("Links") {
                        Link(destination: repositoryURL) {
                            Label("GitBird repository", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Link(destination: releasesURL) {
                            Label("Releases", systemImage: "shippingbox")
                        }
                        Link(destination: issuesURL) {
                            Label("Report an issue", systemImage: "exclamationmark.bubble")
                        }
                        Link(destination: originalProjectURL) {
                            Label("Original GitStatus project", systemImage: "arrow.up.right.square")
                        }
                    }

                    Section("Credits") {
                        Link(destination: iconParkURL) {
                            Label("App artwork · IconPark", systemImage: "paintpalette")
                        }
                        Link(destination: lucideURL) {
                            Label("Menu bar icon · Lucide", systemImage: "branch")
                        }
                    }

                    Section {
                        LabeledContent("Log file") {
                            HStack(spacing: 10) {
                                Button("Show in Finder") {
                                    AppLog.revealLogFileInFinder()
                                }
                                Button("Copy path") {
                                    AppLog.copyLogFilePathToPasteboard()
                                }
                            }
                        }

                        Text(AppLog.logFileURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospaced()
                            .textSelection(.enabled)
                    } header: {
                        Text("Diagnostics")
                    } footer: {
                        Text("Attach this log file when reporting a problem. It contains app diagnostics, not your access token.")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .padding(20)
        }
        .navigationTitle("About")
    }

    private var appSummary: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsAppIconView(size: 64, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("GitBird")
                    .font(.title2.weight(.semibold))
                Text("GitHub and GitLab notifications in your menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versionString: String {
        AppVersion.formatted(versionPrefix: "Version ", buildPrefix: "Build ")
    }
}


private struct SettingsAppIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let nsImage = appIconImage
        let image = Image(nsImage: nsImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)

        if #available(macOS 14.0, *) {
            image
                .clipShape(.rect(cornerRadius: cornerRadius))
        } else {
            image
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private var appIconImage: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }

        return NSApp.applicationIconImage
    }
}

#Preview {
    SettingView()
        .environmentObject(RuntimeData())
}
