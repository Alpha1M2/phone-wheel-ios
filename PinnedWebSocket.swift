import Foundation
import Network
import Security

/// A local-only, encrypted WebSocket with an explicit certificate-pin decision.
/// All state, verification UI and callbacks execute on the main queue.
final class PinnedWebSocket {
    private var connection: NWConnection?
    private var timeout: DispatchWorkItem?
    private var closed = false
    private var ready = false
    private let url: URL
    private let verify: (SecTrust, @escaping (Bool) -> Void) -> Void
    private let onOpen: () -> Void
    private let onMessage: (String) -> Void
    private let onFailure: (Error) -> Void
    private let onClose: () -> Void

    init(url: URL, verify: @escaping (SecTrust, @escaping (Bool) -> Void) -> Void,
         onOpen: @escaping () -> Void, onMessage: @escaping (String) -> Void,
         onFailure: @escaping (Error) -> Void, onClose: @escaping () -> Void) {
        self.url = url
        self.verify = verify
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onFailure = onFailure
        self.onClose = onClose
    }

    func start() {
        guard connection == nil, !closed else { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, reply in
            guard let self = self, !self.closed else { reply(false); return }
            let serverTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            self.verify(serverTrust) { [weak self] approved in
                reply(approved && self?.closed == false)
            }
        }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 65536
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let transport = NWConnection(to: .url(url), using: parameters)
        connection = transport
        transport.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.ready else { return }
                self.ready = true
                self.timeout?.cancel()
                self.onOpen()
                self.receive()
            case .failed(let error), .waiting(let error): self.fail(error)
            case .cancelled: self.close()
            default: break
            }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, !self.ready, !self.closed else { return }
            self.fail(URLError(.timedOut))
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: deadline)
        transport.start(queue: .main)
    }

    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        guard ready, !closed, let transport = connection else {
            completion(URLError(.notConnectedToInternet)); return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "controller-input", metadata: [metadata])
        transport.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                       completion: .contentProcessed { error in completion(error) })
    }

    private func receive() {
        guard !closed, let transport = connection else { return }
        transport.receiveMessage { [weak self] data, context, _, error in
            guard let self = self, !self.closed else { return }
            if let error = error { self.fail(error); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                self.close(); return
            }
            if let data = data, let text = String(data: data, encoding: .utf8) {
                self.onMessage(text)
            }
            self.receive()
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        onFailure(error)
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onClose()
    }
}
