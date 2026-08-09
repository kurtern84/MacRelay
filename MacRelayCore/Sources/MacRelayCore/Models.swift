import Foundation

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected

    public var label: String {
        switch self {
        case .disconnected: "Frakoblet"
        case .connecting: "Kobler til …"
        case .connected: "Tilkoblet"
        }
    }
}

public enum ConversationKind: String, Codable, Sendable {
    case server
    case channel
    case query
}

public enum MessageKind: String, Codable, Equatable, Sendable {
    case normal
    case action
    case notice
    case event
    case error
}

public struct ChatMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let sender: String?
    public let text: String
    public let kind: MessageKind
    public let isOwn: Bool
    public let isMention: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sender: String? = nil,
        text: String,
        kind: MessageKind = .normal,
        isOwn: Bool = false,
        isMention: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.text = text
        self.kind = kind
        self.isOwn = isOwn
        self.isMention = isMention
    }
}

public struct IRCUser: Identifiable, Hashable, Sendable {
    public let nickname: String
    public let prefix: Character?

    public init(nickname: String, prefix: Character? = nil) {
        self.nickname = nickname
        self.prefix = prefix
    }

    public var id: String { nickname.lowercased() }
    public var displayName: String { prefix.map { String($0) + nickname } ?? nickname }
}

public struct Conversation: Identifiable, Sendable {
    public let id: String
    public var name: String
    public let kind: ConversationKind
    public var topic: String?
    public var messages: [ChatMessage]
    public var users: [IRCUser]
    public var unreadCount: Int
    public var mentionCount: Int
    public var isJoined: Bool

    public init(
        id: String,
        name: String,
        kind: ConversationKind,
        topic: String? = nil,
        messages: [ChatMessage] = [],
        users: [IRCUser] = [],
        unreadCount: Int = 0,
        mentionCount: Int = 0,
        isJoined: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.topic = topic
        self.messages = messages
        self.users = users
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isJoined = isJoined
    }
}

public struct ServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "Libera Chat"
    public var host = "irc.libera.chat"
    public var port = 6697
    public var useTLS = true
    public var nickname = "MacRelayUser"
    public var alternateNickname = "MacRelayUser_"
    public var username = "macrelay"
    public var realName = "MacRelay for macOS"
    public var autoJoinChannels = "#macrelay"
    public var allowUntrustedCertificate = false
    public var loggingEnabled = true
    public var notifyOnMention = false
    public var playNotificationSounds = true
    public var autoAwayEnabled = false
    public var startAwayOnConnect = false
    public var autoAwayMinutes = 15
    public var autoAwayMessage = "Ikke ved Mac-en"

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useTLS, nickname, alternateNickname
        case username, realName, autoJoinChannels, allowUntrustedCertificate
        case loggingEnabled, notifyOnMention, playNotificationSounds
        case autoAwayEnabled, startAwayOnConnect, autoAwayMinutes, autoAwayMessage
    }

    public init() {}

    public init(from decoder: Decoder) throws {
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
        autoAwayEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoAwayEnabled) ?? false
        startAwayOnConnect = try values.decodeIfPresent(Bool.self, forKey: .startAwayOnConnect) ?? false
        autoAwayMinutes = try values.decodeIfPresent(Int.self, forKey: .autoAwayMinutes) ?? 15
        autoAwayMessage = try values.decodeIfPresent(String.self, forKey: .autoAwayMessage) ?? "Ikke ved Mac-en"
    }

    public var channels: [String] {
        autoJoinChannels
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("#") || $0.hasPrefix("&") ? $0 : "#" + $0 }
    }
}

public struct DCCOffer: Identifiable, Sendable {
    public let id = UUID()
    public let sender: String
    public let filename: String
    public let size: Int64?
    public let address: String
    public let port: UInt16

    public init(sender: String, filename: String, size: Int64?, address: String, port: UInt16) {
        self.sender = sender
        self.filename = filename
        self.size = size
        self.address = address
        self.port = port
    }
}

public struct IRCMessage: Sendable {
    public let tags: [String: String]
    public let prefix: String?
    public let command: String
    public let parameters: [String]

    public init(tags: [String: String], prefix: String?, command: String, parameters: [String]) {
        self.tags = tags
        self.prefix = prefix
        self.command = command
        self.parameters = parameters
    }

    public var nickname: String? {
        guard let prefix else { return nil }
        return String(prefix.split(separator: "!", maxSplits: 1).first ?? Substring(prefix))
    }

    public var serverTimestamp: Date? {
        guard let value = tags["time"] else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    public static func parse(_ rawLine: String) -> IRCMessage? {
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
