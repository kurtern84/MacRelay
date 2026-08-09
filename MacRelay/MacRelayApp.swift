import AppKit
import SwiftUI

enum AppPreferenceKeys {
    static let showInMenuBar = "MacRelay.showInMenuBar.v1"
    static let keepRunningWhenWindowClosed = "MacRelay.keepRunningWhenWindowClosed.v1"
    static let hideDockIcon = "MacRelay.hideDockIcon.v1"
}

@MainActor
final class MacRelayAppDelegate: NSObject, NSApplicationDelegate {
    private var automaticTerminationDisabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        applyBackgroundPolicy()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let defaults = UserDefaults.standard
        let keepRunning = defaults.object(forKey: AppPreferenceKeys.keepRunningWhenWindowClosed) == nil
            ? true
            : defaults.bool(forKey: AppPreferenceKeys.keepRunningWhenWindowClosed)
        return !keepRunning
    }

    func applyActivationPolicy() {
        let defaults = UserDefaults.standard
        let hideDockIcon = defaults.bool(forKey: AppPreferenceKeys.showInMenuBar)
            && defaults.bool(forKey: AppPreferenceKeys.hideDockIcon)
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    func applyBackgroundPolicy() {
        let defaults = UserDefaults.standard
        let keepRunning = defaults.object(forKey: AppPreferenceKeys.keepRunningWhenWindowClosed) == nil
            ? true
            : defaults.bool(forKey: AppPreferenceKeys.keepRunningWhenWindowClosed)
        if keepRunning, !automaticTerminationDisabled {
            ProcessInfo.processInfo.disableAutomaticTermination("MacRelay holder IRC-tilkoblingen aktiv")
            automaticTerminationDisabled = true
        } else if !keepRunning, automaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination("MacRelay holder ikke lenger IRC-tilkoblingen aktiv")
            automaticTerminationDisabled = false
        }
    }
}

@main
struct MacRelayApp: App {
    @NSApplicationDelegateAdaptor(MacRelayAppDelegate.self) private var appDelegate
    @StateObject private var store = IRCStore()
    @AppStorage(AppPreferenceKeys.showInMenuBar) private var showInMenuBar = false
    @AppStorage(AppPreferenceKeys.hideDockIcon) private var hideDockIcon = false
    @AppStorage(AppPreferenceKeys.keepRunningWhenWindowClosed) private var keepRunningWhenWindowClosed = true

    var body: some Scene {
        Window("MacRelay", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 600)
                .task { appDelegate.applyActivationPolicy() }
                .onChange(of: showInMenuBar) { _, _ in appDelegate.applyActivationPolicy() }
                .onChange(of: hideDockIcon) { _, _ in appDelegate.applyActivationPolicy() }
                .onChange(of: keepRunningWhenWindowClosed) { _, _ in appDelegate.applyBackgroundPolicy() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("IRC") {
                Button("Koble til") {
                    store.connect()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(store.connectionState != .disconnected)

                Button("Koble fra") {
                    store.disconnect()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(store.connectionState == .disconnected)

                Divider()

                Button("Bli med i kanal …") {
                    store.showJoinChannel = true
                }
                .keyboardShortcut("j", modifiers: [.command])
                .disabled(store.connectionState != .connected)

                Divider()

                Button("Favorittservere …") {
                    store.showSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])

                Button("NickServ …") {
                    store.showSettings = true
                }

                Button("WHOIS …") {
                    store.showWhoisPrompt = true
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(store.connectionState != .connected)

                Button("Ignoreringsliste …") {
                    store.showIgnoreList = true
                }

                Divider()

                Button("Åpne logger …") {
                    store.openLogsFolder()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            ServerSettingsView()
                .environmentObject(store)
                .frame(width: 520)
                .padding()
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MacRelayMenuBarView()
                .environmentObject(store)
        } label: {
            Image(systemName: store.totalUnreadCount > 0
                ? "bubble.left.and.bubble.right.fill"
                : "bubble.left.and.bubble.right")
                .accessibilityLabel(store.totalUnreadCount > 0
                    ? "MacRelay, \(store.totalUnreadCount) uleste"
                    : "MacRelay")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MacRelayMenuBarView: View {
    @EnvironmentObject private var store: IRCStore
    @Environment(\.openWindow) private var openWindow

    private var unreadConversations: [Conversation] {
        store.conversations.filter { $0.unreadCount > 0 || $0.mentionCount > 0 }
    }

    var body: some View {
        Label(statusText, systemImage: statusIcon)
        Text("Server: \(store.configuration.name)")

        if store.isConnectedViaZNC {
            Label("Tilkoblet via ZNC", systemImage: "checkmark.shield")
        }

        if !unreadConversations.isEmpty {
            Divider()
            Section("Ulest") {
                ForEach(unreadConversations) { conversation in
                    Button {
                        showMainWindow(selecting: conversation.id)
                    } label: {
                        let count = max(conversation.unreadCount, conversation.mentionCount)
                        Label(
                            "\(conversation.name) (\(count))",
                            systemImage: conversation.kind == .query ? "person.crop.circle" : "number"
                        )
                    }
                }
            }
        }

        Divider()

        Button("Vis MacRelay") {
            showMainWindow()
        }

        if store.connectionState == .disconnected {
            Button("Koble til") { store.connect() }
        } else {
            Button("Koble fra") { store.disconnect() }
        }

        Button(store.isManuallyAway ? "Tilbake" : "Away") {
            store.toggleManualAway()
        }
        .disabled(store.connectionState != .connected)

        Button("Innstillinger …") {
            store.showSettings = true
            showMainWindow()
        }

        Divider()

        Button("Avslutt MacRelay") {
            NSApp.terminate(nil)
        }
    }

    private var statusText: String {
        store.connectionState == .connected && store.isConnectedViaZNC
            ? "Tilkoblet via ZNC"
            : store.connectionState.label
    }

    private var statusIcon: String {
        switch store.connectionState {
        case .connected: "circle.fill"
        case .connecting: "circle.dotted"
        case .disconnected: "circle"
        }
    }

    private func showMainWindow(selecting conversationID: String? = nil) {
        if let conversationID {
            store.selectConversation(conversationID)
        }
        openWindow(id: "main")
        Task { @MainActor in
            await Task.yield()
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
