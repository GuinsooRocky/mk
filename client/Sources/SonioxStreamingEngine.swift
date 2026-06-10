import Foundation

/// 流式识别会话的统一接口（各 provider 实现：Soniox / 腾讯 …）。
/// VoiceModule 只面向本协议，换 provider 不动主流程。
protocol StreamingSession: AnyObject {
    /// 中间态文本回调（实时展示，VoiceModule 路由到 HUD 浮窗）
    var onInterim: ((String) -> Void)? { get set }
    /// 喂一片 PCM（16k/16bit/mono LE）
    func feed(_ pcm: Data)
    /// 松手收尾，返回最终定稿文本（nil = 没出文本，调用方回落一句话识别）
    func finish() async -> String?
    /// 录音异常时直接丢弃会话
    func abort()
}

/// 按 config.polish.stream_provider 选 provider 开会话。nil = 不流式（走一句话识别）。
enum StreamingEngine {
    @MainActor
    static func makeSession() -> (any StreamingSession)? {
        switch RuntimeConfig.shared.polishConfig["stream_provider"] as? String {
        case "soniox": return SonioxStreamingEngine.makeSession()
        case "tencent": return TencentStreamingEngine.makeSession()
        default: return nil
        }
    }
}

/// Soniox 实时识别（stt-rt-v4）。WebSocket：首帧发 JSON 配置（含 api_key），之后推 PCM；
/// 服务端按 token 流回，每个 token 带 is_final——非 final = 实时展示，松手 finalize 后翻 final = 刷新定稿。
/// 全球多区（US/EU/JP），选 JP 端点东京本地最快、且数据留东京（书面 data-residency）。
/// 文档：https://soniox.com/docs/stt/api-reference/websocket-api
///
/// config（~/.mk/config.json polish 段）：
///   "stream_provider": "soniox"
///   "soniox_api_key": "..."        // console.soniox.com 建的「JP 区 Project」长期 key
///   "soniox_region": "jp"          // 可选，默认 jp（东京）；us / eu
enum SonioxStreamingEngine {
    @MainActor
    static func isConfigured() -> Bool { config() != nil }

    @MainActor
    private static func config() -> (apiKey: String, region: String)? {
        let p = RuntimeConfig.shared.polishConfig
        let key = (p["soniox_api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }
        let region = (p["soniox_region"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "jp"
        return (key, region)
    }

    @MainActor
    static func makeSession() -> (any StreamingSession)? {
        guard let cfg = config() else { return nil }
        return SonioxStreamingSession(apiKey: cfg.apiKey, region: cfg.region)
    }
}

/// 线程模型同 TencentStreamingSession：feed 来自采集队列、handleMessage 来自 WS 回调队列，
/// 收尾走内部串行队列 + NSLock，finishCont 只 resume 一次。
final class SonioxStreamingSession: @unchecked Sendable, StreamingSession {
    var onInterim: ((String) -> Void)?

    private let task: URLSessionWebSocketTask
    private let sendQueue = DispatchQueue(label: "mk.soniox.stream.send")
    private let lock = NSLock()

    private var committed = ""          // is_final token 累积（定稿）
    private var preview = ""            // 当前非 final token（实时展示尾巴）
    private var totalBytes = 0
    private var finished = false
    private var finishCont: CheckedContinuation<String?, Never>?

    init(apiKey: String, region: String) {
        let host: String
        switch region {
        case "us": host = "stt-rt.soniox.com"
        case "eu": host = "stt-rt.eu.soniox.com"
        default:   host = "stt-rt.jp.soniox.com"   // 东京
        }
        task = URLSession.shared.webSocketTask(with: URL(string: "wss://\(host)/transcribe-websocket")!)
        task.resume()
        receiveLoop()

        // 首帧：JSON 配置（鉴权写这里，不是 header）。s16le = PCM 16bit LE；中英 language_hints。
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": "stt-rt-v4",
            "audio_format": "s16le",
            "num_channels": 1,
            "sample_rate": 16000,
            "language_hints": ["zh", "en"],
            "enable_endpoint_detection": true
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let s = String(data: data, encoding: .utf8) {
            task.send(.string(s)) { _ in }
        }
        Logger.log("Soniox", "WS open region=\(region) model=stt-rt-v4")
    }

    func feed(_ pcm: Data) {
        sendQueue.async {
            self.totalBytes += pcm.count
            self.task.send(.data(pcm)) { _ in }
        }
    }

    /// 松手：发 finalize（翻定稿）+ 空帧（结束会话），等 finished:true（或 3s 超时）返回定稿文本。
    func finish() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            sendQueue.async {
                self.task.send(.string("{\"type\": \"finalize\"}")) { _ in }
                self.task.send(.data(Data())) { _ in }   // 空二进制帧 = 结束信号
                self.finishCont = cont
                if self.finished {
                    self.resolve()
                } else {
                    self.sendQueue.asyncAfter(deadline: .now() + 3) { self.resolve() }
                }
            }
        }
    }

    func abort() { sendQueue.async { self.resolve() } }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                Logger.log("Soniox", "WS closed: \(e.localizedDescription)")
                self.sendQueue.async { self.resolve() }
            case .success(let msg):
                switch msg {
                case .string(let s): self.handleMessage(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handleMessage(s) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handleMessage(_ s: String) {
        guard let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let code = j["error_code"] {
            Logger.log("Soniox", "err \(code) \(j["error_type"] ?? "") \(j["error_message"] ?? "")")
            sendQueue.async { self.resolve() }
            return
        }
        if let tokens = j["tokens"] as? [[String: Any]] {
            lock.lock()
            var newPreview = ""
            for t in tokens {
                let text = t["text"] as? String ?? ""
                if text == "<fin>" || text == "<end>" { continue }   // 段落标记，不入文本
                if (t["is_final"] as? Bool) == true {
                    committed += text
                } else {
                    newPreview += text
                }
            }
            preview = newPreview
            let display = (committed + preview).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            if let onInterim { onInterim(display) }
        }
        if (j["finished"] as? Bool) == true {
            sendQueue.async { self.resolve() }
        }
    }

    /// 在 sendQueue 上调用。收尾记账只做一次；finishCont 只要在就 resume（解耦防卡死，同 Tencent）。
    private func resolve() {
        if !finished {
            finished = true
            let secs = Double(totalBytes) / 2.0 / 16000.0
            StreamUsageMeter.add(provider: "soniox", seconds: secs)
            task.cancel(with: .normalClosure, reason: nil)
        }
        if let cont = finishCont {
            finishCont = nil
            lock.lock(); let out = (committed + preview).trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock()
            cont.resume(returning: out.isEmpty ? nil : out)
        }
    }
}
