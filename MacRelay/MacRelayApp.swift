import SwiftUI

@main
struct MacRelayApp: App {
    @StateObject private var store = IRCStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 600)
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
    }
}
