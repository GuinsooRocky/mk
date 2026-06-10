import Foundation
import CryptoKit

/// 腾讯云「实时语音识别（WebSocket）」作为识别引擎。
///
/// 与 TencentEngine（一句话识别 / TC3 one-shot）不同：本引擎在**录音过程中边说边传** PCM，
/// 服务器边收边转，松手时只差最后一个分片 → 把「松手后干等」从 ~800ms 压到 ~250ms 且基本恒定。
///
/// 协议：wss://asr.cloud.tencent.com/asr/v2/<appid>?<params+签名>，签名 = HMAC-SHA1（非 TC3）。
/// 文档：https://cloud.tencent.com/document/product/1093/48982
///
/// 配置（~/.mk/config.json 的 polish 段，复用 TencentEngine 的密钥，额外加 appid）：
///   "engine": "tencent"
///   "tencent_appid": "1300000000"       // 实时 WS 必填，一句话识别不需要，所以以前没填
///   "tencent_secret_id": "AKID..."
///   "tencent_secret_key": "..."
///   "tencent_eng_type": "16k_zh"        // 可选，默认 16k_zh
///
/// WS 连不上/中途挂 → 调用方回落 TencentEngine 一句话识别（整段 WAV），永不让用户空手。
enum TencentStreamingEngine {
    private static let host = "asr.cloud.tencent.com"

    /// engine=tencent 且 appid/id/key 齐全才走流式（缺 appid → 回落一句话识别）
    @MainActor
    static func isConfigured() -> Bool { config() != nil }

    @MainActor
    private static func config() -> (appid: String, id: String, key: String, engType: String)? {
        let p = RuntimeConfig.shared.polishConfig
        guard (p["engine"] as? String) == "tencent" else { return nil }
        let appid = (p["tencent_appid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (p["tencent_secret_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (p["tencent_secret_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appid.isEmpty, !id.isEmpty, !key.isEmpty else { return nil }
        let engType = (p["tencent_eng_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "16k_zh"
        return (appid, id, key, engType)
    }

    /// 开一个会话（已签名、WS 已 resume）。返回 nil = 配置缺失。
    @MainActor
    static func makeSession() -> TencentStreamingSession? {
        guard let cfg = config() else { return nil }
        return TencentStreamingSession(appid: cfg.appid, secretId: cfg.id, secretKey: cfg.key, engType: cfg.engType)
    }
}

/// 单次录音的流式会话。线程模型：feed() 来自采集队列（后台），handleMessage 来自 URLSession 回调队列，
/// 收尾/拼装走内部串行队列 + NSLock，保证 finishCont 只 resume 一次。
final class TencentStreamingSession: @unchecked Sendable, StreamingSession {
    /// 云端中间态文本（slice_type 0/1/2 都会回调），VoiceModule 路由到 HUD 浮窗。
    var onInterim: ((String) -> Void)?

    private let task: URLSessionWebSocketTask
    private let sendQueue = DispatchQueue(label: "mk.tencent.stream.send")
    private let lock = NSLock()

    // 句子拼装：index → 定稿文本（slice_type=2），interim = 当前句进行态
    private var sentences: [Int: String] = [:]
    private var interimText = ""
    private var pending = Data()
    private var totalBytes = 0
    private var finished = false
    private var finishCont: CheckedContinuation<String?, Never>?

    private let flushBytes = 3200       // 100ms @ 16k/16bit/mono；够低延迟又不碎
    private static let host = "asr.cloud.tencent.com"

    init(appid: String, secretId: String, secretKey: String, engType: String) {
        let url = Self.signedURL(appid: appid, secretId: secretId, secretKey: secretKey, engType: engType)
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        receiveLoop()
        Logger.log("TencentStream", "WS open \(engType) appid=\(appid)")
    }

    // MARK: - 边录边发

    /// 喂一片 PCM（16k/16bit/mono LE）。攒够 flushBytes 就发一帧二进制。
    func feed(_ pcm: Data) {
        sendQueue.async {
            self.pending.append(pcm)
            self.totalBytes += pcm.count
            while self.pending.count >= self.flushBytes {
                let chunk = Data(self.pending.prefix(self.flushBytes))
                self.pending.removeFirst(self.flushBytes)
                self.task.send(.data(chunk)) { _ in }
            }
        }
    }

    /// 松手：flush 余下 PCM + 发 {"type":"end"}，等 final=1（或 3s 超时）返回拼好的最终文本。
    func finish() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            sendQueue.async {
                if !self.pending.isEmpty {
                    self.task.send(.data(self.pending)) { _ in }
                    self.pending.removeAll()
                }
                self.task.send(.string("{\"type\": \"end\"}")) { _ in }
                self.finishCont = cont
                if self.finished {
                    // WS 已在松手前关闭：别等了，立即用已收文本收尾
                    self.resolve(timedOut: false)
                } else {
                    self.sendQueue.asyncAfter(deadline: .now() + 3) {
                        self.resolve(timedOut: true)
                    }
                }
            }
        }
    }

    /// 录音启动失败/异常时直接丢弃会话（不等 finish），关 WS。
    func abort() {
        sendQueue.async { self.resolve(timedOut: false) }
    }

    // MARK: - 内部

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                Logger.log("TencentStream", "WS closed: \(e.localizedDescription)")
                self.sendQueue.async { self.resolve(timedOut: false) }
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
        if let code = j["code"] as? Int, code != 0 {
            Logger.log("TencentStream", "err code=\(code) \(j["message"] ?? "")")
            sendQueue.async { self.resolve(timedOut: false) }
            return
        }
        if let r = j["result"] as? [String: Any] {
            let sliceType = r["slice_type"] as? Int ?? 1
            let text = r["voice_text_str"] as? String ?? ""
            let idx = r["index"] as? Int ?? 0
            lock.lock()
            if sliceType == 2 { sentences[idx] = text; interimText = "" }
            else { interimText = text }
            let display = assembled(includingInterim: true)
            lock.unlock()
            if let onInterim { onInterim(display) }
        }
        if (j["final"] as? Int) == 1 {
            sendQueue.async { self.resolve(timedOut: false) }
        }
    }

    /// 在 sendQueue 上调用。两件事各自幂等：①收尾记账只做一次 ②finishCont 只要在就 resume
    /// （finish 可能在 WS 已关之后才被调用，故二者解耦，避免 continuation 永不 resume 而卡死）。
    private func resolve(timedOut: Bool) {
        if !finished {
            finished = true
            if timedOut { Logger.log("TencentStream", "finish 超时 3s，用已收到的文本收尾") }
            let secs = Double(totalBytes) / 2.0 / 16000.0
            StreamUsageMeter.add(provider: "tencent", seconds: secs)
            task.cancel(with: .normalClosure, reason: nil)
        }
        if let cont = finishCont {
            finishCont = nil
            lock.lock(); let out = assembled(includingInterim: true); lock.unlock()
            cont.resume(returning: out.isEmpty ? nil : out)
        }
    }

    /// 拼装：已定稿句按 index 升序 + （可选）当前进行态。调用方需持 lock。
    private func assembled(includingInterim: Bool) -> String {
        var out = sentences.keys.sorted().map { sentences[$0] ?? "" }.joined()
        if includingInterim, !interimText.isEmpty { out += interimText }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 签名（HMAC-SHA1 v2，非 TC3）

    /// 拼 wss URL：host+path+? + 字典序参数 → HMAC-SHA1 → base64 → urlencode → &signature=
    private static func signedURL(appid: String, secretId: String, secretKey: String, engType: String) -> URL {
        let path = "/asr/v2/\(appid)"
        let now = Int(Date().timeIntervalSince1970)
        let params: [String: String] = [
            "secretid": secretId,
            "timestamp": String(now),
            "expired": String(now + 24 * 3600),
            "nonce": String(Int.random(in: 1...9_999_999)),
            "engine_model_type": engType,
            "voice_id": UUID().uuidString,
            "voice_format": "1",            // 1 = PCM
            "needvad": "0"                  // push-to-talk 自控起止，关服务端 VAD 避免半句被切
        ]
        let sortedQuery = params.keys.sorted()
            .map { "\($0)=\(params[$0]!)" }
            .joined(separator: "&")

        let signStr = host + path + "?" + sortedQuery
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(signStr.utf8),
                                                          using: SymmetricKey(data: Data(secretKey.utf8)))
        let sig = Data(mac).base64EncodedString()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")        // base64 的 +/= 都会被编码
        let encSig = sig.addingPercentEncoding(withAllowedCharacters: allowed) ?? sig

        return URL(string: "wss://\(host)\(path)?\(sortedQuery)&signature=\(encSig)")!
    }
}

/// 流式 ASR 按时长计费。本地按「provider+月份」累计已发音频时长，写 ~/.mk/stream-usage.json，
/// 每次收尾日志报本月分钟数——心里有数，避免月底被默默扣费。（各家免费额度不同，这里只记不判阈值。）
enum StreamUsageMeter {
    private static let lock = NSLock()
    private static var fileURL: URL { WEDataDir.url.appendingPathComponent("stream-usage.json") }

    static func add(provider: String, seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let key = "\(monthKey())/\(provider)"
        var store: [String: Double] = {
            guard let data = try? Data(contentsOf: fileURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
            return dict
        }()
        let total = (store[key] ?? 0) + seconds
        store[key] = total
        if let data = try? JSONSerialization.data(withJSONObject: store) {
            try? data.write(to: fileURL)
        }
        Logger.log("StreamUsage", "[\(provider)] 本月已用 \(Int(total / 60))min")
    }

    private static func monthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
