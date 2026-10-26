import UIKit
import WebKit
import CoreMotion
import CoreHaptics
import CryptoKit
import Security
import Network

final class WheelViewController: UIViewController, WKScriptMessageHandler,
                                 WKNavigationDelegate {
    private var web: WKWebView!
    private let motion = CMMotionManager()
    private var motionDeliveryInFlight = false
    private var motionGeneration = 0
    private var engine: CHHapticEngine?
    private var feedbackPlayer: CHHapticAdvancedPatternPlayer?
    private var curbPlayer: CHHapticPatternPlayer?
    private var limitPlayer: CHHapticPatternPlayer?
    private var limitUpdatedAt = 0.0
    private var limitStartedAt = 0.0
    private var limitTestUntil = 0.0
    private var limitTimer: DispatchSourceTimer?
    private var pedalTestPlayer: CHHapticPatternPlayer?
    private var limitCueUntil = 0.0
    private var curbCueUntil = 0.0
    private var lastCurbImpactAt = 0.0
    private var feedbackTimer: DispatchSourceTimer?
    private var feedbackUpdatedAt = 0.0
    private var feedbackStartedAt = 0.0
    private var feedbackIntensity: Float = 0
    private var feedbackSharpness: Float = 0
    private var feedbackRoughness: Float = 0
    private var socket: PinnedWebSocket?
    private var socketID: String?
    private var endpoint: URL?
    private var firstAppearance = true
    private var sendInFlight = false
    private var inputBuffer = ControlInputBuffer()
    private var lastHaptic = Date.distantPast
    private var trustPrompt: UIAlertController?
    private var trustDecision: ((Bool) -> Void)?
    private var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.tintColor = UIColor(red: 1, green: 0.53, blue: 0, alpha: 1)
        view.backgroundColor = UIColor(red: 0.04, green: 0.043, blue: 0.05, alpha: 1)
        let config = WKWebViewConfiguration()
        // Controller labels are not editable text: suppress iOS selection/loupe gestures.
        config.preferences.isTextInteractionEnabled = false
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
        stopMotion()
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
            "填写电脑方向盘地址，例如 192.168.1.10:8080。手机与电脑需在同一可信网络。连接前请关闭 iPhone 的 VPN / 代理。",
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
            alert?.dismiss(animated: true) { [weak self] in
                self?.web.evaluateJavaScript("window.__nativeReconnect();", completionHandler: nil)
            }
        })
        alert.addAction(UIAlertAction(title: "返回", style: .cancel))
        present(alert, animated: true)
    }

    private func showHapticSettings() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "震动设置", message:
            hapticsEnabled ? "轻背景、油门、刹车与路肩已开启；超出满转角后持续提示。" : "震动反馈已关闭。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: hapticsEnabled ? "关闭震动" : "开启震动", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.hapticsEnabled.toggle()
            if !self.hapticsEnabled { self.stopAllRaceFeedback() }
            if self.hapticsEnabled { self.playHaptic([90]) }
        })
        alert.addAction(UIAlertAction(title: "测试背景 → 油门反馈", style: .default) { [weak self] _ in
            self?.testPedalFeedback()
        })
        alert.addAction(UIAlertAction(title: "测试满转向提示", style: .default) { [weak self] _ in
            self?.playSteeringLimitCue(force: true)
        })
        alert.addAction(UIAlertAction(title: "测试路肩震动", style: .default) { [weak self] _ in
            self?.playCurbImpact(1, force: true)
        })
        alert.addAction(UIAlertAction(title: "返回", style: .cancel))
        present(alert, animated: true)
    }

    private func showError(_ text: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "F1 Race Controller", message: text, preferredStyle: .alert)
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
        case "stopMotion": stopMotion()
        case "tap": playHaptic([12])
        case "steeringLimit": updateSteeringLimit(active: body["active"] as? Bool ?? true)
        case "pedalTap": if socket != nil { playHaptic([24]) }
        case "curbImpact":
            playCurbImpact(body["strength"] as? Double ?? 0.8)
        case "raceFeedback":
            guard socket != nil else { stopRaceFeedback(); return }
            updateRaceFeedback(body)
        case "haptic":
            let pattern = (body["pattern"] as? [Double]) ?? [(body["pattern"] as? Double) ?? 20]
            playHaptic(pattern)
        case "open": if let id = body["id"] as? String { openSocket(id: id) }
        case "close": if body["id"] as? String == socketID { closeSocket() }
        case "send":
            if body["id"] as? String == socketID, let text = body["text"] as? String,
               text.utf8.count < 8192 {
                // Preserve discrete edges while coalescing pure axis movement.
                guard inputBuffer.enqueue(text) else { closeSocket(); return }
                flushInput()
            }
        default: break
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { showError("此设备不支持融合姿态传感器。"); return }
        guard !motion.isDeviceMotionActive else { return }
        motionGeneration += 1
        let generation = motionGeneration
        motionDeliveryInFlight = false
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        UIApplication.shared.isIdleTimerDisabled = true
        // Fused gravity excludes linear acceleration; arbitrary heading avoids magnetic jumps.
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] sample, _ in
            guard let self = self, let sample = sample,
                  self.motionGeneration == generation, !self.motionDeliveryInFlight,
                  ProcessInfo.processInfo.systemUptime - sample.timestamp < 0.05 else { return }
            let g = sample.gravity
            let rate = sample.rotationRate.z * 180.0 / Double.pi
            guard [g.x, g.y, g.z, rate, sample.timestamp].allSatisfy({ $0.isFinite }) else { return }
            self.motionDeliveryInFlight = true
            self.web.evaluateJavaScript("window.__nativeMotion(\(g.x * 9.81),\(g.y * 9.81),\(g.z * 9.81),\(rate),\(sample.timestamp));") { [weak self] _, _ in
                guard let self = self, self.motionGeneration == generation else { return }
                self.motionDeliveryInFlight = false
            }
        }
    }

    private func stopMotion() {
        motionGeneration += 1
        motion.stopDeviceMotionUpdates()
        motionDeliveryInFlight = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func prepareHapticEngine() throws -> CHHapticEngine {
        if let engine = engine { try engine.start(); return engine }
        let created = try CHHapticEngine()
        created.playsHapticsOnly = true
        created.resetHandler = { [weak self] in
            DispatchQueue.main.async { self?.stopAllRaceFeedback() }
        }
        created.stoppedHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.stopAllRaceFeedback() }
        }
        try created.start()
        engine = created
        return created
    }

    private func updateRaceFeedback(_ body: [String: Any]) {
        if body["stop"] as? Bool == true { stopAllRaceFeedback(); return }
        guard hapticsEnabled, UIApplication.shared.applicationState == .active,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            stopRaceFeedback(); return
        }
        func unit(_ key: String) -> Float {
            let value = body[key] as? Double ?? 0
            return value.isFinite ? Float(min(1, max(0, value))) : 0
        }
        feedbackIntensity = unit("intensity")
        feedbackSharpness = unit("sharpness")
        feedbackRoughness = unit("roughness")
        feedbackUpdatedAt = ProcessInfo.processInfo.systemUptime
        guard feedbackIntensity > 0.001 else { stopRaceFeedback(); return }
        do {
            if feedbackPlayer == nil {
                try startFeedbackPlayer()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now(), repeating: .milliseconds(25))
                timer.setEventHandler { [weak self] in self?.renderRaceFeedback() }
                feedbackTimer = timer
                timer.resume()
            }
            renderRaceFeedback()
        } catch { stopRaceFeedback() }
    }

    private func startFeedbackPlayer() throws {
        let engine = try prepareHapticEngine()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        ], relativeTime: 0, duration: 30)
        // Embed initial gain so the first frame cannot produce a full-strength jolt.
        let initialGain: Float = feedbackIntensity * feedbackLayerGain(at: ProcessInfo.processInfo.systemUptime)
        let pattern = try CHHapticPattern(events: [event], parameters: [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: initialGain, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: feedbackSharpness - 0.5, relativeTime: 0)
        ])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
        feedbackPlayer = player
        feedbackStartedAt = ProcessInfo.processInfo.systemUptime
    }

    private func renderRaceFeedback() {
        let now = ProcessInfo.processInfo.systemUptime
        guard hapticsEnabled, UIApplication.shared.applicationState == .active,
              now - feedbackUpdatedAt < 0.25, socket != nil else {
            stopRaceFeedback(); return
        }
        guard feedbackPlayer != nil else { return }
        do {
            if now - feedbackStartedAt > 25 {
                try? feedbackPlayer?.stop(atTime: CHHapticTimeImmediate)
                feedbackPlayer = nil
                try startFeedbackPlayer()
            }
            // A rumble-strip texture modulates continuous pedal resistance at 16 Hz.
            let pulse = Float(0.5 + 0.5 * sin(now * 2 * Double.pi * 16))
            let gain: Float = feedbackLayerGain(at: now) * feedbackIntensity * (1 - 0.65 * feedbackRoughness + 0.65 * feedbackRoughness * pulse)
            try feedbackPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: gain, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: feedbackSharpness - 0.5, relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
        } catch { stopRaceFeedback() }
    }

    private func playCurbImpact(_ requestedStrength: Double, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard (hapticsEnabled || force), UIApplication.shared.applicationState == .active,
              (socket != nil || force), requestedStrength.isFinite,
              (force || now >= limitCueUntil), now - lastCurbImpactAt >= 0.1,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        // Match the soft steering-limit texture, at a stronger 0.90...1.00 intensity.
        let strength = Float(0.9 + 0.1 * min(1, max(0, requestedStrength)))
        do {
            let engine = try prepareHapticEngine()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.18)
            ], relativeTime: 0, duration: 0.14)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try? curbPlayer?.stop(atTime: CHHapticTimeImmediate)
            curbPlayer = player
            // Temporarily duck the pedal/background layer so it cannot sharpen the cue.
            curbCueUntil = now + 0.14
            renderRaceFeedback()
            try player.start(atTime: CHHapticTimeImmediate)
            lastCurbImpactAt = now
        } catch {
            curbPlayer = nil
            curbCueUntil = 0
        }
    }

    private func feedbackLayerGain(at now: Double) -> Float {
        if now < limitCueUntil { return 0 }
        // Keep a trace of the held pedal beneath a curb cue instead of silencing it.
        return now < curbCueUntil ? 0.35 : 1
    }

    private func playSteeringLimitCue(force: Bool = false) {
        updateSteeringLimit(active: true, force: force)
    }

    private func updateSteeringLimit(active: Bool, force: Bool = false) {
        guard active else { stopSteeringLimit(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard (hapticsEnabled || force), UIApplication.shared.applicationState == .active,
              (socket != nil || force), CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            stopSteeringLimit(); return
        }
        limitUpdatedAt = now
        if force { limitTestUntil = now + 0.8 }
        limitCueUntil = max(now + 0.25, limitTestUntil)
        try? curbPlayer?.stop(atTime: CHHapticTimeImmediate)
        curbPlayer = nil; curbCueUntil = 0
        do {
            if limitPlayer == nil {
                try startSteeringLimitPlayer()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now(), repeating: .milliseconds(25))
                timer.setEventHandler { [weak self] in self?.refreshSteeringLimit() }
                limitTimer = timer; timer.resume()
            }
            renderRaceFeedback()
        } catch { stopSteeringLimit() }
    }

    private func startSteeringLimitPlayer() throws {
        let engine = try prepareHapticEngine()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.18)
        ], relativeTime: 0, duration: 30)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
        limitPlayer = player; limitStartedAt = ProcessInfo.processInfo.systemUptime
    }

    private func refreshSteeringLimit() {
        let now = ProcessInfo.processInfo.systemUptime
        let testing = now < limitTestUntil
        guard UIApplication.shared.applicationState == .active,
              testing || (hapticsEnabled && socket != nil && now - limitUpdatedAt < 0.25) else {
            stopSteeringLimit(); return
        }
        if now - limitStartedAt > 25 {
            try? limitPlayer?.stop(atTime: CHHapticTimeImmediate)
            limitPlayer = nil
            do { try startSteeringLimitPlayer() } catch { stopSteeringLimit() }
        }
    }

    private func stopSteeringLimit() {
        limitTimer?.cancel(); limitTimer = nil
        try? limitPlayer?.stop(atTime: CHHapticTimeImmediate); limitPlayer = nil
        limitCueUntil = 0; limitUpdatedAt = 0; limitTestUntil = 0
        renderRaceFeedback()
    }

    private func testPedalFeedback() {
        guard UIApplication.shared.applicationState == .active,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        stopAllRaceFeedback()
        do {
            let engine = try prepareHapticEngine()
            let events = [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.12),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)
                ], relativeTime: 0, duration: 0.65),
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.34),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.22)
                ], relativeTime: 0.85, duration: 0.65)
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            pedalTestPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch { pedalTestPlayer = nil }
    }

    private func stopAllRaceFeedback() {
        stopRaceFeedback()
        try? curbPlayer?.stop(atTime: CHHapticTimeImmediate)
        curbPlayer = nil
        curbCueUntil = 0
        stopSteeringLimit()
        try? pedalTestPlayer?.stop(atTime: CHHapticTimeImmediate)
        pedalTestPlayer = nil
    }

    private func stopRaceFeedback() {
        feedbackTimer?.cancel()
        feedbackTimer = nil
        try? feedbackPlayer?.stop(atTime: CHHapticTimeImmediate)
        feedbackPlayer = nil
        feedbackIntensity = 0
    }

    private func playHaptic(_ input: [Double], force: Bool = false) {
        guard (hapticsEnabled || force), UIApplication.shared.applicationState == .active,
              Date().timeIntervalSince(lastHaptic) > 0.045 else { return }
        lastHaptic = Date()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            _ = try prepareHapticEngine()
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
        let client = PinnedWebSocket(url: url, verify: { [weak self] trust, reply in
            guard let self = self, self.socketID == id, let host = url.host else { reply(false); return }
            self.verifyLocalServer(trust, host: host, reply: reply)
        }, onOpen: { [weak self] in
            guard let self = self, self.socketID == id else { return }
            self.emit(id, "open")
        }, onMessage: { [weak self] text in
            guard let self = self, self.socketID == id else { return }
            self.emit(id, "message", text)
        }, onFailure: { [weak self] error in
            guard let self = self, self.socketID == id else { return }
            self.reportConnectionError(error)
            self.emit(id, "error")
            self.closeSocket()
        }, onClose: { [weak self] in
            guard let self = self, self.socketID == id else { return }
            self.closeSocket()
        })
        socket = client
        client.start()
    }

    private func closeSocket() {
        stopAllRaceFeedback()
        let previous = socketID
        socketID = nil
        let decision = trustDecision
        trustDecision = nil
        decision?(false)
        trustPrompt?.dismiss(animated: true)
        trustPrompt = nil
        socket?.close()
        socket = nil
        inputBuffer.clear()
        sendInFlight = false
        if let id = previous { emit(id, "close") }
    }

    private func flushInput() {
        guard !sendInFlight, let task = socket, let text = inputBuffer.popFirst() else { return }
        sendInFlight = true
        task.send(text) { [weak self, weak task] error in
            guard let self = self, self.socket === task else { return }
            self.sendInFlight = false
            if let error = error { self.reportConnectionError(error); self.closeSocket() }
            else { self.flushInput() }
        }
    }

    private func reportConnectionError(_ error: Error) {
        let failure: NSError
        if let networkError = error as? NWError, case .tls(let code) = networkError {
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "未知 TLS 错误"
            failure = NSError(domain: "TLS", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
        } else { failure = error as NSError }
        let hint: String
        switch failure.code {
        case 54:
            hint = "连接被重置，请先关闭 iPhone 的 VPN / 代理，再点网络连接重新连接。"
        case NSURLErrorNotConnectedToInternet:
            hint = "请检查本地网络权限、VPN和手机热点连接。"
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            hint = "请先关闭 iPhone 的 VPN / 代理，再确认电脑地址、8080端口及电脑服务。"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            hint = "请先关闭 iPhone 的 VPN / 代理，再重新连接并核对电脑证书。"
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

    private func verifyLocalServer(_ trust: SecTrust, host: String, reply: @escaping (Bool) -> Void) {
        guard host == endpoint?.host, let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            reply(false); return
        }
        let der = SecCertificateCopyData(cert) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let key = "certificate:" + host
        if UserDefaults.standard.string(forKey: key) == fingerprint {
            reply(true); return
        }
        guard presentedViewController == nil else { reply(false); return }
        let alert = UIAlertController(title: "核对电脑证书", message:
            "仅在此地址属于你的电脑，且下面 SHA-256 与电脑显示的指纹一致时信任。\n\n" + fingerprint,
            preferredStyle: .alert)
        trustDecision = reply
        trustPrompt = alert
        alert.addAction(UIAlertAction(title: "指纹一致，信任此电脑", style: .default) { [weak self] _ in
            guard let self = self, let decision = self.trustDecision else { return }
            self.trustDecision = nil
            self.trustPrompt = nil
            UserDefaults.standard.set(fingerprint, forKey: key)
            decision(true)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            guard let self = self, let decision = self.trustDecision else { return }
            self.trustDecision = nil
            self.trustPrompt = nil
            decision(false)
        })
        present(alert, animated: true)
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
          document.getElementById('nativeSettingsGroup').append(b);
        });
        """
        web.evaluateJavaScript(code, completionHandler: nil)
    }
}
