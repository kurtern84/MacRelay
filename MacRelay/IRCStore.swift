import AppKit
import CoreGraphics
import Foundation
import MacRelayCore
import Network
import SwiftUI
import UserNotifications

private struct PersistedIRCSession: Codable {
    let profileID: UUID
    let openChannels: [String]
    let joinedChannels: [String]
    let openQueries: [String]
    let selectedConversationID: String?
    let shouldConnect: Bool
}

@MainActor
final class IRCStore: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: String?
    @Published var profiles: [ServerConfiguration] = []
    @Published var configuration: ServerConfiguration
    @Published var ircPassword = ""
    @Published var nickServPassword = ""
    @Published var showSettings = false
    @Published var showJoinChannel = false
    @Published var showWhoisPrompt = false
    @Published var showIgnoreList = false
    @Published var joinChannelText = ""
    @Published var whoisNickname = ""
    @Published var inputText = ""
    @Published var incomingDCCOffer: DCCOffer?
    @Published var restorePreviousSession: Bool
    @Published private(set) var isConnectedViaZNC = false
    @Published private(set) var isManuallyAway = false

    private let connection = IRCConnection()
    private let logManager = LogManager()
    private let profilesKey = "MacRelay.serverProfiles.v1"
    private let selectedProfileKey = "MacRelay.selectedProfile.v1"
    private let legacyConfigurationKey = "MacRelay.serverConfiguration.v1"
    private let ignoredNicksKey = "MacRelay.ignoredNicks.v1"
    private static let sessionKey = "MacRelay.session.v1"
    private static let restoreSessionKey = "MacRelay.restorePreviousSession.v1"
    private var currentNickname = ""
    private var intentionalDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var channelsToRestore: Set<String> = []
    private var ignoredNicks: Set<String> = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var idleMonitorTask: Task<Void, Never>?
    private var isSystemSleeping = false
    private var shouldReconnectAfterWake = false
    private var isReconnectInProgress = false
    private var hasSentRegistration = false
    private var advertisedCapabilities: Set<String> = []
    private var enabledCapabilities: Set<String> = []
    private var isAutoAway = false
    private var isStartAway = false
    private var restoredSelectionID: String?
    private var pendingRestoredChannelIDs: Set<String> = []
    private var restoreSelectionTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let shouldRestorePreviousSession = defaults.object(forKey: Self.restoreSessionKey) == nil
            ? true
            : defaults.bool(forKey: Self.restoreSessionKey)
        restorePreviousSession = shouldRestorePreviousSession
        let savedSession = shouldRestorePreviousSession
            ? defaults.data(forKey: Self.sessionKey).flatMap { try? JSONDecoder().decode(PersistedIRCSession.self, from: $0) }
            : nil

        let savedProfiles: [ServerConfiguration]
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([ServerConfiguration].self, from: data),
           !decoded.isEmpty {
            savedProfiles = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyConfigurationKey),
                  let legacy = try? JSONDecoder().decode(ServerConfiguration.self, from: data) {
            savedProfiles = [legacy]
        } else {
            savedProfiles = [ServerConfiguration()]
        }

        profiles = savedProfiles
        defaults.removeObject(forKey: legacyConfigurationKey)
        let selectedID = defaults.string(forKey: selectedProfileKey).flatMap(UUID.init(uuidString:))
        let restoredProfileID = savedSession.flatMap { session in
            savedProfiles.contains(where: { $0.id == session.profileID }) ? session.profileID : nil
        }
        configuration = savedProfiles.first(where: { $0.id == restoredProfileID ?? selectedID }) ?? savedProfiles[0]
        ircPassword = KeychainStore.ircPassword(for: configuration.id)
        nickServPassword = KeychainStore.password(for: configuration.id)
        ignoredNicks = Set(defaults.stringArray(forKey: ignoredNicksKey) ?? [])
        publishProfilesToICloud()

        ensureConversation(id: serverID, name: configuration.name, kind: .server)
        selectedConversationID = serverID
        if let savedSession, savedSession.profileID == configuration.id {
            restoreWorkspace(from: savedSession)
        }

        connection.onLine = { [weak self] line in
            Task { @MainActor in self?.handle(rawLine: line) }
        }
        connection.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handle(connectionState: state) }
        }
        connection.onUnexpectedClose = { [weak self] in
            Task { @MainActor in self?.handleUnexpectedDisconnect("Forbindelsen ble lukket av serveren.") }
        }

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        sleepObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemSleep() }
        }
        wakeObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWake() }
        }
        startIdleMonitor()
        if savedSession?.shouldConnect == true {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.connect()
            }
        }
    }

    deinit {
        idleMonitorTask?.cancel()
        restoreSelectionTask?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var serverID: String { "server" }

    var ignoredNicknames: [String] { ignoredNicks.sorted() }

    func saveConfiguration() {
        configuration.name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.name.isEmpty { configuration.name = configuration.host }
        if ![5, 10, 15, 30, 60].contains(configuration.autoAwayMinutes) {
            configuration.autoAwayMinutes = 15
        }
        configuration.autoAwayMessage = configuration.autoAwayMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.autoAwayMessage.isEmpty { configuration.autoAwayMessage = "Ikke ved Mac-en" }
        if let index = profiles.firstIndex(where: { $0.id == configuration.id }) {
            profiles[index] = configuration
        } else {
            profiles.append(configuration)
        }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
            UserDefaults.standard.set(configuration.id.uuidString, forKey: selectedProfileKey)
        }
        KeychainStore.setIRCPassword(ircPassword, for: configuration.id)
        KeychainStore.setPassword(nickServPassword, for: configuration.id)
        publishProfilesToICloud()
        mutateConversation(id: serverID) { $0.name = configuration.name }

        if configuration.notifyOnMention {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        UserDefaults.standard.set(restorePreviousSession, forKey: Self.restoreSessionKey)
        updateAutoAwayState()
        saveSessionState()
    }

    func selectProfile(_ id: UUID) {
        guard connectionState == .disconnected,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        saveConfiguration()
        configuration = profile
        ircPassword = KeychainStore.ircPassword(for: id)
        nickServPassword = KeychainStore.password(for: id)
        UserDefaults.standard.set(id.uuidString, forKey: selectedProfileKey)
        publishProfilesToICloud()
        mutateConversation(id: serverID) { $0.name = profile.name }
        saveSessionState()
    }

    func addProfile() {
        guard connectionState == .disconnected else { return }
        saveConfiguration()
        var profile = ServerConfiguration()
        profile.name = "Ny server"
        profile.host = ""
        profile.autoJoinChannels = ""
        profiles.append(profile)
        configuration = profile
        ircPassword = ""
        nickServPassword = ""
        saveConfiguration()
    }

    private func publishProfilesToICloud() {
        ICloudProfileStore.publish(profiles: profiles, selectedProfileID: configuration.id)
    }

    func deleteCurrentProfile() {
        guard connectionState == .disconnected, profiles.count > 1 else { return }
        let removedID = configuration.id
        profiles.removeAll { $0.id == removedID }
        KeychainStore.removeIRCPassword(for: removedID)
        KeychainStore.removePassword(for: removedID)
        configuration = profiles[0]
        ircPassword = KeychainStore.ircPassword(for: configuration.id)
        nickServPassword = KeychainStore.password(for: configuration.id)
        saveConfiguration()
    }

    func toggleConnection() {
        connectionState == .disconnected ? connect() : disconnect()
    }

    func toggleManualAway() {
        guard connectionState == .connected else { return }
        if isManuallyAway {
            connection.send("AWAY")
            isManuallyAway = false
            appendStatus("Du er tilbake.", kind: .notice)
            updateAutoAwayState()
        } else {
            connection.send("AWAY :\(configuration.autoAwayMessage)")
            isAutoAway = false
            isStartAway = false
            isManuallyAway = true
            appendStatus("Du er markert som away.", kind: .notice)
        }
    }

    func connect() {
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        shouldReconnectAfterWake = false
        startConnection(isReconnect: false)
    }

    func reconnect() {
        channelsToRestore = Set(conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name))
        reconnectTask?.cancel()
        reconnectTask = nil
        connection.disconnect(reason: "manuell reconnect")
        connectionState = .disconnected
        isAutoAway = false
        isStartAway = false
        markAllChannelsDisconnected()
        intentionalDisconnect = false
        appendStatus("Kobler til serveren på nytt …")
        startConnection(isReconnect: true)
    }

    private func startConnection(isReconnect: Bool) {
        guard connectionState == .disconnected, !configuration.host.isEmpty else { return }
        saveConfiguration()
        intentionalDisconnect = false
        isReconnectInProgress = isReconnect
        currentNickname = configuration.nickname
        connectionState = .connecting
        hasSentRegistration = false
        advertisedCapabilities.removeAll()
        enabledCapabilities.removeAll()
        isConnectedViaZNC = false
        saveSessionState()
        let prefix = isReconnect ? "Kobler til igjen" : "Kobler til"
        appendStatus("\(prefix) \(configuration.host):\(configuration.port)\(configuration.useTLS ? " med TLS" : "") …")
        connection.connect(
            host: configuration.host,
            port: configuration.port,
            useTLS: configuration.useTLS,
            allowUntrustedCertificate: configuration.allowUntrustedCertificate
        )
    }

    func disconnect() {
        intentionalDisconnect = true
        shouldReconnectAfterWake = false
        isReconnectInProgress = false
        isAutoAway = false
        isStartAway = false
        clearRestoredSelection()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        if connectionState == .connected { sendRaw("QUIT :MacRelay avsluttes") }
        connection.disconnect(reason: "manuell disconnect")
        connectionState = .disconnected
        markAllChannelsDisconnected()
        appendStatus("Koblet fra serveren.")
        saveSessionState()
    }

    func selectConversation(_ id: String) {
        selectedConversationID = id
        markConversationRead(id)
    }

    func markConversationRead(_ id: String) {
        mutateConversation(id: id) {
            $0.unreadCount = 0
            $0.mentionCount = 0
        }
        if let restoredSelectionID, restoredSelectionID != id {
            clearRestoredSelection()
        }
        saveSessionState()
    }

    func joinChannel() {
        var channel = joinChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty else { return }
        if !channel.hasPrefix("#") && !channel.hasPrefix("&") { channel = "#" + channel }
        sendRaw("JOIN \(channel)")
        joinChannelText = ""
        showJoinChannel = false
    }

    func part(_ conversation: Conversation) {
        guard conversation.kind == .channel else { return }
        sendRaw("PART \(conversation.name) :Forlater kanalen")
    }

    func requestTopic(for conversation: Conversation) {
        guard conversation.kind == .channel else { return }
        sendRaw("TOPIC \(conversation.name)")
    }

    func sendInput() {
        let text = inputText.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        inputText = ""
        execute(text)
    }

    func closeConversation(_ id: String) {
        guard id != serverID, let conversation = conversations.first(where: { $0.id == id }) else { return }
        if conversation.kind == .channel, conversation.isJoined, connectionState == .connected { part(conversation) }
        if conversation.kind == .channel {
            channelsToRestore = Set(channelsToRestore.filter {
                $0.caseInsensitiveCompare(conversation.name) != .orderedSame
            })
        }
        conversations.removeAll { $0.id == id }
        if selectedConversationID == id { selectedConversationID = serverID }
        saveSessionState()
    }

    func openQuery(with nickname: String) {
        let id = conversationID(for: nickname)
        ensureConversation(id: id, name: nickname, kind: .query)
        selectConversation(id)
    }

    func whois(_ nickname: String) {
        guard connectionState == .connected else { return }
        openQuery(with: nickname)
        sendRaw("WHOIS \(nickname)")
    }

    func submitWhois() {
        let nickname = whoisNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty else { return }
        whoisNickname = ""
        showWhoisPrompt = false
        whois(nickname)
    }

    func toggleIgnore(_ nickname: String) {
        let key = nickname.lowercased()
        if ignoredNicks.contains(key) {
            ignoredNicks.remove(key)
            appendStatus("Ignorerer ikke lenger \(nickname).")
        } else {
            ignoredNicks.insert(key)
            appendStatus("Ignorerer meldinger fra \(nickname).")
        }
        UserDefaults.standard.set(Array(ignoredNicks).sorted(), forKey: ignoredNicksKey)
    }

    func isIgnored(_ nickname: String) -> Bool {
        ignoredNicks.contains(nickname.lowercased())
    }

    func openLog(for conversation: Conversation) {
        logManager.reveal(serverName: configuration.name, conversationName: conversation.name)
    }

    func openLogsFolder() {
        logManager.revealLogsFolder()
    }

    func dismissDCCOffer() {
        incomingDCCOffer = nil
    }

    private func execute(_ text: String) {
        guard text.hasPrefix("/") else {
            sendChat(text)
            return
        }

        let body = String(text.dropFirst())
        let pieces = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = pieces.first else { return }
        let command = first.lowercased()
        let argument = pieces.count > 1 ? String(pieces[1]) : ""

        switch command {
        case "join", "j":
            joinChannelText = argument
            joinChannel()
        case "part":
            guard let selectedConversation, selectedConversation.kind == .channel else {
                appendStatus("Velg en kanal før du bruker /part.", kind: .error)
                return
            }
            sendRaw("PART \(selectedConversation.name) :\(argument.isEmpty ? "Forlater kanalen" : argument)")
        case "msg":
            let values = argument.split(separator: " ", maxSplits: 1)
            guard values.count == 2 else {
                appendStatus("Bruk: /msg nick melding", kind: .error)
                return
            }
            let target = String(values[0])
            openQuery(with: target)
            sendMessage(String(values[1]), to: target)
        case "query":
            guard let nickname = argument.split(separator: " ").first else {
                appendStatus("Bruk: /query nick", kind: .error)
                return
            }
            openQuery(with: String(nickname))
        case "whois":
            guard let nickname = argument.split(separator: " ").first else {
                appendStatus("Bruk: /whois nick", kind: .error)
                return
            }
            whois(String(nickname))
        case "me":
            guard let target = selectedConversation, target.kind != .server, !argument.isEmpty else { return }
            sendRaw("PRIVMSG \(target.name) :\u{1}ACTION \(argument)\u{1}")
            if !enabledCapabilities.contains("echo-message") {
                appendMessage(to: target.id, ChatMessage(sender: currentNickname, text: argument, kind: .action, isOwn: true))
            }
        case "nick":
            if !argument.isEmpty { sendRaw("NICK \(argument)") }
        case "topic":
            guard let channel = selectedConversation, channel.kind == .channel else {
                appendStatus("Velg en kanal før du bruker /topic.", kind: .error)
                return
            }
            sendRaw(argument.isEmpty ? "TOPIC \(channel.name)" : "TOPIC \(channel.name) :\(argument)")
        case "kick":
            guard let channel = selectedConversation, channel.kind == .channel else {
                appendStatus("Velg en kanal før du bruker /kick.", kind: .error)
                return
            }
            let values = argument.split(separator: " ", maxSplits: 1)
            guard let nickname = values.first else {
                appendStatus("Bruk: /kick nick [grunn]", kind: .error)
                return
            }
            let reason = values.count > 1 ? String(values[1]) : "Fjernet fra kanalen"
            sendRaw("KICK \(channel.name) \(nickname) :\(reason)")
        case "mode":
            guard !argument.isEmpty else {
                appendStatus("Bruk: /mode [mål] modus", kind: .error)
                return
            }
            if let channel = selectedConversation, channel.kind == .channel,
               argument.first == "+" || argument.first == "-" {
                sendRaw("MODE \(channel.name) \(argument)")
            } else {
                sendRaw("MODE \(argument)")
            }
        case "ignore":
            guard let nickname = argument.split(separator: " ").first else {
                appendStatus("Bruk: /ignore nick", kind: .error)
                return
            }
            if !isIgnored(String(nickname)) { toggleIgnore(String(nickname)) }
        case "unignore":
            guard let nickname = argument.split(separator: " ").first else {
                appendStatus("Bruk: /unignore nick", kind: .error)
                return
            }
            if isIgnored(String(nickname)) { toggleIgnore(String(nickname)) }
        case "notice":
            let values = argument.split(separator: " ", maxSplits: 1)
            if values.count == 2 { sendRaw("NOTICE \(values[0]) :\(values[1])") }
        case "quit":
            intentionalDisconnect = true
            shouldReconnectAfterWake = false
            isReconnectInProgress = false
            isAutoAway = false
            isStartAway = false
            reconnectTask?.cancel()
            sendRaw("QUIT :\(argument.isEmpty ? "MacRelay avsluttes" : argument)")
            connection.disconnect(reason: "/quit")
            connectionState = .disconnected
            markAllChannelsDisconnected()
            appendStatus("Koblet fra serveren.")
            saveSessionState()
        case "raw", "quote":
            if !argument.isEmpty { sendRaw(argument) }
        case "clear":
            if let id = selectedConversationID { mutateConversation(id: id) { $0.messages.removeAll() } }
        case "server":
            if !argument.isEmpty {
                configuration.host = argument
                reconnect()
            }
        case "help":
            appendStatus("Kommandoer: /join, /part, /msg, /query, /whois, /me, /nick, /topic, /kick, /mode, /ignore, /unignore, /notice, /raw, /clear og /quit")
        default:
            appendStatus("Ukjent kommando: /\(command). Bruk /raw for å sende en IRC-kommando direkte.", kind: .error)
        }
    }

    private func sendChat(_ text: String) {
        guard connectionState == .connected else {
            appendStatus("Du må koble til en server først.", kind: .error)
            return
        }
        guard let target = selectedConversation, target.kind != .server else {
            appendStatus("Velg en kanal eller privat samtale.", kind: .error)
            return
        }
        sendMessage(text, to: target.name)
    }

    private func sendMessage(_ text: String, to target: String) {
        let id = conversationID(for: target)
        ensureConversation(id: id, name: target, kind: isChannel(target) ? .channel : .query)
        sendRaw("PRIVMSG \(target) :\(text)")
        if !enabledCapabilities.contains("echo-message") {
            appendMessage(to: id, ChatMessage(sender: currentNickname, text: text, isOwn: true))
        }
    }

    private func sendRaw(_ line: String) {
        guard connectionState != .disconnected else {
            appendStatus("Kan ikke sende kommandoen mens klienten er frakoblet.", kind: .error)
            return
        }
        connection.send(line)
    }

    private func handle(connectionState state: NWConnection.State) {
        switch state {
        case .ready:
            guard !hasSentRegistration else {
                #if DEBUG
                print("[MacRelay IRC] STATE ready gjentatt; registrering sendes ikke på nytt")
                #endif
                return
            }
            hasSentRegistration = true
            connectionState = .connecting
            appendStatus("Nettverkstilkoblingen er opprettet. Registrerer kallenavn …")
            if !ircPassword.isEmpty {
                sendRaw("PASS \(ircPassword)")
            }
            sendRaw("CAP LS 302")
            sendRaw("NICK \(configuration.nickname)")
            sendRaw("USER \(configuration.username) 0 * :\(configuration.realName)")
        case .failed(let error):
            handleUnexpectedDisconnect(connectionErrorMessage(error, waiting: false))
        case .cancelled:
            if !intentionalDisconnect && connectionState != .disconnected {
                handleUnexpectedDisconnect("Forbindelsen ble brutt.")
            }
        case .waiting(let error):
            appendStatus(connectionErrorMessage(error, waiting: true), kind: .notice)
        default:
            break
        }
    }

    private func handleUnexpectedDisconnect(_ message: String) {
        guard !intentionalDisconnect else { return }
        if connectionState == .disconnected, reconnectTask != nil { return }
        channelsToRestore.formUnion(conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name))
        connectionState = .disconnected
        isAutoAway = false
        isStartAway = false
        markAllChannelsDisconnected()
        if isSystemSleeping { return }
        appendStatus(message, kind: .error)
        scheduleReconnect()
        saveSessionState()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, !intentionalDisconnect, !isSystemSleeping else { return }
        let delays = [2, 5, 10, 20, 30, 60]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        appendStatus("Prøver å koble til igjen om \(delay) sekunder …", kind: .notice)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.intentionalDisconnect else { return }
            self.reconnectTask = nil
            self.startConnection(isReconnect: true)
        }
    }

    private func connectionErrorMessage(_ error: NWError, waiting: Bool) -> String {
        if case .tls = error, configuration.useTLS, !configuration.allowUntrustedCertificate {
            return "TLS-sertifikatet ble avvist. Kontroller serveren og aktiver «Tillat selvsignert sertifikat» bare hvis du stoler på den."
        }
        let prefix = waiting ? "Venter på nettverket" : "Tilkoblingen feilet"
        return "\(prefix): \(error.localizedDescription)"
    }

    private func handle(rawLine: String) {
        guard let message = IRCMessage.parse(rawLine) else { return }

        switch message.command {
        case "PING":
            if let token = message.parameters.last { sendRaw("PONG :\(token)") }
        case "CAP":
            handleCapabilities(message)
        case "001":
            let completedReconnect = isReconnectInProgress
            connectionState = .connected
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            isReconnectInProgress = false
            isAutoAway = false
            isStartAway = false
            currentNickname = message.parameters.first ?? configuration.nickname
            appendStatus(isConnectedViaZNC
                ? "Tilkoblet via ZNC som \(currentNickname)."
                : "Tilkoblet som \(currentNickname).")
            if !nickServPassword.isEmpty {
                sendRaw("PRIVMSG NickServ :IDENTIFY \(nickServPassword)")
                appendStatus("Sendte identifisering til NickServ.")
            }
            let channels = Set(configuration.channels).union(channelsToRestore)
            if completedReconnect { appendReconnectSeparators(for: channels) }
            channels.forEach { sendRaw("JOIN \($0)") }
            channelsToRestore.removeAll()
            updateAutoAwayState()
            if restoredSelectionID != nil {
                pendingRestoredChannelIDs = Set(channels.map { conversationID(for: $0) })
                if pendingRestoredChannelIDs.isEmpty {
                    clearRestoredSelection()
                } else {
                    scheduleRestoredSelectionCleanup()
                }
            }
            saveSessionState()
        case "433":
            if currentNickname.caseInsensitiveCompare(configuration.nickname) == .orderedSame,
               !configuration.alternateNickname.isEmpty {
                currentNickname = configuration.alternateNickname
            } else {
                currentNickname += "_"
            }
            appendStatus("Kallenavnet er opptatt. Prøver \(currentNickname) …", kind: .notice)
            sendRaw("NICK \(currentNickname)")
        case "PRIVMSG":
            handlePrivateMessage(message)
        case "NOTICE":
            handleNotice(message)
        case "JOIN":
            handleJoin(message)
        case "PART":
            handlePart(message)
        case "QUIT":
            if let nick = message.nickname { removeUser(nick, reason: "forlot serveren") }
        case "NICK":
            handleNickChange(message)
        case "353":
            handleNames(message)
        case "KICK":
            handleKick(message)
        case "MODE":
            handleMode(message)
        case "TOPIC", "332":
            handleTopic(message)
        case "331":
            if message.parameters.count > 1 {
                mutateConversation(id: conversationID(for: message.parameters[1])) { $0.topic = nil }
            }
        case "311", "312", "313", "317", "319", "330", "671", "318":
            handleWhois(message)
        default:
            if Int(message.command) != nil {
                let text = message.parameters.dropFirst().joined(separator: " ")
                if !text.isEmpty {
                    appendStatus(text, kind: message.command.first == "4" || message.command.first == "5" ? .error : .event)
                }
            }
        }
    }

    private func handlePrivateMessage(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        let sender = message.nickname ?? "?"
        guard !isIgnored(sender) else { return }
        let target = message.parameters[0]
        var text = message.parameters[1]

        if text.hasPrefix("\u{1}DCC SEND "), let offer = parseDCCOffer(text, sender: sender) {
            incomingDCCOffer = offer
            openQuery(with: sender)
            appendEvent("\(sender) tilbyr filen «\(offer.filename)» via DCC. Ingen fil mottas uten bekreftelse.", to: conversationID(for: sender))
            return
        }

        let isAction = text.hasPrefix("\u{1}ACTION ") && text.hasSuffix("\u{1}")
        if isAction { text = String(text.dropFirst(8).dropLast()) }
        let conversationName = target.caseInsensitiveCompare(currentNickname) == .orderedSame ? sender : target
        let id = conversationID(for: conversationName)
        let kind: ConversationKind = isChannel(conversationName) ? .channel : .query
        let isNewConversation = !conversations.contains(where: { $0.id == id })
        ensureConversation(id: id, name: conversationName, kind: kind)
        let isOwn = sender.caseInsensitiveCompare(currentNickname) == .orderedSame
        let mention = !isOwn && kind == .channel && containsCurrentNick(text)
        let serverTimestamp = message.serverTimestamp
        appendMessage(to: id, ChatMessage(
            timestamp: serverTimestamp ?? Date(),
            sender: sender,
            text: text,
            kind: isAction ? .action : .normal,
            isOwn: isOwn,
            isMention: mention
        ), deduplicateServerTime: serverTimestamp != nil)
        if isNewConversation { saveSessionState() }
    }

    private func handleNotice(_ message: IRCMessage) {
        let sender = message.nickname ?? message.prefix ?? "server"
        guard !isIgnored(sender) else { return }
        let text = message.parameters.last ?? ""
        let target = message.parameters.first ?? ""
        let id = target.caseInsensitiveCompare(currentNickname) == .orderedSame ? conversationID(for: sender) : serverID
        let isNewQuery = id != serverID && !conversations.contains(where: { $0.id == id })
        if id != serverID { ensureConversation(id: id, name: sender, kind: .query) }
        let serverTimestamp = message.serverTimestamp
        appendMessage(to: id, ChatMessage(
            timestamp: serverTimestamp ?? Date(),
            sender: sender,
            text: text,
            kind: .notice
        ), deduplicateServerTime: serverTimestamp != nil)
        if isNewQuery { saveSessionState() }
    }

    private func handleCapabilities(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        switch message.parameters[1].uppercased() {
        case "LS":
            if let capabilities = message.parameters.last {
                advertisedCapabilities.formUnion(
                    capabilities.split(separator: " ").map(capabilityName)
                )
            }
            let hasMore = message.parameters.count >= 4 && message.parameters[2] == "*"
            guard !hasMore else { return }

            isConnectedViaZNC = advertisedCapabilities.contains { $0.hasPrefix("znc.in/") }
            var requestedCapabilities: [String] = []
            if advertisedCapabilities.contains("server-time") {
                requestedCapabilities.append("server-time")
            } else if isConnectedViaZNC,
                      advertisedCapabilities.contains("znc.in/server-time-iso") {
                requestedCapabilities.append("znc.in/server-time-iso")
            }
            if isConnectedViaZNC {
                requestedCapabilities.append(contentsOf: [
                    "echo-message",
                    "znc.in/self-message"
                ])
            }
            let supportedCapabilities = requestedCapabilities.filter(advertisedCapabilities.contains)
            if supportedCapabilities.isEmpty {
                sendRaw("CAP END")
            } else {
                sendRaw("CAP REQ :\(supportedCapabilities.joined(separator: " "))")
            }
        case "ACK":
            if let capabilities = message.parameters.last {
                enabledCapabilities.formUnion(
                    capabilities.split(separator: " ").map(capabilityName)
                )
            }
            sendRaw("CAP END")
        case "NAK":
            sendRaw("CAP END")
        default:
            break
        }
    }

    private func capabilityName(_ token: Substring) -> String {
        let value = token.drop(while: { $0 == "-" || $0 == "~" || $0 == "=" })
        return value.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
    }

    private func handleJoin(_ message: IRCMessage) {
        guard let nick = message.nickname, let channel = message.parameters.first else { return }
        let id = conversationID(for: channel)
        ensureConversation(id: id, name: channel, kind: .channel)
        if nick.caseInsensitiveCompare(currentNickname) == .orderedSame {
            mutateConversation(id: id) { $0.isJoined = true }
            appendEvent("Du ble med i \(channel).", to: id)
            if restoredSelectionID == nil {
                selectConversation(id)
            } else {
                pendingRestoredChannelIDs.remove(id)
                if pendingRestoredChannelIDs.isEmpty { clearRestoredSelection() }
                saveSessionState()
            }
        } else {
            addUser(IRCUser(nickname: nick, prefix: nil), to: id)
            appendEvent("\(nick) ble med i kanalen.", to: id)
        }
    }

    private func handlePart(_ message: IRCMessage) {
        guard let nick = message.nickname, let channel = message.parameters.first else { return }
        let id = conversationID(for: channel)
        let reason = message.parameters.count > 1 ? ": \(message.parameters[1])" : ""
        if nick.caseInsensitiveCompare(currentNickname) == .orderedSame {
            mutateConversation(id: id) {
                $0.isJoined = false
                $0.users.removeAll()
            }
            channelsToRestore = Set(channelsToRestore.filter {
                $0.caseInsensitiveCompare(channel) != .orderedSame
            })
            appendEvent("Du forlot \(channel)\(reason).", to: id)
            saveSessionState()
        } else {
            removeUser(nick, from: id)
            appendEvent("\(nick) forlot kanalen\(reason).", to: id)
        }
    }

    private func handleNickChange(_ message: IRCMessage) {
        guard let oldNick = message.nickname, let newNick = message.parameters.first else { return }
        if oldNick.caseInsensitiveCompare(currentNickname) == .orderedSame { currentNickname = newNick }
        for index in conversations.indices where conversations[index].kind == .channel {
            if let userIndex = conversations[index].users.firstIndex(where: { $0.nickname.caseInsensitiveCompare(oldNick) == .orderedSame }) {
                let prefix = conversations[index].users[userIndex].prefix
                conversations[index].users[userIndex] = IRCUser(nickname: newNick, prefix: prefix)
                conversations[index].users.sort(by: userSort)
                let event = ChatMessage(text: "\(oldNick) heter nå \(newNick).", kind: .event)
                conversations[index].messages.append(event)
                log(event, conversationName: conversations[index].name)
            }
        }
    }

    private func handleNames(_ message: IRCMessage) {
        guard message.parameters.count >= 4 else { return }
        let channel = message.parameters[2]
        let id = conversationID(for: channel)
        ensureConversation(id: id, name: channel, kind: .channel)
        let users = message.parameters[3].split(separator: " ").map { token -> IRCUser in
            let value = String(token)
            if let first = value.first, "~&@%+".contains(first) {
                return IRCUser(nickname: String(value.dropFirst()), prefix: first)
            }
            return IRCUser(nickname: value, prefix: nil)
        }
        mutateConversation(id: id) { conversation in
            for user in users {
                if let index = conversation.users.firstIndex(where: { $0.nickname.caseInsensitiveCompare(user.nickname) == .orderedSame }) {
                    if conversation.users[index].prefix == nil { conversation.users[index] = user }
                } else {
                    conversation.users.append(user)
                }
            }
            conversation.users.sort(by: userSort)
        }
    }

    private func handleKick(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        let channel = message.parameters[0]
        let nickname = message.parameters[1]
        let reason = message.parameters.count > 2 ? message.parameters[2] : "ingen grunn oppgitt"
        let id = conversationID(for: channel)
        removeUser(nickname, from: id)
        if nickname.caseInsensitiveCompare(currentNickname) == .orderedSame {
            mutateConversation(id: id) { $0.isJoined = false }
            saveSessionState()
        }
        appendEvent("\(nickname) ble kastet ut av \(message.nickname ?? "serveren"): \(reason)", to: id)
    }

    private func handleMode(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        let target = message.parameters[0]
        let mode = message.parameters[1]
        let arguments = Array(message.parameters.dropFirst(2))
        guard isChannel(target) else {
            appendStatus("Modus for \(target): \(mode) \(arguments.joined(separator: " "))")
            return
        }

        var adding = true
        var argumentIndex = 0
        for character in mode {
            if character == "+" { adding = true; continue }
            if character == "-" { adding = false; continue }
            guard "ovhqa".contains(character), argumentIndex < arguments.count else { continue }
            let nickname = arguments[argumentIndex]
            argumentIndex += 1
            updatePrefix(for: nickname, in: conversationID(for: target), mode: character, adding: adding)
        }
        let setter = message.nickname ?? "serveren"
        appendEvent("\(setter) satte modus \(mode) \(arguments.joined(separator: " ")).", to: conversationID(for: target))
    }

    private func handleTopic(_ message: IRCMessage) {
        let channel = message.command == "TOPIC" ? message.parameters.first : message.parameters.dropFirst().first
        guard let channel, let topic = message.parameters.last else { return }
        let id = conversationID(for: channel)
        mutateConversation(id: id) { $0.topic = topic }
        appendEvent("Emne: \(topic)", to: id)
    }

    private func handleWhois(_ message: IRCMessage) {
        guard message.parameters.count > 1 else { return }
        let nickname = message.parameters[1]
        let id = conversationID(for: nickname)
        ensureConversation(id: id, name: nickname, kind: .query)
        let text: String
        switch message.command {
        case "311" where message.parameters.count >= 6:
            text = "WHOIS: \(nickname) er \(message.parameters[2])@\(message.parameters[3]) — \(message.parameters[5])"
        case "312" where message.parameters.count >= 4:
            text = "Server: \(message.parameters[2]) — \(message.parameters[3])"
        case "313": text = "\(nickname) er IRC-operator."
        case "317" where message.parameters.count >= 3: text = "Inaktiv i \(message.parameters[2]) sekunder."
        case "319": text = "Kanaler: \(message.parameters.dropFirst(2).joined(separator: " "))"
        case "330" where message.parameters.count >= 3: text = "Innlogget som \(message.parameters[2])."
        case "671": text = "Bruker en sikker tilkobling."
        case "318": text = "Slutt på WHOIS."
        default: text = message.parameters.dropFirst(2).joined(separator: " ")
        }
        appendEvent(text, to: id)
    }

    private func ensureConversation(id: String, name: String, kind: ConversationKind) {
        guard !conversations.contains(where: { $0.id == id }) else { return }
        var conversation = Conversation(id: id, name: name, kind: kind)
        if kind == .channel {
            let history = logManager.recentMessages(
                serverName: configuration.name,
                conversationName: name
            )
            if !history.isEmpty {
                conversation.messages = history
                conversation.messages.append(ChatMessage(text: "──── Ny økt ────", kind: .event))
            }
        }
        conversations.append(conversation)
    }

    private func mutateConversation(id: String, change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
    }

    private func appendStatus(_ text: String, kind: MessageKind = .event) {
        appendMessage(to: serverID, ChatMessage(text: text, kind: kind))
    }

    private func appendEvent(_ text: String, to id: String) {
        appendMessage(to: id, ChatMessage(text: text, kind: .event))
    }

    private func appendLocalEvent(_ text: String, to id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(ChatMessage(text: text, kind: .event))
        if conversations[index].messages.count > 2_000 { conversations[index].messages.removeFirst(200) }
    }

    private func appendReconnectSeparators(for channels: Set<String>) {
        let channelIDs = Set(channels.map { conversationID(for: $0) })
        let conversationIDs = conversations
            .filter { $0.kind == .channel && channelIDs.contains($0.id) }
            .map(\.id)
        for id in conversationIDs {
            appendLocalEvent("──── Reconnect ────", to: id)
        }
    }

    private func appendMessage(to id: String, _ message: ChatMessage, deduplicateServerTime: Bool = false) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if deduplicateServerTime, isDuplicateServerTimeMessage(message, in: conversations[index]) { return }
        conversations[index].messages.append(message)
        if conversations[index].messages.count > 2_000 { conversations[index].messages.removeFirst(200) }
        if selectedConversationID != id, !message.isOwn {
            conversations[index].unreadCount += 1
            if message.isMention { conversations[index].mentionCount += 1 }
        }
        log(message, conversationName: conversations[index].name)

        if message.isMention, configuration.notifyOnMention, selectedConversationID != id {
            let content = UNMutableNotificationContent()
            content.title = conversations[index].name
            content.body = message.sender.map { "\($0): \(message.text)" } ?? message.text
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil))
        }

        if configuration.playNotificationSounds,
           !message.isOwn,
           message.sender != nil,
           selectedConversationID != id,
           (message.isMention || conversations[index].kind == .query) {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    private func isDuplicateServerTimeMessage(_ message: ChatMessage, in conversation: Conversation) -> Bool {
        func matches(_ existing: ChatMessage, tolerance: TimeInterval) -> Bool {
            let sameSender: Bool
            switch (existing.sender, message.sender) {
            case let (lhs?, rhs?):
                sameSender = lhs.caseInsensitiveCompare(rhs) == .orderedSame
            case (nil, nil):
                sameSender = true
            default:
                sameSender = false
            }
            return sameSender
                && existing.text == message.text
                && existing.kind == message.kind
                && abs(existing.timestamp.timeIntervalSince(message.timestamp)) < tolerance
        }

        if conversation.messages.suffix(300).contains(where: { matches($0, tolerance: 0.001) }) {
            return true
        }

        guard let separatorIndex = conversation.messages.firstIndex(where: {
            $0.sender == nil && $0.text == "──── Ny økt ────"
        }) else { return false }
        return conversation.messages[..<separatorIndex].suffix(300).contains {
            matches($0, tolerance: 1.0)
        }
    }

    private func log(_ message: ChatMessage, conversationName: String) {
        guard configuration.loggingEnabled else { return }
        logManager.append(message, serverName: configuration.name, conversationName: conversationName)
    }

    private func addUser(_ user: IRCUser, to id: String) {
        mutateConversation(id: id) { conversation in
            guard !conversation.users.contains(where: { $0.nickname.caseInsensitiveCompare(user.nickname) == .orderedSame }) else { return }
            conversation.users.append(user)
            conversation.users.sort(by: userSort)
        }
    }

    private func removeUser(_ nickname: String, from id: String) {
        mutateConversation(id: id) { $0.users.removeAll { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame } }
    }

    private func removeUser(_ nickname: String, reason: String) {
        for index in conversations.indices where conversations[index].kind == .channel {
            if conversations[index].users.contains(where: { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame }) {
                conversations[index].users.removeAll { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame }
                let event = ChatMessage(text: "\(nickname) \(reason).", kind: .event)
                conversations[index].messages.append(event)
                log(event, conversationName: conversations[index].name)
            }
        }
    }

    private func updatePrefix(for nickname: String, in id: String, mode: Character, adding: Bool) {
        let prefixMap: [Character: Character] = ["q": "~", "a": "&", "o": "@", "h": "%", "v": "+"]
        guard let prefix = prefixMap[mode] else { return }
        mutateConversation(id: id) { conversation in
            guard let index = conversation.users.firstIndex(where: { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame }) else { return }
            let current = conversation.users[index]
            conversation.users[index] = IRCUser(nickname: current.nickname, prefix: adding ? prefix : (current.prefix == prefix ? nil : current.prefix))
            conversation.users.sort(by: userSort)
        }
    }

    private func restoreWorkspace(from session: PersistedIRCSession) {
        for channel in session.openChannels {
            ensureConversation(id: conversationID(for: channel), name: channel, kind: .channel)
        }
        for nickname in session.openQueries {
            ensureConversation(id: conversationID(for: nickname), name: nickname, kind: .query)
        }

        channelsToRestore = Set(session.joinedChannels)
        if let selectedID = session.selectedConversationID,
           conversations.contains(where: { $0.id == selectedID }) {
            selectedConversationID = selectedID
            restoredSelectionID = selectedID
        }
    }

    private func saveSessionState() {
        let openChannels = conversations
            .filter { $0.kind == .channel }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let joinedChannels = Set(
            conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name)
        )
        .union(channelsToRestore)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let openQueries = conversations
            .filter { $0.kind == .query }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let shouldConnect = !intentionalDisconnect
            && (connectionState != .disconnected || reconnectTask != nil || shouldReconnectAfterWake)
        let session = PersistedIRCSession(
            profileID: configuration.id,
            openChannels: openChannels,
            joinedChannels: joinedChannels,
            openQueries: openQueries,
            selectedConversationID: selectedConversationID,
            shouldConnect: shouldConnect
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    private func scheduleRestoredSelectionCleanup() {
        restoreSelectionTask?.cancel()
        restoreSelectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearRestoredSelection()
        }
    }

    private func clearRestoredSelection() {
        restoreSelectionTask?.cancel()
        restoreSelectionTask = nil
        restoredSelectionID = nil
        pendingRestoredChannelIDs.removeAll()
    }

    private func handleSystemSleep() {
        guard !isSystemSleeping else { return }
        isSystemSleeping = true
        shouldReconnectAfterWake = !intentionalDisconnect
            && (connectionState != .disconnected || reconnectTask != nil)
        if shouldReconnectAfterWake {
            channelsToRestore.formUnion(
                conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name)
            )
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        saveSessionState()
    }

    private func handleSystemWake() {
        guard isSystemSleeping else { return }
        isSystemSleeping = false
        guard shouldReconnectAfterWake, !intentionalDisconnect else {
            shouldReconnectAfterWake = false
            return
        }

        shouldReconnectAfterWake = false
        channelsToRestore.formUnion(
            conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name)
        )
        reconnectTask?.cancel()
        reconnectTask = nil
        connection.disconnect(reason: "reconnect etter wake")
        connectionState = .disconnected
        isAutoAway = false
        isStartAway = false
        reconnectAttempt = 0
        markAllChannelsDisconnected()
        appendStatus("Tilkoblingen ble brutt under dvale. Kobler til igjen …", kind: .notice)
        scheduleReconnect()
        saveSessionState()
    }

    private func startIdleMonitor() {
        idleMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.updateAutoAwayState()
            }
        }
    }

    private func updateAutoAwayState() {
        guard !isSystemSleeping, connectionState == .connected else {
            if connectionState != .connected {
                isAutoAway = false
                isStartAway = false
            }
            return
        }

        guard !isManuallyAway else { return }

        if configuration.startAwayOnConnect {
            if !isStartAway {
                if !isAutoAway {
                    connection.send("AWAY :\(configuration.autoAwayMessage)")
                }
                isAutoAway = false
                isStartAway = true
            }
            return
        }

        if isStartAway {
            clearAwayStatus()
        }

        guard configuration.autoAwayEnabled else {
            if isAutoAway {
                clearAwayStatus()
            }
            return
        }

        guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        guard idleSeconds.isFinite, idleSeconds >= 0 else { return }
        let threshold = Double(configuration.autoAwayMinutes * 60)

        if idleSeconds >= threshold, !isAutoAway {
            connection.send("AWAY :\(configuration.autoAwayMessage)")
            isAutoAway = true
        } else if idleSeconds < threshold, isAutoAway {
            clearAwayStatus()
        }
    }

    private func clearAwayStatus() {
        connection.send("AWAY")
        isAutoAway = false
        isStartAway = false
        appendStatus("Du er ikke lenger markert som away.", kind: .notice)
    }

    private func markAllChannelsDisconnected() {
        isManuallyAway = false
        for index in conversations.indices where conversations[index].kind == .channel {
            conversations[index].isJoined = false
            conversations[index].users.removeAll()
        }
    }

    private func containsCurrentNick(_ text: String) -> Bool {
        guard !currentNickname.isEmpty else { return false }
        return text.range(of: currentNickname, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func parseDCCOffer(_ text: String, sender: String) -> DCCOffer? {
        let content = String(text.dropFirst().dropLast())
        let tokens = quotedTokens(content)
        guard tokens.count >= 5, tokens[0].uppercased() == "DCC", tokens[1].uppercased() == "SEND",
              let port = UInt16(tokens[4]), port > 0 else { return nil }
        let filename = tokens[2]
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        guard filename == safeName, safeName != ".", safeName != "..", !safeName.isEmpty else { return nil }
        let size = tokens.count > 5 ? Int64(tokens[5]) : nil
        return DCCOffer(sender: sender, filename: safeName, size: size, address: tokens[3], port: port)
    }

    private func quotedTokens(_ value: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quoted = false
        for character in value {
            if character == "\"" { quoted.toggle(); continue }
            if character == " ", !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private func conversationID(for name: String) -> String { name.lowercased() }
    private func isChannel(_ name: String) -> Bool { name.hasPrefix("#") || name.hasPrefix("&") }

    private func userSort(_ lhs: IRCUser, _ rhs: IRCUser) -> Bool {
        func rank(_ prefix: Character?) -> Int {
            switch prefix {
            case "@": 0
            case "+": 1
            default: 2
            }
        }
        let leftRank = rank(lhs.prefix)
        let rightRank = rank(rhs.prefix)
        return leftRank == rightRank
            ? lhs.nickname.localizedCaseInsensitiveCompare(rhs.nickname) == .orderedAscending
            : leftRank < rightRank
    }
}
