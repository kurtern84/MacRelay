import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected

    var label: String {
        switch self {
        case .disconnected: "Frakoblet"
        case .connecting: "Kobler til …"
        case .connected: "Tilkoblet"
        }
    }
}

enum ConversationKind: String, Codable {
    case server
    case channel
    case query
}

enum MessageKind {
    case normal
    case action
    case notice
    case event
    case error
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let timestamp: Date
    let sender: String?
    let text: String
    let kind: MessageKind
    let isOwn: Bool
    let isMention: Bool

    init(
        sender: String? = nil,
        text: String,
        kind: MessageKind = .normal,
        isOwn: Bool = false,
        isMention: Bool = false
    ) {
        timestamp = Date()
        self.sender = sender
        self.text = text
        self.kind = kind
        self.isOwn = isOwn
        self.isMention = isMention
    }
}

struct IRCUser: Identifiable, Hashable {
    let nickname: String
    let prefix: Character?

    var id: String { nickname.lowercased() }
    var displayName: String { prefix.map { String($0) + nickname } ?? nickname }
}

struct Conversation: Identifiable {
    let id: String
    var name: String
    let kind: ConversationKind
    var topic: String?
    var messages: [ChatMessage] = []
    var users: [IRCUser] = []
    var unreadCount = 0
    var mentionCount = 0
    var isJoined = false
}

struct ServerConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Libera Chat"
    var host = "irc.libera.chat"
    var port = 6697
    var useTLS = true
    var nickname = "MacRelayUser"
    var alternateNickname = "MacRelayUser_"
    var username = "macrelay"
    var realName = "MacRelay for macOS"
    var autoJoinChannels = "#macrelay"
    var allowUntrustedCertificate = false
    var loggingEnabled = true
    var notifyOnMention = false
    var playNotificationSounds = true

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, nickname, alternateNickname
        case username, realName, autoJoinChannels, allowUntrustedCertificate
        case loggingEnabled, notifyOnMention, playNotificationSounds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? "irc.libera.chat"
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 6697
        useTLS = try values.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
        nickname = try values.decodeIfPresent(String.self, forKey: .nickname) ?? "MacRelayUser"
        alternateNickname = try values.decodeIfPresent(String.self, forKey: .alternateNickname) ?? nickname + "_"
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? "macrelay"
        realName = try values.decodeIfPresent(String.self, forKey: .realName) ?? "MacRelay for macOS"
        autoJoinChannels = try values.decodeIfPresent(String.self, forKey: .autoJoinChannels) ?? "#macrelay"
        allowUntrustedCertificate = try values.decodeIfPresent(Bool.self, forKey: .allowUntrustedCertificate) ?? false
        loggingEnabled = try values.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? true
        notifyOnMention = try values.decodeIfPresent(Bool.self, forKey: .notifyOnMention) ?? false
        playNotificationSounds = try values.decodeIfPresent(Bool.self, forKey: .playNotificationSounds) ?? true
    }

    var channels: [String] {
        autoJoinChannels
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("#") || $0.hasPrefix("&") ? $0 : "#" + $0 }
    }
}

struct DCCOffer: Identifiable {
    let id = UUID()
    let sender: String
    let filename: String
    let size: Int64?
    let address: String
    let port: UInt16
}

struct IRCMessage {
    let tags: [String: String]
    let prefix: String?
    let command: String
    let parameters: [String]

    var nickname: String? {
        guard let prefix else { return nil }
        return String(prefix.split(separator: "!", maxSplits: 1).first ?? Substring(prefix))
    }

    static func parse(_ rawLine: String) -> IRCMessage? {
        var line = rawLine
        var tags: [String: String] = [:]
        var prefix: String?

        if line.hasPrefix("@"), let space = line.firstIndex(of: " ") {
            let tagText = line[line.index(after: line.startIndex)..<space]
            for tag in tagText.split(separator: ";") {
                let pair = tag.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
            }
            line = String(line[line.index(after: space)...])
        }

        if line.hasPrefix(":"), let space = line.firstIndex(of: " ") {
            prefix = String(line[line.index(after: line.startIndex)..<space])
            line = String(line[line.index(after: space)...])
        }

        let command: String
        if let space = line.firstIndex(of: " ") {
            command = String(line[..<space]).uppercased()
            line = String(line[line.index(after: space)...])
        } else {
            command = line.uppercased()
            line = ""
        }

        var parameters: [String] = []
        while !line.isEmpty {
            if line.hasPrefix(":") {
                parameters.append(String(line.dropFirst()))
                break
            }
            if let space = line.firstIndex(of: " ") {
                parameters.append(String(line[..<space]))
                line = String(line[line.index(after: space)...])
                while line.first == " " { line.removeFirst() }
            } else {
                parameters.append(line)
                break
            }
        }

        guard !command.isEmpty else { return nil }
        return IRCMessage(tags: tags, prefix: prefix, command: command, parameters: parameters)
    }
}
