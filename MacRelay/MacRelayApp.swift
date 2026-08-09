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
        let defaults = UserDefaults.standard
        let showInMenuBar = defaults.bool(forKey: AppPreferenceKeys.showInMenuBar)
        MacRelayMenuBarController.shared.setVisible(showInMenuBar)
        applyActivationPolicy(
            showInMenuBar: showInMenuBar,
            hideDockIcon: defaults.bool(forKey: AppPreferenceKeys.hideDockIcon)
        )
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
        applyActivationPolicy(
            showInMenuBar: defaults.bool(forKey: AppPreferenceKeys.showInMenuBar),
            hideDockIcon: defaults.bool(forKey: AppPreferenceKeys.hideDockIcon)
        )
    }

    func applyActivationPolicy(showInMenuBar: Bool, hideDockIcon: Bool) {
        NSApp.setActivationPolicy(showInMenuBar && hideDockIcon ? .accessory : .regular)
    }

    func applyBackgroundPolicy() {
        let defaults = UserDefaults.standard
        let keepRunning = defaults.object(forKey: AppPreferenceKeys.keepRunningWhenWindowClosed) == nil
            ? true
            : defaults.bool(forKey: AppPreferenceKeys.keepRunningWhenWindowClosed)
        applyBackgroundPolicy(keepRunning: keepRunning)
    }

    func applyBackgroundPolicy(keepRunning: Bool) {
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
    @StateObject private var menuBarController = MacRelayMenuBarController.shared
    @AppStorage(AppPreferenceKeys.showInMenuBar) private var showInMenuBar = false
    @AppStorage(AppPreferenceKeys.hideDockIcon) private var hideDockIcon = false
    @AppStorage(AppPreferenceKeys.keepRunningWhenWindowClosed) private var keepRunningWhenWindowClosed = true

    var body: some Scene {
        Window("MacRelay", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 600)
                .background(MainWindowRegistrationView(controller: menuBarController))
                .task {
                    menuBarController.configure(store: store)
                    menuBarController.setVisible(showInMenuBar)
                    appDelegate.applyActivationPolicy(
                        showInMenuBar: showInMenuBar,
                        hideDockIcon: hideDockIcon
                    )
                }
                .onChange(of: showInMenuBar) { _, isVisible in
                    Task { @MainActor in
                        await Task.yield()
                        menuBarController.setVisible(isVisible)
                        appDelegate.applyActivationPolicy(
                            showInMenuBar: isVisible,
                            hideDockIcon: hideDockIcon
                        )
                    }
                }
                .onChange(of: hideDockIcon) { _, shouldHideDockIcon in
                    Task { @MainActor in
                        await Task.yield()
                        menuBarController.setVisible(showInMenuBar)
                        appDelegate.applyActivationPolicy(
                            showInMenuBar: showInMenuBar,
                            hideDockIcon: shouldHideDockIcon
                        )
                    }
                }
                .onChange(of: keepRunningWhenWindowClosed) { _, keepRunning in
                    Task { @MainActor in
                        await Task.yield()
                        appDelegate.applyBackgroundPolicy(keepRunning: keepRunning)
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 800)
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

private struct MainWindowRegistrationView: View {
    @Environment(\.openWindow) private var openWindow
    let controller: MacRelayMenuBarController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                controller.openMainWindow = { openWindow(id: "main") }
            }
    }
}

@MainActor
final class MacRelayMenuBarController: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = MacRelayMenuBarController()

    private weak var store: IRCStore?
    private var statusItem: NSStatusItem?
    var openMainWindow: (() -> Void)?

    func configure(store: IRCStore) {
        self.store = store
    }

    func setVisible(_ isVisible: Bool) {
        guard isVisible != (statusItem != nil) else { return }

        if isVisible {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "MacRelay.MenuBar.StatusItem.v2"
            item.isVisible = true
            item.button?.image = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right",
                accessibilityDescription: "MacRelay"
            )
            item.button?.imagePosition = .imageLeading
            item.button?.title = "MacRelay"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let store else { return }

        addDisabledItem(store.connectionState == .connected && store.isConnectedViaZNC
            ? "Tilkoblet via ZNC"
            : store.connectionState.label, to: menu)
        addDisabledItem("Server: \(store.configuration.name)", to: menu)

        let unreadConversations = store.conversations.filter {
            $0.unreadCount > 0 || $0.mentionCount > 0
        }
        if !unreadConversations.isEmpty {
            menu.addItem(.separator())
            addDisabledItem("Ulest", to: menu)
            for conversation in unreadConversations {
                let count = max(conversation.unreadCount, conversation.mentionCount)
                let item = NSMenuItem(
                    title: "\(conversation.name) (\(count))",
                    action: #selector(openConversation(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = conversation.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addItem("Vis MacRelay", action: #selector(showMainWindow), to: menu)
        if store.connectionState == .disconnected {
            addItem("Koble til", action: #selector(connect), to: menu)
        } else {
            addItem("Koble fra", action: #selector(disconnect), to: menu)
        }

        let awayItem = addItem(
            store.isManuallyAway ? "Tilbake" : "Away",
            action: #selector(toggleAway),
            to: menu
        )
        awayItem.isEnabled = store.connectionState == .connected

        addItem("Innstillinger …", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addItem("Avslutt MacRelay", action: #selector(quit), to: menu)
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func openConversation(_ sender: NSMenuItem) {
        if let conversationID = sender.representedObject as? String {
            store?.selectConversation(conversationID)
        }
        showMainWindow()
    }

    @objc private func showMainWindow() {
        openMainWindow?()
        Task { @MainActor in
            await Task.yield()
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func connect() {
        store?.connect()
    }

    @objc private func disconnect() {
        store?.disconnect()
    }

    @objc private func toggleAway() {
        store?.toggleManualAway()
    }

    @objc private func showSettings() {
        store?.showSettings = true
        showMainWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
