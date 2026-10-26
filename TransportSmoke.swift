import Foundation
import CryptoKit
import Security

private final class Smoke {
    var client: PinnedWebSocket?
    var successes = 0
    let expected: Data
    let url = URL(string: "wss://127.0.0.1:19876/ws")!
    init(certificate: Data) { expected = Data(SHA256.hash(data: certificate)) }
    func connect(reject: Bool = false) {
        let token = "input-\(successes)"
        client = PinnedWebSocket(url: url, verify: { [weak self] trust, reply in
            guard let self = self, let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
                reply(false); return
            }
            let hash = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
            reply(!reject && hash == self.expected)
        }, onOpen: { [weak self] in
            guard !reject else { print("FAIL: rejected certificate connected"); exit(1) }
            self?.client?.send(token) { error in
                if let error = error { print("FAIL: send: \(error)"); exit(1) }
            }
        }, onMessage: { [weak self] text in
            guard let self = self, text == "echo:" + token else {
                print("FAIL: wrong echo"); exit(1)
            }
            self.successes += 1
            self.client?.close()
            print("PASS: pinned TLS + WebSocket echo + automatic Pong, connection \(self.successes)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.connect(reject: self.successes == 2)
            }
        }, onFailure: { error in
            if reject { print("PASS: certificate rejection blocks the encrypted connection"); exit(0) }
            print("FAIL: \(error)"); exit(1)
        }, onClose: {})
        client?.start()
    }
}

private var retainedSmoke: Smoke?
@main struct TransportSmoke {
    static func main() throws {
        let certificate = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        retainedSmoke = Smoke(certificate: certificate)
        retainedSmoke?.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("FAIL: smoke test timed out"); exit(1) }
        dispatchMain()
    }
}
