//
//  GitBirdApp.swift
//  GitBird
//
//  Created by rook1e on 2023/10/6.
//

import SwiftUI

@main
struct GitBirdApp: App {
    @State private var support: SupportPurchaseManager
    init() {
        let support = SupportPurchaseManager()
        _support = State(initialValue: support)
        // Hosted tests create their own services and StoreKit sessions. Prevent
        // the debug app host from consuming those transactions concurrently.
        #if DEBUG
        let isHostedTest = ProcessInfo.processInfo.environment["GITBIRD_HOSTED_TESTS"] == "1"
        #else
        let isHostedTest = false
        #endif
        if !isHostedTest { support.start() }
        AppLog.bootstrap()
        AppLog.info("App launch")
        if !isHostedTest {
            Task { @MainActor in RuntimeData.shared.start() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(RuntimeData.shared)
                .environment(support)
                .frame(width: 420, height: 520)
        } label: {
            MenuBarLabelView()
                .environmentObject(RuntimeData.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingView()
                .environmentObject(RuntimeData.shared)
                .environment(support)
        }
    }
}

private struct MenuBarLabelView: View {
    @EnvironmentObject private var runtimeData: RuntimeData

    var body: some View {
        let count = runtimeData.notifications.reduce(into: 0) { count, thread in
            if thread.unread { count += 1 }
        }
        let hasError = !runtimeData.errorMessage.isEmpty

        HStack(spacing: 4) {
            Image("MenubarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)

            if count > 0 {
                Text(runtimeData.hasMoreNotifications ? "\(count)+" : "\(count)")
                    .monospacedDigit()
            }

            if hasError {
                Text("!")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GitBird, \(count) loaded unread notifications\(runtimeData.hasMoreNotifications ? ", more pages available" : "")\(hasError ? ", account or connection needs attention" : "")")
    }
}
