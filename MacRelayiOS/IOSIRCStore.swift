import Combine
import Foundation
import MacRelayCore
import Network

private struct IOSSession: Codable {
    var profileID: UUID
    var openChannels: [String]
    var joinedChannels: [String]?
    var openQueries: [String]
    var selectedConversationID: String?
    var shouldReconnect: Bool
}

@MainActor
final class IOSIRCStore: ObservableObject {
    @Published var profiles: [ServerConfiguration]
    @Published var configuration: ServerConfiguration
    @Published var connectionState: ConnectionState = .disconnected
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: String?
    @Published var inputText = ""
    @Published var ircPassword = ""
    @Published var nickServPassword = ""
    @Published var showingSettings = false
    @Published var showingJoin = false
    @Published var joinChannelText = ""
    @Published private(set) var isConnectedViaZNC = false

    private let connection = IRCConnection()
    private let profilesKey = "MacRelay.iOS.serverProfiles.v1"
    private let selectedProfileKey = "MacRelay.iOS.selectedProfile.v1"
    private let sessionKey = "MacRelay.iOS.session.v1"
    private static let nickServService = "no.varion.MacRelay.NickServ"
    private static let ircPassService = "no.varion.MacRelay.IRCPass"
    private var currentNickname = ""
    private var enabledCapabilities: Set<String> = []
    private var advertisedCapabilities: Set<String> = []
    private var playbackBatches: [String: (conversationID: String, separatorText: String, historyCount: Int)] = [:]
    private var hasSentRegistration = false
    private var intentionalDisconnect = false
    private var appIsActive = true
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnectInForeground = false
    private var channelsToRestore: Set<String> = []
    private var restoredSelectionID: String?
    private var pendingRestoredChannelIDs: Set<String> = []
    private var restoreSelectionTask: Task<Void, Never>?
    private var seenMessageIDs: Set<String> = []
    private var seenMessageIDOrder: [String] = []
    private var historyCache: [String: [ChatMessage]] = [:]
    private var loadedHistoryIDs: Set<String> = []
    private var iCloudObserver: NSObjectProtocol?

    var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var serverID: String { "server:\(configuration.id.uuidString.lowercased())" }

    init() {
        let defaults = UserDefaults.standard
        ICloudProfileStore.synchronize()
        let cloudProfiles = ICloudProfileStore.load()
        let decodedProfiles = defaults.data(forKey: profilesKey)
            .flatMap { try? JSONDecoder().decode([ServerConfiguration].self, from: $0) }
        let savedProfiles: [ServerConfiguration]
        if let cloudProfiles {
            savedProfiles = cloudProfiles.profiles
        } else if let decodedProfiles, !decodedProfiles.isEmpty {
            savedProfiles = decodedProfiles.map(Self.removingBundledTemplateValues)
        } else {
            savedProfiles = [Self.makeEmptyProfile()]
        }
        profiles = savedProfiles
        let selectedID = cloudProfiles?.selectedProfileID
            ?? defaults.string(forKey: selectedProfileKey).flatMap(UUID.init(uuidString:))
        configuration = savedProfiles.first { $0.id == selectedID } ?? savedProfiles[0]
        ircPassword = KeychainStore.read(service: Self.ircPassService, account: configuration.id.uuidString)
        nickServPassword = KeychainStore.read(service: Self.nickServService, account: configuration.id.uuidString)
        historyCache = Self.readHistory(profileID: configuration.id)

        ensureConversation(id: serverID, name: configuration.name, kind: .server)
        selectedConversationID = serverID
        restoreSession()

        connection.onLine = { [weak self] line in
            Task { @MainActor in self?.handle(rawLine: line) }
        }
        connection.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handle(connectionState: state) }
        }
        connection.onUnexpectedClose = { [weak self] in
            Task { @MainActor in self?.handleUnexpectedDisconnect("Forbindelsen ble lukket.") }
        }
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.importProfilesFromICloud() }
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            ICloudProfileStore.synchronize()
            self?.importProfilesFromICloud()
        }
    }

    deinit {
        reconnectTask?.cancel()
        restoreSelectionTask?.cancel()
        if let iCloudObserver { NotificationCenter.default.removeObserver(iCloudObserver) }
    }

    func connect() {
        guard appIsActive, connectionState == .disconnected, !configuration.host.isEmpty else { return }
        saveProfile()
        intentionalDisconnect = false
        shouldReconnectInForeground = true
        currentNickname = configuration.nickname
        hasSentRegistration = false
        enabledCapabilities.removeAll()
        advertisedCapabilities.removeAll()
        playbackBatches.removeAll()
        isConnectedViaZNC = false
        connectionState = .connecting
        appendStatus("Kobler til \(configuration.host):\(configuration.port) …")
        connection.connect(
            host: configuration.host,
            port: configuration.port,
            useTLS: configuration.useTLS,
            allowUntrustedCertificate: configuration.allowUntrustedCertificate
        )
        saveSession()
    }

    func disconnect() {
        intentionalDisconnect = true
        shouldReconnectInForeground = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        if connectionState == .connected { connection.send("QUIT :MacRelay for iOS avsluttes") }
        connection.disconnect(reason: "manuell disconnect")
        connectionState = .disconnected
        markChannelsDisconnected()
        appendStatus("Koblet fra serveren.")
        saveSession()
    }

    func handleAppBecameActive(_ active: Bool) {
        appIsActive = active
        if active {
            ICloudProfileStore.synchronize()
            importProfilesFromICloud()
            if shouldReconnectInForeground, connectionState == .disconnected { scheduleReconnect(immediate: true) }
        } else {
            let shouldResume = connectionState != .disconnected || reconnectTask != nil
            reconnectTask?.cancel()
            reconnectTask = nil
            if connectionState != .disconnected {
                connection.disconnect(reason: "appen gikk i bakgrunnen")
                connectionState = .disconnected
                markChannelsDisconnected()
            }
            shouldReconnectInForeground = shouldReconnectInForeground || shouldResume
            saveSession()
        }
    }

    func selectConversation(_ id: String) {
        selectedConversationID = id
        mutateConversation(id) {
            $0.unreadCount = 0
            $0.mentionCount = 0
        }
        saveSession()
    }

    func joinChannel() {
        var name = joinChannelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !isChannel(name) { name = "#" + name }
        ensureConversation(id: conversationID(name), name: name, kind: .channel)
        sendRaw("JOIN \(name)")
        joinChannelText = ""
        showingJoin = false
    }

    func openQuery(_ nickname: String) {
        let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let id = conversationID(clean)
        ensureConversation(id: id, name: clean, kind: .query)
        selectConversation(id)
    }

    func sendInput() {
        let text = inputText.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        inputText = ""
        execute(text)
    }

    func addProfile() {
        let profile = Self.makeEmptyProfile()
        profiles.append(profile)
        switchProfile(profile.id)
        showingSettings = true
    }

    func deleteCurrentProfile() {
        guard profiles.count > 1 else { return }
        disconnect()
        let oldID = configuration.id
        profiles.removeAll { $0.id == oldID }
        KeychainStore.write("", service: Self.ircPassService, account: oldID.uuidString)
        KeychainStore.write("", service: Self.nickServService, account: oldID.uuidString)
        configuration = profiles[0]
        loadCredentials()
        loadHistoryForCurrentProfile()
        resetWorkspace()
        persistProfiles()
    }

    func switchProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), profile.id != configuration.id else { return }
        disconnect()
        configuration = profile
        loadCredentials()
        loadHistoryForCurrentProfile()
        resetWorkspace()
        UserDefaults.standard.set(profile.id.uuidString, forKey: selectedProfileKey)
    }

    func saveProfile() {
        if let index = profiles.firstIndex(where: { $0.id == configuration.id }) {
            profiles[index] = configuration
        } else {
            profiles.append(configuration)
        }
        persistProfiles()
        KeychainStore.write(ircPassword, service: Self.ircPassService, account: configuration.id.uuidString)
        KeychainStore.write(nickServPassword, service: Self.nickServService, account: configuration.id.uuidString)
        UserDefaults.standard.set(configuration.id.uuidString, forKey: selectedProfileKey)
        if let serverIndex = conversations.firstIndex(where: { $0.id == serverID }) {
            conversations[serverIndex].name = configuration.name
        }
    }

    private func resetWorkspace() {
        clearRestoredSelection()
        conversations.removeAll()
        ensureConversation(id: serverID, name: configuration.name, kind: .server)
        selectedConversationID = serverID
        shouldReconnectInForeground = false
        saveSession()
    }

    private func loadCredentials() {
        ircPassword = KeychainStore.read(service: Self.ircPassService, account: configuration.id.uuidString)
        nickServPassword = KeychainStore.read(service: Self.nickServService, account: configuration.id.uuidString)
    }

    private func importProfilesFromICloud() {
        guard connectionState == .disconnected,
              let payload = ICloudProfileStore.load(),
              !payload.profiles.isEmpty
        else { return }

        let selectedID = payload.selectedProfileID ?? configuration.id
        let selectedProfile = payload.profiles.first { $0.id == selectedID }
            ?? payload.profiles.first { $0.id == configuration.id }
            ?? payload.profiles[0]
        let profileChanged = configuration != selectedProfile
        let listChanged = profiles != payload.profiles
        guard profileChanged || listChanged else {
            loadCredentials()
            return
        }

        profiles = payload.profiles
        configuration = selectedProfile
        persistProfiles()
        UserDefaults.standard.set(selectedProfile.id.uuidString, forKey: selectedProfileKey)
        loadCredentials()
        loadHistoryForCurrentProfile()
        resetWorkspace()
    }

    private static func makeEmptyProfile(id: UUID = UUID()) -> ServerConfiguration {
        var profile = ServerConfiguration()
        profile.id = id
        profile.name = "Ny server"
        profile.host = ""
        profile.nickname = ""
        profile.alternateNickname = ""
        profile.username = ""
        profile.realName = ""
        profile.autoJoinChannels = ""
        return profile
    }

    private static func removingBundledTemplateValues(_ profile: ServerConfiguration) -> ServerConfiguration {
        var cleaned = profile
        if cleaned.name == "Libera Chat" { cleaned.name = "Ny server" }
        if cleaned.host == "irc.libera.chat" { cleaned.host = "" }
        if cleaned.nickname == "MacRelayUser" { cleaned.nickname = "" }
        if cleaned.alternateNickname == "MacRelayUser_" { cleaned.alternateNickname = "" }
        if cleaned.username == "macrelay" { cleaned.username = "" }
        if cleaned.realName == "MacRelay for iOS" || cleaned.realName == "MacRelay for macOS" {
            cleaned.realName = ""
        }
        if cleaned.autoJoinChannels == "#macrelay" { cleaned.autoJoinChannels = "" }
        return cleaned
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    private func handle(connectionState state: NWConnection.State) {
        switch state {
        case .ready:
            guard !hasSentRegistration else { return }
            hasSentRegistration = true
            if !ircPassword.isEmpty { connection.send("PASS \(ircPassword)") }
            connection.send("CAP LS 302")
            connection.send("NICK \(configuration.nickname)")
            connection.send("USER \(configuration.username) 0 * :\(configuration.realName)")
        case .failed(let error):
            handleUnexpectedDisconnect("Tilkoblingen feilet: \(error.localizedDescription)")
        case .cancelled:
            if !intentionalDisconnect && appIsActive && connectionState != .disconnected {
                handleUnexpectedDisconnect("Forbindelsen ble brutt.")
            }
        case .waiting(let error):
            appendStatus("Venter på nettverket: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func handleUnexpectedDisconnect(_ text: String) {
        guard !intentionalDisconnect else { return }
        connection.disconnect(reason: "uventet disconnect")
        let wasConnected = connectionState == .connected
        connectionState = .disconnected
        markChannelsDisconnected()
        shouldReconnectInForeground = true
        appendStatus(text)
        if wasConnected { channelsToRestore.formUnion(conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name)) }
        scheduleReconnect(immediate: false)
        saveSession()
    }

    private func scheduleReconnect(immediate: Bool) {
        guard appIsActive, shouldReconnectInForeground, reconnectTask == nil else { return }
        let delay = immediate ? 0.15 : min(pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func handle(rawLine: String) {
        guard let message = IRCMessage.parse(rawLine) else { return }
        if isPlaybackStateEvent(message) { return }
        switch message.command {
        case "PING":
            if let token = message.parameters.last { connection.send("PONG :\(token)") }
        case "CAP": handleCapabilities(message)
        case "BATCH": handleBatch(message)
        case "001": handleWelcome(message)
        case "433":
            currentNickname = currentNickname.caseInsensitiveCompare(configuration.nickname) == .orderedSame
                ? configuration.alternateNickname : currentNickname + "_"
            sendRaw("NICK \(currentNickname)")
        case "PRIVMSG": handlePrivateMessage(message)
        case "NOTICE": handleNotice(message)
        case "JOIN": handleJoin(message)
        case "PART": handlePart(message)
        case "QUIT": if let nick = message.nickname { removeUser(nick) }
        case "NICK": handleNick(message)
        case "353": handleNames(message)
        case "KICK": handleKick(message)
        case "MODE": handleMode(message)
        case "TOPIC", "332": handleTopic(message)
        case "331":
            if message.parameters.count > 1 { mutateConversation(conversationID(message.parameters[1])) { $0.topic = nil } }
        default:
            if Int(message.command) != nil {
                let text = message.parameters.dropFirst().joined(separator: " ")
                if !text.isEmpty { appendStatus(text) }
            }
        }
    }

    private func handleWelcome(_ message: IRCMessage) {
        connectionState = .connected
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        currentNickname = message.parameters.first ?? configuration.nickname
        appendStatus(isConnectedViaZNC ? "Tilkoblet via ZNC som \(currentNickname)." : "Tilkoblet som \(currentNickname).")
        if !nickServPassword.isEmpty { sendRaw("PRIVMSG NickServ :IDENTIFY \(nickServPassword)") }
        let channels = Set(configuration.channels).union(channelsToRestore)
        channels.forEach { sendRaw("JOIN \($0)") }
        if restoredSelectionID != nil {
            pendingRestoredChannelIDs = Set(channels.map(conversationID))
            if pendingRestoredChannelIDs.isEmpty {
                clearRestoredSelection()
            } else {
                scheduleRestoredSelectionCleanup()
            }
        }
        shouldReconnectInForeground = true
        saveSession()
    }

    private func handleCapabilities(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        switch message.parameters[1].uppercased() {
        case "LS":
            if let value = message.parameters.last {
                advertisedCapabilities.formUnion(value.split(separator: " ").map(capabilityName))
            }
            let hasMore = message.parameters.count >= 4 && message.parameters[2] == "*"
            guard !hasMore else { return }
            isConnectedViaZNC = advertisedCapabilities.contains { $0.hasPrefix("znc.in/") }
            var wanted = ["server-time", "message-tags", "batch"]
            if !advertisedCapabilities.contains("server-time"), isConnectedViaZNC {
                wanted.append("znc.in/server-time-iso")
            }
            if isConnectedViaZNC { wanted.append(contentsOf: ["echo-message", "znc.in/self-message"]) }
            let supported = wanted.filter(advertisedCapabilities.contains)
            supported.isEmpty ? connection.send("CAP END") : connection.send("CAP REQ :\(supported.joined(separator: " "))")
        case "ACK":
            if let value = message.parameters.last {
                enabledCapabilities.formUnion(value.split(separator: " ").map(capabilityName))
            }
            connection.send("CAP END")
        case "NAK": connection.send("CAP END")
        default: break
        }
    }

    private func handleBatch(_ message: IRCMessage) {
        guard let batchToken = message.parameters.first else { return }
        if batchToken.hasPrefix("+"),
           message.parameters.count >= 3,
           message.parameters[1].caseInsensitiveCompare("znc.in/playback") == .orderedSame {
            let batchID = String(batchToken.dropFirst())
            let target = message.parameters[2]
            let conversationID = self.conversationID(target)
            ensureConversation(
                id: conversationID,
                name: target,
                kind: isChannel(target) ? .channel : .query
            )
            var separatorText = "──── Live ────"
            mutateConversation(conversationID) { conversation in
                if let last = conversation.messages.last,
                   last.sender == nil,
                   (last.text == "──── Live ────" || last.text == "──── Reconnect ────") {
                    separatorText = last.text
                    conversation.messages.removeLast()
                }
            }
            let historyCount = conversations.first(where: { $0.id == conversationID })?.messages.count ?? 0
            playbackBatches[batchID] = (conversationID, separatorText, historyCount)
        } else if batchToken.hasPrefix("-") {
            let batchID = String(batchToken.dropFirst())
            guard let playback = playbackBatches.removeValue(forKey: batchID) else { return }
            mutateConversation(playback.conversationID) { conversation in
                conversation.messages = conversation.messages.enumerated().sorted {
                    if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
                    return $0.element.timestamp < $1.element.timestamp
                }.map(\.element)
                conversation.messages.append(ChatMessage(text: playback.separatorText, kind: .event))
            }
            persistHistory(for: playback.conversationID)
        }
    }

    private func handlePrivateMessage(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        let sender = message.nickname ?? "?"
        let target = message.parameters[0]
        var text = message.parameters[1]
        let isAction = text.hasPrefix("\u{1}ACTION ") && text.hasSuffix("\u{1}")
        if isAction { text = String(text.dropFirst(8).dropLast()) }
        let conversationName = target.caseInsensitiveCompare(currentNickname) == .orderedSame ? sender : target
        let id = conversationID(conversationName)
        let kind: ConversationKind = isChannel(conversationName) ? .channel : .query
        ensureConversation(id: id, name: conversationName, kind: kind)
        let isOwn = sender.caseInsensitiveCompare(currentNickname) == .orderedSame
        appendMessage(to: id, message: ChatMessage(
            timestamp: message.serverTimestamp ?? Date(),
            sender: sender,
            text: text,
            kind: isAction ? .action : .normal,
            isOwn: isOwn,
            isMention: !isOwn && kind == .channel && containsCurrentNick(text)
        ), source: message)
        saveSession()
    }

    private func handleNotice(_ message: IRCMessage) {
        let sender = message.nickname ?? message.prefix ?? "server"
        let target = message.parameters.first ?? ""
        let id = target.caseInsensitiveCompare(currentNickname) == .orderedSame ? conversationID(sender) : serverID
        if id != serverID { ensureConversation(id: id, name: sender, kind: .query) }
        appendMessage(to: id, message: ChatMessage(
            timestamp: message.serverTimestamp ?? Date(), sender: sender,
            text: message.parameters.last ?? "", kind: .notice
        ), source: message)
    }

    private func handleJoin(_ message: IRCMessage) {
        guard let nick = message.nickname, let channel = message.parameters.first else { return }
        let id = conversationID(channel)
        ensureConversation(id: id, name: channel, kind: .channel)
        if nick.caseInsensitiveCompare(currentNickname) == .orderedSame {
            mutateConversation(id) { $0.isJoined = true }
            channelsToRestore = Set(channelsToRestore.filter {
                $0.caseInsensitiveCompare(channel) != .orderedSame
            })
            if restoredSelectionID == nil {
                selectConversation(id)
            } else {
                pendingRestoredChannelIDs.remove(id)
                if pendingRestoredChannelIDs.isEmpty { clearRestoredSelection() }
                saveSession()
            }
        } else {
            addUser(IRCUser(nickname: nick), to: id)
        }
        saveSession()
    }

    private func handlePart(_ message: IRCMessage) {
        guard let nick = message.nickname, let channel = message.parameters.first else { return }
        let id = conversationID(channel)
        if nick.caseInsensitiveCompare(currentNickname) == .orderedSame {
            mutateConversation(id) { $0.isJoined = false; $0.users.removeAll() }
            channelsToRestore = Set(channelsToRestore.filter {
                $0.caseInsensitiveCompare(channel) != .orderedSame
            })
            saveSession()
        } else { removeUser(nick, from: id) }
    }

    private func handleNick(_ message: IRCMessage) {
        guard let oldNick = message.nickname, let newNick = message.parameters.first else { return }
        if oldNick.caseInsensitiveCompare(currentNickname) == .orderedSame { currentNickname = newNick }
        for index in conversations.indices where conversations[index].kind == .channel {
            if let userIndex = conversations[index].users.firstIndex(where: { $0.nickname.caseInsensitiveCompare(oldNick) == .orderedSame }) {
                let prefix = conversations[index].users[userIndex].prefix
                conversations[index].users[userIndex] = IRCUser(nickname: newNick, prefix: prefix)
                conversations[index].users.sort(by: userSort)
            }
        }
    }

    private func handleNames(_ message: IRCMessage) {
        guard message.parameters.count >= 4 else { return }
        let id = conversationID(message.parameters[2])
        ensureConversation(id: id, name: message.parameters[2], kind: .channel)
        for token in message.parameters[3].split(separator: " ") {
            let value = String(token)
            let prefix = value.first.flatMap { "~&@%+".contains($0) ? $0 : nil }
            addUser(IRCUser(nickname: prefix == nil ? value : String(value.dropFirst()), prefix: prefix), to: id)
        }
    }

    private func handleKick(_ message: IRCMessage) {
        guard message.parameters.count >= 2 else { return }
        let id = conversationID(message.parameters[0])
        let nick = message.parameters[1]
        removeUser(nick, from: id)
        if nick.caseInsensitiveCompare(currentNickname) == .orderedSame { mutateConversation(id) { $0.isJoined = false } }
    }

    private func handleMode(_ message: IRCMessage) {
        guard message.parameters.count >= 3, isChannel(message.parameters[0]) else { return }
        let id = conversationID(message.parameters[0])
        var adding = true
        var argumentIndex = 2
        let prefixMap: [Character: Character] = ["q": "~", "a": "&", "o": "@", "h": "%", "v": "+"]
        for mode in message.parameters[1] {
            if mode == "+" { adding = true; continue }
            if mode == "-" { adding = false; continue }
            guard let prefix = prefixMap[mode], argumentIndex < message.parameters.count else { continue }
            let nick = message.parameters[argumentIndex]
            argumentIndex += 1
            mutateConversation(id) { conversation in
                guard let index = conversation.users.firstIndex(where: { $0.nickname.caseInsensitiveCompare(nick) == .orderedSame }) else { return }
                let old = conversation.users[index]
                conversation.users[index] = IRCUser(nickname: old.nickname, prefix: adding ? prefix : nil)
                conversation.users.sort(by: userSort)
            }
        }
    }

    private func handleTopic(_ message: IRCMessage) {
        let channel = message.command == "TOPIC" ? message.parameters.first : message.parameters.dropFirst().first
        guard let channel, let topic = message.parameters.last else { return }
        mutateConversation(conversationID(channel)) { $0.topic = topic }
    }

    private func execute(_ text: String) {
        guard text.hasPrefix("/") else { sendChat(text); return }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
        let command = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? String(parts[1]) : ""
        switch command {
        case "join", "j": joinChannelText = argument; joinChannel()
        case "part": if let selectedConversation, selectedConversation.kind == .channel { sendRaw("PART \(selectedConversation.name) :Forlater kanalen") }
        case "msg":
            let values = argument.split(separator: " ", maxSplits: 1)
            if values.count == 2 { openQuery(String(values[0])); sendMessage(String(values[1]), to: String(values[0])) }
        case "query": openQuery(argument)
        case "me":
            if let selectedConversation, selectedConversation.kind != .server {
                sendRaw("PRIVMSG \(selectedConversation.name) :\u{1}ACTION \(argument)\u{1}")
                if !enabledCapabilities.contains("echo-message") {
                    appendMessage(to: selectedConversation.id, message: ChatMessage(sender: currentNickname, text: argument, kind: .action, isOwn: true))
                }
            }
        case "nick": if !argument.isEmpty { sendRaw("NICK \(argument)") }
        case "whois": if !argument.isEmpty { sendRaw("WHOIS \(argument)") }
        case "quote", "raw": if !argument.isEmpty { sendRaw(argument) }
        case "quit": disconnect()
        default: appendStatus("Ukjent kommando: /\(command)")
        }
    }

    private func sendChat(_ text: String) {
        guard connectionState == .connected, let selectedConversation, selectedConversation.kind != .server else { return }
        sendMessage(text, to: selectedConversation.name)
    }

    private func sendMessage(_ text: String, to target: String) {
        let id = conversationID(target)
        ensureConversation(id: id, name: target, kind: isChannel(target) ? .channel : .query)
        sendRaw("PRIVMSG \(target) :\(text)")
        if !enabledCapabilities.contains("echo-message") {
            appendMessage(to: id, message: ChatMessage(sender: currentNickname, text: text, isOwn: true))
        }
    }

    private func sendRaw(_ line: String) {
        guard connectionState != .disconnected else { return }
        connection.send(line)
    }

    private func appendStatus(_ text: String) {
        appendMessage(to: serverID, message: ChatMessage(text: text, kind: .event))
    }

    private func appendMessage(to id: String, message: ChatMessage, source: IRCMessage? = nil) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let playback = source?.tags["batch"].flatMap { playbackBatches[$0] }
        if let source, isDuplicate(
            message,
            source: source,
            conversation: conversations[index],
            playbackHistoryCount: playback?.historyCount
        ) { return }
        let isPlayback = playback != nil
        conversations[index].messages.append(message)
        if conversations[index].messages.count > 2_000 { conversations[index].messages.removeFirst(200) }
        if !isPlayback, selectedConversationID != id, !message.isOwn {
            conversations[index].unreadCount += 1
            if message.isMention { conversations[index].mentionCount += 1 }
        }
        persistHistory(for: id)
    }

    private func isDuplicate(
        _ message: ChatMessage,
        source: IRCMessage,
        conversation: Conversation,
        playbackHistoryCount: Int?
    ) -> Bool {
        if let messageID = source.tags["msgid"], !messageID.isEmpty {
            guard !seenMessageIDs.contains(messageID) else { return true }
            seenMessageIDs.insert(messageID)
            seenMessageIDOrder.append(messageID)
            if seenMessageIDOrder.count > 4_000 {
                seenMessageIDs.remove(seenMessageIDOrder.removeFirst())
            }
        }
        guard source.serverTimestamp != nil else { return false }
        if conversation.messages.suffix(400).contains(where: {
            $0.sender?.caseInsensitiveCompare(message.sender ?? "") == .orderedSame
                && $0.text == message.text
                && $0.kind == message.kind
                && abs($0.timestamp.timeIntervalSince(message.timestamp)) < 0.001
        }) {
            return true
        }

        guard let playbackHistoryCount else { return false }
        let upperBound = min(playbackHistoryCount, conversation.messages.count)
        let calendar = Calendar.current
        let messageTime = calendar.dateComponents([.hour, .minute, .second], from: message.timestamp)
        return conversation.messages[..<upperBound].suffix(400).contains {
            let existingTime = calendar.dateComponents([.hour, .minute, .second], from: $0.timestamp)
            return $0.sender?.caseInsensitiveCompare(message.sender ?? "") == .orderedSame
                && $0.text == message.text
                && $0.kind == message.kind
                && existingTime.hour == messageTime.hour
                && existingTime.minute == messageTime.minute
                && existingTime.second == messageTime.second
        }
    }

    private func ensureConversation(id: String, name: String, kind: ConversationKind) {
        guard !conversations.contains(where: { $0.id == id }) else { return }
        var conversation = Conversation(id: id, name: name, kind: kind)
        if !loadedHistoryIDs.contains(id), let history = historyCache[id], !history.isEmpty {
            conversation.messages = Array(history.suffix(250))
            conversation.messages.append(ChatMessage(text: "──── Live ────", kind: .event))
        }
        loadedHistoryIDs.insert(id)
        conversations.append(conversation)
    }

    private func mutateConversation(_ id: String, _ body: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[index])
    }

    private func addUser(_ user: IRCUser, to id: String) {
        mutateConversation(id) {
            if let index = $0.users.firstIndex(where: { $0.nickname.caseInsensitiveCompare(user.nickname) == .orderedSame }) {
                if $0.users[index].prefix == nil { $0.users[index] = user }
            } else { $0.users.append(user) }
            $0.users.sort(by: userSort)
        }
    }

    private func removeUser(_ nickname: String, from id: String? = nil) {
        if let id { mutateConversation(id) { $0.users.removeAll { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame } } }
        else {
            for index in conversations.indices { conversations[index].users.removeAll { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame } }
        }
    }

    private func userSort(_ lhs: IRCUser, _ rhs: IRCUser) -> Bool {
        let rank: (Character?) -> Int = { switch $0 { case "~", "&", "@": 0; case "%", "+": 1; default: 2 } }
        let lhsRank = rank(lhs.prefix), rhsRank = rank(rhs.prefix)
        return lhsRank == rhsRank ? lhs.nickname.localizedCaseInsensitiveCompare(rhs.nickname) == .orderedAscending : lhsRank < rhsRank
    }

    private func conversationID(_ name: String) -> String { "conversation:\(name.lowercased())" }
    private func isChannel(_ name: String) -> Bool { name.hasPrefix("#") || name.hasPrefix("&") }
    private func capabilityName(_ token: Substring) -> String {
        let value = token.drop(while: { $0 == "-" || $0 == "~" || $0 == "=" })
        return value.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
    }
    private func containsCurrentNick(_ text: String) -> Bool {
        text.range(of: currentNickname, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    private func markChannelsDisconnected() {
        channelsToRestore.formUnion(conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name))
        for index in conversations.indices where conversations[index].kind == .channel {
            conversations[index].isJoined = false
            conversations[index].users.removeAll()
        }
    }

    private static func historyKey(profileID: UUID) -> String {
        "MacRelay.iOS.history.v1.\(profileID.uuidString)"
    }

    private static func readHistory(profileID: UUID) -> [String: [ChatMessage]] {
        guard let data = UserDefaults.standard.data(forKey: historyKey(profileID: profileID)) else { return [:] }
        return (try? JSONDecoder().decode([String: [ChatMessage]].self, from: data)) ?? [:]
    }

    private func loadHistoryForCurrentProfile() {
        historyCache = Self.readHistory(profileID: configuration.id)
        loadedHistoryIDs.removeAll()
    }

    private func persistHistory(for id: String) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        historyCache[id] = Array(conversation.messages.filter {
            $0.text != "──── Live ────" && $0.text != "──── Reconnect ────"
        }.suffix(250))
        if let data = try? JSONEncoder().encode(historyCache) {
            UserDefaults.standard.set(data, forKey: Self.historyKey(profileID: configuration.id))
        }
    }

    private func saveSession() {
        let session = IOSSession(
            profileID: configuration.id,
            openChannels: conversations.filter { $0.kind == .channel }.map(\.name),
            joinedChannels: Array(Set(
                conversations.filter { $0.kind == .channel && $0.isJoined }.map(\.name)
            ).union(channelsToRestore)),
            openQueries: conversations.filter { $0.kind == .query }.map(\.name),
            selectedConversationID: selectedConversationID,
            shouldReconnect: shouldReconnectInForeground && !intentionalDisconnect
        )
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: sessionKey) }
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(IOSSession.self, from: data),
              session.profileID == configuration.id else { return }
        session.openChannels.forEach { ensureConversation(id: conversationID($0), name: $0, kind: .channel) }
        session.openQueries.forEach { ensureConversation(id: conversationID($0), name: $0, kind: .query) }
        if let selected = session.selectedConversationID, conversations.contains(where: { $0.id == selected }) {
            selectedConversationID = selected
            restoredSelectionID = selected
        }
        channelsToRestore = Set(session.joinedChannels ?? session.openChannels)
        shouldReconnectInForeground = session.shouldReconnect
        if session.shouldReconnect { Task { @MainActor [weak self] in await Task.yield(); self?.connect() } }
    }

    private func isPlaybackStateEvent(_ message: IRCMessage) -> Bool {
        guard let batchID = message.tags["batch"], playbackBatches[batchID] != nil else { return false }
        return ["JOIN", "PART", "QUIT", "NICK", "KICK", "MODE", "TOPIC"].contains(message.command)
    }

    private func scheduleRestoredSelectionCleanup() {
        restoreSelectionTask?.cancel()
        restoreSelectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
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
}
