//
//  SwipeAeroSpaceApp.swift
//  SwipeAeroSpace
//
//  Created by Tricster on 1/25/25.
//

import Cocoa
import SwiftUI

@available(macOS 14.0, *)
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings") {
            openSettings()
        }
    }
}

func checkAccessibilityPermissions() {
    let options = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
    ]
    guard !AXIsProcessTrustedWithOptions(options as CFDictionary) else {
        return
    }

    let alert = NSAlert()
    alert.messageText = "Accessibility Permission Required"
    alert.informativeText =
        "SwipeAeroSpace needs Accessibility permission to read trackpad gestures and switch AeroSpace workspaces."
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Not Now")

    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!
        )
    }
}

@main
struct SwipeAeroSpaceApp: App {
    @AppStorage(SettingKey.menuBarExtraIsInserted) var menuBarExtraIsInserted = SettingDefaults.menuBarExtraIsInserted
    @Environment(\.openWindow) private var openWindow
    @State var swipeManager: SwipeManager

    init() {
        AppSettings.migrateLegacyKeys()
        let swipeManager = SwipeManager()
        _swipeManager = State(initialValue: swipeManager)
        swipeManager.start()
        DispatchQueue.main.async {
            checkAccessibilityPermissions()
        }
    }

    var body: some Scene {
        MenuBarExtra(
            "Screenshots",
            image: "MenubarIcon",
            isInserted: $menuBarExtraIsInserted
        ) {
            Button("Workspace Overview") {
                swipeManager.showWorkspaceOverview()
            }
            Divider()
            Button("Next Workspace") {
                swipeManager.nextWorkspace()
            }
            Button("Prev Workspace") {
                swipeManager.prevWorkspace()
            }

            if #available(macOS 14.0, *) {
                SettingsButton()
            } else {
                Button(
                    action: {
                        NSApp.sendAction(
                            Selector(("showSettingsWindow:")),
                            to: nil,
                            from: nil
                        )
                    },
                    label: {
                        Text("Settings")
                    }
                )
            }

            Button("About") {
                openWindow(id: "about")
            }
            Divider()

            Button("Quit") {
                swipeManager.stop()
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }

        Settings {
            SettingsView(
                swipeManager: swipeManager,
                socketInfo: swipeManager.socketInfo
            )
        }.windowResizability(.contentSize)

        WindowGroup(id: "about") {
            AboutView()
        }.windowResizability(.contentSize)
    }
}
