import AppKit
import Foundation

final class LogManager {
    private let fileManager = FileManager.default

    func append(_ message: ChatMessage, serverName: String, conversationName: String) {
        guard let url = logURL(serverName: serverName, conversationName: conversationName, createDirectories: true) else { return }
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

    private func logURL(serverName: String, conversationName: String, createDirectories: Bool) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = appSupport
            .appendingPathComponent("MacRelay/Logs", isDirectory: true)
            .appendingPathComponent(safeComponent(serverName), isDirectory: true)
            .appendingPathComponent(safeComponent(conversationName), isDirectory: true)
        if createDirectories { try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appendingPathComponent(formatter.string(from: Date()) + ".log")
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
}
