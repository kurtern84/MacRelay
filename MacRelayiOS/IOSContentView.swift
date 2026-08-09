import MacRelayCore
import SwiftUI

struct IOSContentView: View {
    @ObservedObject var store: IOSIRCStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            conversationList
                .navigationTitle("MacRelay")
                .toolbar { sidebarToolbar }
        } content: {
            if let conversation = store.selectedConversation {
                ConversationView(store: store, conversation: conversation)
                    .id(conversation.id)
            } else {
                ContentUnavailableView("Velg en samtale", systemImage: "number")
            }
        } detail: {
            if let conversation = store.selectedConversation, conversation.kind == .channel {
                UserListView(store: store, conversation: conversation)
                    .id(conversation.id)
            } else {
                ContentUnavailableView("Ingen brukerliste", systemImage: "person.2")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $store.showingSettings) {
            NavigationStack { SettingsView(store: store) }
        }
        .alert("Bli med i kanal", isPresented: $store.showingJoin) {
            TextField("#kanal", text: $store.joinChannelText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Avbryt", role: .cancel) {}
            Button("Bli med") { store.joinChannel() }
        }
    }

    private var conversationList: some View {
        List(selection: Binding(
            get: { store.selectedConversationID },
            set: { if let id = $0 { store.selectConversation(id) } }
        )) {
            Section {
                ForEach(store.conversations.filter { $0.kind == .server }) { conversation in
                    ConversationListRow(conversation: conversation)
                        .tag(conversation.id)
                }
            } header: {
                HStack {
                    Text("Server")
                    Spacer()
                    Circle()
                        .fill(store.connectionState == .connected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                }
            }

            let channels = store.conversations.filter { $0.kind == .channel }
            if !channels.isEmpty {
                Section("Kanaler") {
                    ForEach(channels) { conversation in
                        ConversationListRow(conversation: conversation).tag(conversation.id)
                    }
                }
            }

            let queries = store.conversations.filter { $0.kind == .query }
            if !queries.isEmpty {
                Section("Private") {
                    ForEach(queries) { conversation in
                        ConversationListRow(conversation: conversation).tag(conversation.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { store.showingSettings = true } label: { Image(systemName: "gearshape") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { store.showingJoin = true } label: { Image(systemName: "number") }
                .disabled(store.connectionState != .connected)
            Menu {
                if store.connectionState == .disconnected {
                    Button("Koble til") { store.connect() }
                } else {
                    Button("Koble fra", role: .destructive) { store.disconnect() }
                }
                Button("Ny serverprofil") { store.addProfile() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct ConversationListRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: conversation.kind == .server ? "network" : conversation.kind == .channel ? "number" : "person")
                .foregroundStyle(conversation.kind == .channel ? .blue : .secondary)
            Text(conversation.name)
                .lineLimit(1)
            Spacer()
            if conversation.unreadCount > 0 {
                Circle()
                    .fill(conversation.mentionCount > 0 ? Color.orange : Color.blue)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("\(conversation.unreadCount) uleste")
            }
        }
    }
}

private struct ConversationView: View {
    @ObservedObject var store: IOSIRCStore
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 0) {
            if conversation.kind == .channel {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.name).font(.headline)
                    if let topic = conversation.topic, !topic.isEmpty {
                        Text(topic).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 9)
                Divider()
            }

            MessageList(messages: conversation.messages)

            Divider()
            HStack(spacing: 10) {
                TextField("Melding til \(conversation.name)", text: $store.inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit { store.sendInput() }
                Button { store.sendInput() } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderless)
                .disabled(store.inputText.isEmpty || conversation.kind == .server || store.connectionState != .connected)
            }
            .padding(.horizontal)
            .padding(.vertical, 11)
            .background(.bar)
        }
        .navigationTitle(conversation.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.isConnectedViaZNC {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(conversation.name).font(.headline)
                        Text("via ZNC").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct MessageList: View {
    let messages: [ChatMessage]
    @State private var isAtBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("message-list-bottom")
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in
                guard id != nil, isAtBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("message-list-bottom", anchor: .bottom) }
            }
        }
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
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let sender = message.sender {
                Text(message.kind == .action ? "• \(sender)" : "<\(sender)>")
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(message.isOwn ? .cyan : nickColor(sender))
            }
            Text(message.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(message.kind == .error ? .orange : message.kind == .event ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nickColor(_ nick: String) -> Color {
        let palette: [Color] = [.blue, .pink, .orange, .mint, .purple, .teal]
        let value = nick.lowercased().unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return palette[Int(value % UInt64(palette.count))]
    }
}

private struct UserListView: View {
    @ObservedObject var store: IOSIRCStore
    let conversation: Conversation

    var body: some View {
        List(conversation.users) { user in
            Button { store.openQuery(user.nickname) } label: {
                Text(user.displayName).font(.system(.body, design: .monospaced))
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Brukere (\(conversation.users.count))")
    }
}

private struct SettingsView: View {
    @ObservedObject var store: IOSIRCStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Serverprofil") {
                Picker("Profil", selection: Binding(
                    get: { store.configuration.id },
                    set: { store.switchProfile($0) }
                )) {
                    ForEach(store.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                Button("Legg til profil") { store.addProfile() }
                Button("Slett profil", role: .destructive) { store.deleteCurrentProfile() }
                    .disabled(store.profiles.count == 1)
            }

            Section("Server") {
                TextField("Profilnavn", text: $store.configuration.name)
                TextField("Adresse", text: $store.configuration.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $store.configuration.port, format: .number)
                    .keyboardType(.numberPad)
                Toggle("Bruk TLS", isOn: $store.configuration.useTLS)
                Toggle("Tillat selvsignert sertifikat", isOn: $store.configuration.allowUntrustedCertificate)
                if store.configuration.allowUntrustedCertificate {
                    Label("Bruk bare dette for en server du stoler på.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Identitet") {
                TextField("Kallenavn", text: $store.configuration.nickname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Alternativt kallenavn", text: $store.configuration.alternateNickname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Brukernavn", text: $store.configuration.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Virkelig navn", text: $store.configuration.realName)
            }

            Section {
                SecureField("IRC PASS (valgfritt)", text: $store.ircPassword)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Sendes som IRC PASS før innlogging. Brukes blant annet av ZNC og IRC-servere som krever serverautentisering.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("NickServ-passord (valgfritt)", text: $store.nickServPassword)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("IRC PASS og NickServ-passord lagres separat i Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Autentisering")
            }

            Section("Automatisk tilkobling") {
                TextField("Kanaler, separert med komma", text: $store.configuration.autoJoinChannels)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        .navigationTitle("IRC-servere")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Lagre") { store.saveProfile(); dismiss() }
            }
        }
    }
}
