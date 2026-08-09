import AppKit
import Foundation

final class LogManager {
    private let fileManager = FileManager.default

    func append(_ message: ChatMessage, serverName: String, conversationName: String) {
        guard let url = logURL(
            serverName: serverName,
            conversationName: conversationName,
            date: message.timestamp,
            createDirectories: true
        ) else { return }
        let line = format(message) + "\n"
        guard let data = line.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    func reveal(serverName: String, conversationName: String) {
        guard let url = logURL(serverName: serverName, conversationName: conversationName, createDirectories: true) else { return }
        if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: nil) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLogsFolder() {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = appSupport.appendingPathComponent("MacRelay/Logs", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func recentMessages(serverName: String, conversationName: String, limit: Int = 250) -> [ChatMessage] {
        guard limit > 0,
              let directory = logDirectory(serverName: serverName, conversationName: conversationName),
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        let logFiles = files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let candidateLimit = limit * 4
        var messages: [ChatMessage] = []
        var remainingBytes = 512 * 1_024

        for file in logFiles where messages.count < candidateLimit && remainingBytes > 0 {
            let maximumBytes = min(remainingBytes, 128 * 1_024)
            guard let tail = readTail(of: file, maximumBytes: maximumBytes),
                  let contents = String(data: tail.data, encoding: .utf8) else { continue }
            remainingBytes -= tail.data.count

            var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if tail.wasTruncated, !lines.isEmpty { lines.removeFirst() }
            let available = candidateLimit - messages.count
            let parsed = lines.suffix(available).compactMap { parse($0, file: file) }
            messages.insert(contentsOf: parsed, at: 0)
        }

        let sortedMessages = messages.enumerated().sorted {
            if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
            return $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        var seen = Set<HistoryMessageKey>()
        let uniqueMessages = sortedMessages.filter { message in
            seen.insert(HistoryMessageKey(message)).inserted
        }
        return Array(uniqueMessages.suffix(limit))
    }

    private func logURL(
        serverName: String,
        conversationName: String,
        date: Date = Date(),
        createDirectories: Bool
    ) -> URL? {
        guard let directory = logDirectory(serverName: serverName, conversationName: conversationName) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if createDirectories { try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appendingPathComponent(formatter.string(from: date) + ".log")
    }

    private func logDirectory(serverName: String, conversationName: String) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MacRelay/Logs", isDirectory: true)
            .appendingPathComponent(safeComponent(serverName), isDirectory: true)
            .appendingPathComponent(safeComponent(conversationName), isDirectory: true)
    }

    private func readTail(of url: URL, maximumBytes: Int) -> (data: Data, wasTruncated: Bool)? {
        guard maximumBytes > 0,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let byteCount = min(fileSize, maximumBytes)
        let offset = max(0, fileSize - byteCount)
        do {
            try handle.seek(toOffset: UInt64(offset))
            return (try handle.read(upToCount: byteCount) ?? Data(), offset > 0)
        } catch {
            return nil
        }
    }

    private func parse(_ line: String, file: URL) -> ChatMessage? {
        guard line.hasPrefix("["), line.count >= 11,
              let closingBracket = line.firstIndex(of: "]") else { return nil }
        let timeStart = line.index(after: line.startIndex)
        let time = String(line[timeStart..<closingBracket])
        let contentStart = line.index(after: closingBracket)
        let content = line[contentStart...].trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let day = file.deletingPathExtension().lastPathComponent
        let timestamp = dateFormatter.date(from: "\(day) \(time)") ?? Date()

        if content.hasPrefix("<"), let end = content.firstIndex(of: ">") {
            let sender = String(content[content.index(after: content.startIndex)..<end])
            let text = content[content.index(after: end)...].trimmingCharacters(in: .whitespaces)
            return ChatMessage(timestamp: timestamp, sender: sender, text: text)
        }

        let text = content.hasPrefix("* ") ? String(content.dropFirst(2)) : content
        return ChatMessage(timestamp: timestamp, text: text, kind: .event)
    }

    private func safeComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Ukjent" : String(cleaned.prefix(120))
    }

    private func format(_ message: ChatMessage) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: message.timestamp)
        if let sender = message.sender {
            let marker = message.kind == .action ? "*" : "<\(sender)>"
            return "[\(timestamp)] \(message.kind == .action ? marker + " " + sender : marker) \(message.text)"
        }
        return "[\(timestamp)] * \(message.text)"
    }

    private struct HistoryMessageKey: Hashable {
        let secondOfDay: Int
        let sender: String?
        let text: String
        let kind: String

        init(_ message: ChatMessage) {
            let components = Calendar.current.dateComponents([.hour, .minute, .second], from: message.timestamp)
            secondOfDay = (components.hour ?? 0) * 3_600
                + (components.minute ?? 0) * 60
                + (components.second ?? 0)
            sender = message.sender?.lowercased()
            text = message.text
            kind = message.kind.rawValue
        }
    }
}
