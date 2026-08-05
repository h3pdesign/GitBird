//
//  GitBirdApp.swift
//  GitBird
//
//  Created by rook1e on 2023/10/6.
//

import SwiftUI

@main
struct GitBirdApp: App {
    init() {
        AppLog.bootstrap()
        AppLog.info("App launch")
        Task { @MainActor in
            RuntimeData.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(RuntimeData.shared)
                .frame(width: 420, height: 520)
        } label: {
            MenuBarLabelView()
                .environmentObject(RuntimeData.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingView()
                .environmentObject(RuntimeData.shared)
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
                Text("\(count)")
                    .monospacedDigit()
            }

            if hasError {
                Text("!")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "GitBird, \(count) unread notifications" : "GitBird, no unread notifications")
    }
}
