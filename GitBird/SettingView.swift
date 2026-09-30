//
//  SettingView.swift
//  GitBird
//

import AppKit
import SwiftUI
import ServiceManagement

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
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .token: return "Account"
        case .support: return "Support"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .token: return "key.horizontal"
        case .support: return "heart"
        case .about: return "info.circle"
        }
    }
}

struct SettingView: View {
    @EnvironmentObject private var runtimeData: RuntimeData
    @AppStorage("settingsSection") private var selection: SettingsSection = .general

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
                case .support:
                    SupportSettingsView()
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

    @Environment(\.scenePhase) private var scenePhase
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: { enabled in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = "Couldn’t change launch at login. Check Login Items in System Settings."
            }
            loginStatus = SMAppService.mainApp.status
        })
    }

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
                Section("Startup") {
                    Toggle("Launch GitBird at login", isOn: launchAtLogin)
                        .help("Start GitBird automatically when you sign in to your Mac")
                    if loginStatus == .requiresApproval {
                        Text("Allow GitBird under Login Items in System Settings to finish enabling startup.")
                            .foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if let loginError { Text(loginError).foregroundStyle(.secondary) }
                }
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
                                .help("How often to refresh notifications")

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
                    .help("When enabled, only notifications the selected provider still marks unread or pending are shown.")

                } header: {
                    Text("Notifications")
                } footer: {
                    Text("GitBird refreshes automatically while it is running. The interval applies to successful polls; temporary failures retry with a backoff. Provider API rate limits apply.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .navigationTitle("General")
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loginStatus = SMAppService.mainApp.status }
        }
    }
}

private struct TokenSettingsView: View {
    @EnvironmentObject private var runtimeData: RuntimeData
    @State private var showRemoveToken = false
    @State private var hostDraft = ""
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
                        HStack {
                            TextField("GitLab host", text: $hostDraft)
                                .textContentType(.URL)
                                .onSubmit { applyHost() }
                            Button("Use host", action: applyHost)
                                .disabled(validatedGitLabBaseURL(hostDraft) == nil || tokenChecking)
                        }
                        Text("Use an HTTPS origin such as https://gitlab.com. Tokens are saved separately for each host.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    SecureField("Personal access token", text: $runtimeData.accessToken)
                        .textContentType(.password)
                        .disabled(tokenChecking || runtimeData.isLoadingCredentials)

                    if runtimeData.isLoadingCredentials { ProgressView("Loading saved token…") }
                    if !runtimeData.credentialError.isEmpty {
                        Text(runtimeData.credentialError).foregroundStyle(.secondary)
                        Button("Retry Keychain") { Task { await runtimeData.loadCredentials(requireVerification: runtimeData.accountNeedsVerification) } }
                    }

                    HStack(spacing: 10) {
                        Button("Verify and save token") {
                            tokenChecking = true
                            Task {
                                let (ok, err) = await runtimeData.testAccessToken()
                                tokenChecking = false
                                showTokenAlert = true
                                tokenAlertTitle = ok ? "Token verified and saved" : "Access token verification failed"
                                tokenAlertContent = err

                                if ok {
                                    AppLog.info("Access token verification succeeded")
                                } else {
                                    AppLog.warning("Access token verification failed: \(err)")
                                }
                            }
                        }
                        .disabled(tokenChecking || runtimeData.isLoadingCredentials || runtimeData.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Remove saved token", role: .destructive) { showRemoveToken = true }
                            .disabled(tokenChecking || runtimeData.isLoadingCredentials)

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
                    Text("Tokens are activated and saved to Keychain only after verification succeeds. Editing the field does not replace the active token.")
                    Text(runtimeData.provider == .github ? "GitHub notifications need a classic token with the notifications scope, plus repo access for private repositories. Fine-grained personal access tokens do not support this endpoint." : "GitLab Todos need a token with api scope. Read and done both complete the Todo on GitLab.")
                }

                Section("Help") {
                    Link("Open \(runtimeData.provider.displayName) token settings", destination: runtimeData.providerLoginURL)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .navigationTitle("Account")
        .confirmationDialog("Remove this account’s saved token?", isPresented: $showRemoveToken, titleVisibility: .visible) {
            Button("Remove saved token", role: .destructive) { Task { await runtimeData.removeAccessToken() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GitBird will stop using this account until you verify and save a token again. Tokens for other hosts are kept.")
        }
        .task { hostDraft = runtimeData.gitlabBaseURL }
        .onChange(of: runtimeData.gitlabBaseURL) { _, value in hostDraft = value }
    }

    private func applyHost() {
        guard let host = validatedGitLabBaseURL(hostDraft) else { return }
        runtimeData.gitlabBaseURL = host.absoluteString
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
        .environment(SupportPurchaseManager())
}

private struct SupportSettingsView: View {
    @Environment(SupportPurchaseManager.self) private var support
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Text("Support GitBird")
                        .font(.headline)
                    Text("Help keep GitBird fast, simple, and maintained.")
                        .foregroundStyle(.secondary)
                    Text("Support is optional. All features remain available without a purchase.")
                    Text("A consumable tip you can send multiple times. No subscription or automatic renewal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LabeledContent("App Store Price") {
                        if support.isLoading && support.product == nil {
                            ProgressView("Loading price…")
                                .controlSize(.small)
                        } else {
                            Text(support.product?.displayPrice ?? "Unavailable")
                                .monospacedDigit()
                        }
                    }

                    Button(support.purchaseTitle) {
                        Task { await support.purchase() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!support.canPurchase)
                    .accessibilityLabel("Send Support Tip")
                    .accessibilityValue(support.product?.displayPrice ?? "Unavailable")
                    .help("Send an optional, one-time tip through the App Store")

                    if support.hasCheckedAvailability && !support.canMakePayments {
                        Text("In-App Purchases are unavailable. Check your App Store account and payment restrictions.")
                            .foregroundStyle(.secondary)
                    }
                    if support.hasCheckedAvailability && support.product == nil && !support.isLoading {
                        Text("The App Store support tip is currently unavailable. All GitBird features remain available.")
                            .foregroundStyle(.secondary)
                        Button("Retry App Store") {
                            support.statusMessage = nil
                            Task { await support.refresh() }
                        }
                        .disabled(support.isPurchasing)
                    }
                    if let message = support.statusMessage {
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityLabel("Purchase status: \(message)")
                    }
                } header: {
                    Text("Support Development")
                }

                Section("More ways to support") {
                    if let url = URL(string: "https://www.patreon.com/h3p") {
                        Link(destination: url) {
                            Label("Support via Patreon", systemImage: "safari")
                        }
                    }
                    if let url = URL(string: "https://github.com/h3pdesign/GitBird") {
                        Link(destination: url) {
                            Label("Star on GitHub", systemImage: "star")
                        }
                    }
                }

                Section("Help and feedback") {
                    if let url = URL(string: "https://github.com/h3pdesign/GitBird/issues") {
                        Link(destination: url) {
                            Label("Report an issue or request a feature", systemImage: "exclamationmark.bubble")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(20)
        }
        .navigationTitle("Support")
        .task { await support.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await support.refresh() } }
        }
    }
}
