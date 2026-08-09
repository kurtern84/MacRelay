import Foundation
import Network
import Security

public final class IRCConnection: @unchecked Sendable {
    public var onLine: ((String) -> Void)?
    public var onStateChange: ((NWConnection.State) -> Void)?
    public var onUnexpectedClose: (() -> Void)?

    private let queue = DispatchQueue(label: "no.varion.macrelay.irc", qos: .userInitiated)
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isReceiving = false

    public init() {}

    public func connect(host: String, port: Int, useTLS: Bool, allowUntrustedCertificate: Bool) {
        disconnect(reason: "erstatter eksisterende forbindelse før connect")
        debugLog("CONNECT \(host):\(port) TLS=\(useTLS)")

        guard (1...65_535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            onStateChange?(.failed(.posix(.EINVAL)))
            return
        }

        let parameters: NWParameters
        if useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            if allowUntrustedCertificate {
                sec_protocol_options_set_verify_block(
                    tlsOptions.securityProtocolOptions,
                    { _, _, completion in completion(true) },
                    queue
                )
            }
            parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            self.debugLog("STATE \(state)")
            self.onStateChange?(state)
            if case .ready = state, !self.isReceiving {
                self.isReceiving = true
                self.receiveNextChunk(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ line: String) {
        guard let connection else {
            debugLog("SEND forkastet uten aktiv forbindelse: \(redacted(line))")
            return
        }
        debugLog("SEND \(redacted(line))")
        connection.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.debugLog("SEND ERROR \(error)") }
        })
    }

    public func disconnect(reason: String = "forespurt av klienten") {
        if let connection {
            debugLog("CLOSE cancel(): \(reason)")
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connection = nil
        isReceiving = false
        receiveBuffer.removeAll(keepingCapacity: true)
    }

    private func receiveNextChunk(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.emitCompleteLines()
            }
            if error == nil, !isComplete {
                self.receiveNextChunk(on: connection)
            } else if isComplete, error == nil {
                self.isReceiving = false
                self.debugLog("RECEIVE EOF fra server")
                self.onUnexpectedClose?()
            } else if let error {
                self.isReceiving = false
                self.debugLog("RECEIVE ERROR \(error)")
                self.onUnexpectedClose?()
            }
        }
    }

    private func emitCompleteLines() {
        let delimiter = Data([13, 10])
        while let range = receiveBuffer.range(of: delimiter) {
            let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                debugLog("RECV \(line)")
                onLine?(line)
            }
        }
    }

    private func redacted(_ line: String) -> String {
        let uppercase = line.uppercased()
        if uppercase.hasPrefix("PASS ") { return "PASS <skjult>" }
        if uppercase.hasPrefix("PRIVMSG NICKSERV :IDENTIFY ") {
            return "PRIVMSG NickServ :IDENTIFY <skjult>"
        }
        return line
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[MacRelay IRC] \(message())")
        #endif
    }
}
