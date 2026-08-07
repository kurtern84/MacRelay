import Foundation
import Network
import Security

final class IRCConnection {
    var onLine: ((String) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?
    var onUnexpectedClose: (() -> Void)?

    private let queue = DispatchQueue(label: "no.varion.macrelay.irc", qos: .userInitiated)
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    func connect(host: String, port: Int, useTLS: Bool, allowUntrustedCertificate: Bool) {
        disconnect()

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
            self.onStateChange?(state)
            if case .ready = state {
                self.receiveNextChunk()
            }
        }
        connection.start(queue: queue)
    }

    func send(_ line: String) {
        guard let connection else { return }
        let data = Data((line + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
    }

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.emitCompleteLines()
            }

            if error == nil, !isComplete {
                self.receiveNextChunk()
            } else if isComplete, error == nil {
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
                onLine?(line)
            }
        }
    }
}
