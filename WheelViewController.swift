import UIKit
import WebKit
import CoreMotion
import CoreHaptics
import CryptoKit
import Security

final class WheelViewController: UIViewController, WKScriptMessageHandler,
                                 WKNavigationDelegate, URLSessionWebSocketDelegate {
    private var web: WKWebView!
    private let motion = CMMotionManager()
    private var engine: CHHapticEngine?
    private var socket: URLSessionWebSocketTask?
    private var socketID: String?
    private var endpoint: URL?
    private var firstAppearance = true
    private var sendInFlight = false
    private var pendingInput: String?
    private var lastHaptic = Date.distantPast
    private var session: URLSession?
    private var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.043, blue: 0.05, alpha: 1)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "phoneWheel")
        if let path = Bundle.main.url(forResource: "NativeBridge", withExtension: "js"),
           let code = try? String(contentsOf: path) {
            config.userContentController.addUserScript(WKUserScript(source: code,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = view.backgroundColor
        web.scrollView.backgroundColor = view.backgroundColor
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        if let html = Bundle.main.url(forResource: "index", withExtension: "html") {
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        NotificationCenter.default.addObserver(self, selector: #selector(background),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(active),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if firstAppearance { firstAppearance = false; showConnectionSettings() }
    }

    @objc private func background() {
        web.evaluateJavaScript("if(typeof stop==='function')stop();", completionHandler: nil)
        motion.stopAccelerometerUpdates()
        closeSocket()
        engine?.stop(completionHandler: nil)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    @objc private func active() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func localEndpoint(_ address: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "wss://", with: "")
        guard let c = URLComponents(string: "wss://" + value),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let host = c.host else { return nil }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
              octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
                (octets[0] == 172 && (16...31).contains(octets[1])) else { return nil }
        var result = c
        result.port = c.port ?? 8080
        result.path = "/ws"
        return result.url
    }

    private func showConnectionSettings() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "连接电脑", message:
            "填写电脑方向盘地址，例如 192.168.1.10:8080。手机与电脑需在同一可信网络。",
            preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "电脑 IPv4:8080"
            $0.text = UserDefaults.standard.string(forKey: "computerAddress")
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.keyboardType = .numbersAndPunctuation
        }
        alert.addAction(UIAlertAction(title: "连接", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let address = alert?.textFields?.first?.text ?? ""
            guard let url = self.localEndpoint(address) else {
                DispatchQueue.main.async { self.showError("地址需为局域网 IPv4，可附带端口。") }
                return
            }
            self.endpoint = url
            UserDefaults.standard.set(address, forKey: "computerAddress")
            self.closeSocket()
            self.web.evaluateJavaScript("if(typeof stop==='function')stop();", completionHandler: nil)
        })
        alert.addAction(UIAlertAction(title: "返回", style: .cancel))
        present(alert, animated: true)
    }

    private func showHapticSettings() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "震动设置", message:
            hapticsEnabled ? "震动反馈已开启。" : "震动反馈已关闭。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: hapticsEnabled ? "关闭震动" : "开启震动", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.hapticsEnabled.toggle()
            if self.hapticsEnabled { self.playHaptic([90]) }
        })
        alert.addAction(UIAlertAction(title: "测试震动", style: .default) { [weak self] _ in
            self?.playHaptic([120, 80, 120], force: true)
        })
        alert.addAction(UIAlertAction(title: "返回", style: .cancel))
        present(alert, animated: true)
    }

    private func showError(_ text: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "手机方向盘", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "networkSettings": showConnectionSettings()
        case "hapticSettings": showHapticSettings()
        case "motion": startMotion()
        case "tap": playHaptic([12])
        case "haptic":
            let pattern = (body["pattern"] as? [Double]) ?? [(body["pattern"] as? Double) ?? 20]
            playHaptic(pattern)
        case "open": if let id = body["id"] as? String { openSocket(id: id) }
        case "close": if body["id"] as? String == socketID { closeSocket() }
        case "send":
            if body["id"] as? String == socketID, let text = body["text"] as? String,
               text.utf8.count < 8192 {
                // Keep only the latest input if the network falls behind.
                pendingInput = text
                flushInput()
            }
        default: break
        }
    }

    private func startMotion() {
        guard motion.isAccelerometerAvailable else { showError("此设备不支持加速度传感器。"); return }
        guard !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 60.0
        UIApplication.shared.isIdleTimerDisabled = true
        motion.startAccelerometerUpdates(to: .main) { [weak self] sample, _ in
            guard let self = self, let g = sample?.acceleration else { return }
            self.web.evaluateJavaScript("window.__nativeMotion(\(g.x * 9.81),\(g.y * 9.81),\(g.z * 9.81));", completionHandler: nil)
        }
    }

    private func playHaptic(_ input: [Double], force: Bool = false) {
        guard (hapticsEnabled || force), UIApplication.shared.applicationState == .active,
              Date().timeIntervalSince(lastHaptic) > 0.045 else { return }
        lastHaptic = Date()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                engine = try CHHapticEngine()
                engine?.playsHapticsOnly = true
                engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            }
            try engine?.start()
            var events: [CHHapticEvent] = []
            var time = 0.0
            for (index, value) in input.prefix(10).enumerated() {
                let duration = min(0.3, max(0, value.isFinite ? value / 1000 : 0))
                if index % 2 == 0 && duration > 0 {
                    events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.65),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
                    ], relativeTime: time, duration: duration))
                }
                time += duration
                if time >= 1 { break }
            }
            guard !events.isEmpty else { return }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func emit(_ id: String, _ kind: String, _ payload: String = "") {
        guard let data = try? JSONSerialization.data(withJSONObject: [id, kind, payload]),
              let arguments = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.__nativeSocketEvent(...\(arguments));", completionHandler: nil)
    }

    private func openSocket(id: String) {
        closeSocket()
        if endpoint == nil, let address = UserDefaults.standard.string(forKey: "computerAddress") {
            endpoint = localEndpoint(address)
        }
        guard let url = endpoint else {
            emit(id, "error"); emit(id, "close"); showConnectionSettings(); return
        }
        socketID = id
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12
        let connectionSession = URLSession(configuration: config, delegate: self,
                                           delegateQueue: OperationQueue.main)
        session = connectionSession
        let task = connectionSession.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(task, id: id)
    }

    private func closeSocket() {
        let previous = socketID
        socketID = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        pendingInput = nil
        sendInFlight = false
        if let id = previous { emit(id, "close") }
    }

    private func flushInput() {
        guard !sendInFlight, let text = pendingInput, let task = socket else { return }
        pendingInput = nil
        sendInFlight = true
        task.send(.string(text)) { [weak self, weak task] error in
            DispatchQueue.main.async {
                guard let self = self, self.socket === task else { return }
                self.sendInFlight = false
                if let error = error { self.reportConnectionError(error); self.closeSocket() } else { self.flushInput() }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, id: String) {
        task.receive { [weak self, weak task] result in
            DispatchQueue.main.async {
                guard let self = self, let task = task, self.socket === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.emit(id, "message", text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.emit(id, "message", text) }
                    @unknown default: break
                    }
                    self.receive(task, id: id)
                case .failure(let error):
                    self.reportConnectionError(error)
                    self.emit(id, "error")
                    self.closeSocket()
                }
            }
        }
    }

    private func reportConnectionError(_ error: Error) {
        let failure = error as NSError
        let hint: String
        switch failure.code {
        case NSURLErrorNotConnectedToInternet:
            hint = "请检查本地网络权限、VPN和手机热点连接。"
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            hint = "请确认电脑地址、8080端口及电脑服务。"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            hint = "请重新连接并核对电脑证书。"
        default: hint = ""
        }
        let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        let detail = underlying.map { " [\($0.domain):\($0.code)]" } ?? ""
        let text = "连接失败 (\(failure.code))：\(failure.localizedDescription)\(detail) \(hint)"
        if let data = try? JSONSerialization.data(withJSONObject: [text]),
           let json = String(data: data, encoding: .utf8) {
            web.evaluateJavaScript("window.__nativeLastError=\(json)[0]; document.querySelectorAll('#statusText,#statusText2').forEach(e=>e.textContent=window.__nativeLastError);", completionHandler: nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol negotiatedProtocol: String?) {
        if socket === webSocketTask, let id = socketID { emit(id, "open") }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if socket === webSocketTask { closeSocket() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleTrustChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleTrustChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleTrustChallenge(_ challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == endpoint?.host,
              let trust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let der = SecCertificateCopyData(cert) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let key = "certificate:" + challenge.protectionSpace.host
        if UserDefaults.standard.string(forKey: key) == fingerprint {
            acceptApprovedCertificate(trust, certificate: cert, completionHandler: completionHandler)
            return
        }
        guard presentedViewController == nil else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let alert = UIAlertController(title: "核对电脑证书", message:
            "仅在此地址属于你的电脑，且下面 SHA-256 与电脑显示的指纹一致时信任。\n\n" + fingerprint,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "指纹一致，信任此电脑", style: .default) { _ in
            UserDefaults.standard.set(fingerprint, forKey: key)
            self.acceptApprovedCertificate(trust, certificate: cert, completionHandler: completionHandler)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
            completionHandler(.cancelAuthenticationChallenge, nil)
        })
        present(alert, animated: true)
    }

    private func acceptApprovedCertificate(_ trust: SecTrust, certificate: SecCertificate,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only the exact certificate fingerprint approved above may be an anchor.
        // Preserve URLSession's hostname, validity and TLS policy evaluation.
        guard SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let code = """
        ['certBtn','certBtn2','fullscreenBtn1','fullscreenBtn2'].forEach(id=>{const e=document.getElementById(id);if(e)e.style.display='none';});
        [['nativeNetworkSettings','网络连接','networkSettings'],['nativeHapticSettings','震动设置','hapticSettings']].forEach(([id,title,kind])=>{
          if(document.getElementById(id))return;
          const b=document.createElement('button'); b.id=id; b.textContent=title;
          b.onclick=()=>window.webkit.messageHandlers.phoneWheel.postMessage({kind});
          document.getElementById('settingsPanel').append(b);
        });
        """
        web.evaluateJavaScript(code, completionHandler: nil)
    }
}
