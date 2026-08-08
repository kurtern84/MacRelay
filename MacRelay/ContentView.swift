import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: IRCStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if let conversation = store.selectedConversation {
                ConversationView(conversation: conversation)
            } else {
                ContentUnavailableView("Ingen samtale valgt", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationTitle(store.selectedConversation?.name ?? "MacRelay")
        .toolbar {
            ToolbarItemGroup {
                Button { store.toggleConnection() } label: {
                    Label(
                        store.connectionState == .connected ? "Koble fra" : "Koble til",
                        systemImage: store.connectionState == .connected ? "bolt.slash" : "bolt"
                    )
                }
                .help(store.connectionState == .connected ? "Koble fra serveren" : "Koble til serveren")

                Button { store.showJoinChannel = true } label: {
                    Label("Bli med i kanal", systemImage: "number")
                }
                .disabled(store.connectionState != .connected)

                SettingsLink { Label("Serverinnstillinger", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $store.showJoinChannel) {
            JoinChannelView().environmentObject(store)
        }
        .sheet(isPresented: $store.showSettings) {
            ServerSettingsView()
                .environmentObject(store)
                .frame(width: 560, height: 650)
        }
        .sheet(item: $store.incomingDCCOffer) { offer in
            DCCOfferView(offer: offer).environmentObject(store)
        }
        .sheet(isPresented: $store.showWhoisPrompt) {
            WhoisView().environmentObject(store)
        }
        .sheet(isPresented: $store.showIgnoreList) {
            IgnoreListView().environmentObject(store)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: IRCStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedConversationID) {
                Section("Server") {
                    ForEach(store.conversations.filter { $0.kind == .server }) { conversation in
                        ConversationRow(conversation: conversation, serverConnected: store.connectionState == .connected)
                            .tag(conversation.id)
                            .contextMenu { serverMenu(conversation) }
                    }
                }

                let channels = store.conversations.filter { $0.kind == .channel }
                if !channels.isEmpty {
                    Section("Kanaler") {
                        ForEach(channels) { conversation in
                            ConversationRow(conversation: conversation)
                                .tag(conversation.id)
                                .contextMenu { channelMenu(conversation) }
                        }
                    }
                }

                let queries = store.conversations.filter { $0.kind == .query }
                if !queries.isEmpty {
                    Section("Private samtaler") {
                        ForEach(queries) { conversation in
                            ConversationRow(conversation: conversation)
                                .tag(conversation.id)
                                .contextMenu { queryMenu(conversation) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: store.selectedConversationID) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    await Task.yield()
                    store.markConversationRead(id)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text(store.connectionState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func serverMenu(_ conversation: Conversation) -> some View {
        Button("Koble til på nytt", systemImage: "arrow.clockwise") { store.reconnect() }
            .disabled(store.connectionState == .connecting)
        Button("Koble fra", systemImage: "bolt.slash") { store.disconnect() }
            .disabled(store.connectionState == .disconnected)
        Divider()
        Button("Rediger server …", systemImage: "gearshape") { store.showSettings = true }
        Button("Åpne serverlogg", systemImage: "doc.text") { store.openLog(for: conversation) }
    }

    @ViewBuilder
    private func channelMenu(_ conversation: Conversation) -> some View {
        Button("Forlat kanal", systemImage: "rectangle.portrait.and.arrow.right") { store.closeConversation(conversation.id) }
            .disabled(!conversation.isJoined)
        Button("Vis topic", systemImage: "text.quote") {
            store.selectConversation(conversation.id)
            store.requestTopic(for: conversation)
        }
        Button("Kopier kanalnavn", systemImage: "doc.on.doc") { copy(conversation.name) }
        Divider()
        Button("Åpne logg", systemImage: "doc.text") { store.openLog(for: conversation) }
        Button("Lukk", systemImage: "xmark", role: .destructive) { store.closeConversation(conversation.id) }
    }

    @ViewBuilder
    private func queryMenu(_ conversation: Conversation) -> some View {
        Button("Kopier nick", systemImage: "doc.on.doc") { copy(conversation.name) }
        Button("WHOIS", systemImage: "person.text.rectangle") { store.whois(conversation.name) }
        Button(store.isIgnored(conversation.name) ? "Slutt å ignorere" : "Ignorer", systemImage: "speaker.slash") {
            store.toggleIgnore(conversation.name)
        }
        Divider()
        Button("Åpne logg", systemImage: "doc.text") { store.openLog(for: conversation) }
        Button("Lukk", systemImage: "xmark", role: .destructive) { store.closeConversation(conversation.id) }
    }

    private var stateColor: Color {
        switch store.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    var serverConnected = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .foregroundStyle(conversation.kind == .server ? Color.orange : Color.accentColor)
                .frame(width: 16)
            if conversation.kind == .server, serverConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Tilkoblet")
            }
            Text(conversation.name).lineLimit(1)
            Spacer()
            if conversation.mentionCount > 0 {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("\(conversation.mentionCount) omtaler")
            } else if conversation.unreadCount > 0 {
                Circle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("\(conversation.unreadCount) uleste meldinger")
            }
        }
    }

    private var iconName: String {
        switch conversation.kind {
        case .server: "network"
        case .channel: "number"
        case .query: "person.crop.circle"
        }
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var store: IRCStore
    let conversation: Conversation

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if conversation.kind == .channel { ChannelHeader(conversation: conversation) }
                MessageList(messages: conversation.messages)
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        conversation.kind == .server ? "Skriv /help for kommandoer" : "Melding til \(conversation.name)",
                        text: $store.inputText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit { store.sendInput() }
                    .padding(10)

                    Button { store.sendInput() } label: { Image(systemName: "paperplane.fill") }
                        .buttonStyle(.borderless)
                        .disabled(store.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                }
                .background(.background)
            }
            .frame(minWidth: 480)

            if conversation.kind == .channel {
                UserList(users: conversation.users)
                    .frame(minWidth: 150, idealWidth: 190, maxWidth: 260)
            }
        }
    }
}

private struct ChannelHeader: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(conversation.name).font(.headline)
                if !conversation.isJoined {
                    Text("Ikke tilkoblet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(conversation.topic.map { "Topic: \($0)" } ?? "Ingen topic satt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct MessageList: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(Self.timeFormatter.string(from: message.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 39, alignment: .trailing)

            if let sender = message.sender {
                Text(message.kind == .action ? "• \(sender)" : "<\(sender)>")
                    .font(.system(.body, design: .monospaced).weight(message.isOwn || message.isMention ? .semibold : .medium))
                    .foregroundStyle(message.isOwn ? Color.accentColor : senderColor(sender))
                    .textSelection(.enabled)
            }

            Text(message.text)
                .font(.system(.body, design: .monospaced))
                .italic(message.kind == .action)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(message.isMention ? Color.orange.opacity(0.10) : Color.clear)
    }

    private var textColor: Color {
        switch message.kind {
        case .error: .red
        case .notice: .orange
        case .event: .secondary
        default: .primary
        }
    }

    private func senderColor(_ sender: String) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .pink, .green, .orange]
        let hash = sender.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return colors[Int(UInt(bitPattern: hash) % UInt(colors.count))]
    }
}

private struct UserList: View {
    @EnvironmentObject private var store: IRCStore
    let users: [IRCUser]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Brukere").font(.headline)
                Spacer()
                Text("\(users.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            List(users) { user in
                Text(user.displayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(store.isIgnored(user.nickname) ? .secondary : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { store.openQuery(with: user.nickname) }
                    .contextMenu {
                        Button("Åpne privat samtale", systemImage: "person.crop.circle") { store.openQuery(with: user.nickname) }
                        Button("WHOIS", systemImage: "person.text.rectangle") { store.whois(user.nickname) }
                        Button(store.isIgnored(user.nickname) ? "Slutt å ignorere" : "Ignorer", systemImage: "speaker.slash") {
                            store.toggleIgnore(user.nickname)
                        }
                        Divider()
                        Button("Kopier nick", systemImage: "doc.on.doc") { copy(user.nickname) }
                    }
            }
            .listStyle(.plain)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct JoinChannelView: View {
    @EnvironmentObject private var store: IRCStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bli med i kanal").font(.title2.bold())
            TextField("#kanal", text: $store.joinChannelText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.joinChannel() }
            HStack {
                Spacer()
                Button("Avbryt") { dismiss() }
                Button("Bli med") { store.joinChannel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.joinChannelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}

struct ServerSettingsView: View {
    @EnvironmentObject private var store: IRCStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Favorittserver") {
                HStack {
                    Picker("Profil", selection: Binding(
                        get: { store.configuration.id },
                        set: { id in
                            Task { @MainActor in
                                await Task.yield()
                                store.selectProfile(id)
                            }
                        }
                    )) {
                        ForEach(store.profiles) { profile in Text(profile.name).tag(profile.id) }
                    }
                    .disabled(store.connectionState != .disconnected)
                    Button { store.addProfile() } label: { Image(systemName: "plus") }
                        .help("Ny serverprofil")
                        .disabled(store.connectionState != .disconnected)
                    Button(role: .destructive) { store.deleteCurrentProfile() } label: { Image(systemName: "minus") }
                        .help("Slett serverprofil")
                        .disabled(store.connectionState != .disconnected || store.profiles.count < 2)
                }
                TextField("Profilnavn", text: $store.configuration.name)
            }

            Section("Server") {
                TextField("Adresse", text: $store.configuration.host)
                TextField("Port", value: $store.configuration.port, format: .number.grouping(.never))
                Toggle("Bruk TLS", isOn: $store.configuration.useTLS)
                Toggle("Tillat selvsignert sertifikat", isOn: $store.configuration.allowUntrustedCertificate)
                    .disabled(!store.configuration.useTLS)
                if store.configuration.allowUntrustedCertificate && store.configuration.useTLS {
                    Label("Bruk bare dette for en server du stoler på. Sertifikatet blir ikke verifisert av macOS.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Identitet") {
                TextField("Kallenavn", text: $store.configuration.nickname)
                TextField("Alternativt kallenavn", text: $store.configuration.alternateNickname)
                TextField("Brukernavn", text: $store.configuration.username)
                TextField("Virkelig navn", text: $store.configuration.realName)
                SecureField("NickServ-passord (valgfritt)", text: $store.nickServPassword)
                Text("NickServ-passordet lagres bare i macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Automatisk tilkobling") {
                TextField("Kanaler, separert med komma", text: $store.configuration.autoJoinChannels)
                Toggle("Gjenopprett forrige økt ved oppstart", isOn: $store.restorePreviousSession)
                Text("Eksempel: #swift, #macos").font(.caption).foregroundStyle(.secondary)
            }

            Section("Automatisk away") {
                Toggle("Sett meg som away automatisk", isOn: $store.configuration.autoAwayEnabled)
                Toggle("Start som away ved tilkobling", isOn: $store.configuration.startAwayOnConnect)
                Picker("Inaktivitet", selection: $store.configuration.autoAwayMinutes) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) minutter").tag(minutes)
                    }
                }
                .disabled(!store.configuration.autoAwayEnabled)
                TextField("Away-melding", text: $store.configuration.autoAwayMessage)
                    .disabled(!store.configuration.autoAwayEnabled && !store.configuration.startAwayOnConnect)
                Text("Start som away overstyrer tidsintervallet og beholdes til valget slås av.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logger og varsling") {
                Toggle("Logg kanaler og private samtaler", isOn: $store.configuration.loggingEnabled)
                Toggle("Vis macOS-varsel når navnet mitt nevnes", isOn: $store.configuration.notifyOnMention)
                Toggle("Spill diskret IRC-varsellyd", isOn: $store.configuration.playNotificationSounds)
                Text("Bruker macOS-systemlyden Glass ved omtaler og uleste private meldinger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Lagre") {
                    store.saveConfiguration()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("IRC-servere")
    }
}

private struct WhoisView: View {
    @EnvironmentObject private var store: IRCStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("WHOIS", systemImage: "person.text.rectangle")
                .font(.title2.bold())
            TextField("Kallenavn", text: $store.whoisNickname)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.submitWhois() }
            HStack {
                Spacer()
                Button("Avbryt") { dismiss() }
                Button("Slå opp") { store.submitWhois() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.whoisNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}

private struct IgnoreListView: View {
    @EnvironmentObject private var store: IRCStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ignoreringsliste", systemImage: "speaker.slash")
                .font(.title2.bold())
            if store.ignoredNicknames.isEmpty {
                ContentUnavailableView("Ingen ignorerte brukere", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(store.ignoredNicknames, id: \.self) { nickname in
                    HStack {
                        Text(nickname).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Fjern") { store.toggleIgnore(nickname) }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Ferdig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct DCCOfferView: View {
    @EnvironmentObject private var store: IRCStore
    let offer: DCCOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Innkommende DCC-fil", systemImage: "doc.badge.arrow.down")
                .font(.title2.bold())
            Text("\(offer.sender) tilbyr filen «\(offer.filename)».")
            if let size = offer.size {
                LabeledContent("Størrelse", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            Label("Filen er ikke mottatt. Sikker DCC-overføring er klargjort i grensesnittet, men overføringsmotoren er ikke aktivert ennå.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Avvis") { store.dismissDCCOffer() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
