import Foundation
import CryptoKit

/// 腾讯云「一句话识别」作为识别引擎（与微信内置语音输入同源的腾讯 ASR）。
///
/// SA 仍全程跑——负责录音落 WAV + 即时回落。engine=tencent 时把转写文本换成腾讯云的，
/// 再交给原有管线（字典/filler/标点）收拾。腾讯失败就回落 SA，永不让用户空手。
///
/// 选「一句话识别」而非实时流式：push-to-talk「说一句=一次调用」正好匹配，
/// 且一句话识别有 5000 次/月 免费额度（音频 ≤60s / ≤3MB）。
///
/// 配置走 ~/.mk/config.json 的 polish 段：
///   "engine": "tencent"                 // 或 "sa" 切回纯本地
///   "tencent_secret_id": "AKID..."
///   "tencent_secret_key": "..."
///   "tencent_eng_type": "16k_zh"        // 可选，默认 16k_zh（中英混合）；电话音用 8k_zh
enum TencentEngine {
    private static let host = "asr.tencentcloudapi.com"
    private static let service = "asr"
    private static let action = "SentenceRecognition"
    private static let version = "2019-06-14"

    /// 专用 session：除了 per-request 超时，再封一道 timeoutIntervalForResource 总时长上限
    /// （URLSession.shared 默认 7 天——网络半死不活、数据涓流时请求会挂极久，必须封顶）。
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    /// engine=tencent 且有 secretId/secretKey 才启用
    @MainActor
    static func isActive() -> Bool {
        let p = RuntimeConfig.shared.polishConfig
        guard (p["engine"] as? String) == "tencent" else { return false }
        return config() != nil
    }

    @MainActor
    private static func config() -> (id: String, key: String, engType: String)? {
        let p = RuntimeConfig.shared.polishConfig
        let id = (p["tencent_secret_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (p["tencent_secret_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !key.isEmpty else { return nil }
        let engType = (p["tencent_eng_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "16k_zh"
        return (id, key, engType)
    }

    /// 把 WAV 发腾讯云一句话识别。任何失败返回 nil（调用方回落 SA）。
    nonisolated static func transcribe(wavPath: String) async -> String? {
        guard let cfg = await config() else { return nil }
        guard let audio = try? Data(contentsOf: URL(fileURLWithPath: wavPath)) else {
            Logger.log("TencentEngine", "读不到 wav \(wavPath)")
            return nil
        }
        // 一句话识别上限 3MB（base64 前的原始字节）
        guard audio.count <= 3 * 1024 * 1024 else {
            Logger.log("TencentEngine", "音频 \(audio.count / 1024)KB 超 3MB 上限，回落 SA")
            return nil
        }

        let payloadDict: [String: Any] = [
            "EngSerViceType": cfg.engType,
            "SourceType": 1,
            "VoiceFormat": "wav",
            // ConvertNumMode=0：关云端阿拉伯数字智能转换（默认 1）。云端会把量词「一个」转成「1个」、
            // 语气词「千万」转成数字，且不可控。收权到本地 NumberNormalizer（可加黑名单/开关）统一管。
            // 文档：https://cloud.tencent.com/document/product/1093/35646（ConvertNumMode）
            "ConvertNumMode": 0,
            "Data": audio.base64EncodedString(),
            "DataLen": audio.count
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: payloadDict),
              let payloadStr = String(data: payload, encoding: .utf8) else {
            Logger.log("TencentEngine", "payload 序列化失败")
            return nil
        }

        let ts = Int(Date().timeIntervalSince1970)
        let auth = signature(secretId: cfg.id, secretKey: cfg.key, timestamp: ts, payload: payloadStr)

        var req = URLRequest(url: URL(string: "https://\(host)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = payload
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(action, forHTTPHeaderField: "X-TC-Action")
        req.setValue(String(ts), forHTTPHeaderField: "X-TC-Timestamp")
        req.setValue(version, forHTTPHeaderField: "X-TC-Version")

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
                Logger.log("TencentEngine", "HTTP \(code): \(snippet)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["Response"] as? [String: Any] else { return nil }
            if let err = response["Error"] as? [String: Any] {
                Logger.log("TencentEngine", "API error: \(err["Code"] ?? "") \(err["Message"] ?? "")")
                return nil
            }
            guard let text = response["Result"] as? String else { return nil }
            Logger.log("TencentEngine", "\(cfg.engType) \(ms)ms \(audio.count / 1024)KB → \(text.count)字")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Logger.log("TencentEngine", "request failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - TC3-HMAC-SHA256 签名
    // 文档：https://cloud.tencent.com/document/api/1093/35640（公共参数 / 签名 v3）

    private static func signature(secretId: String, secretKey: String, timestamp: Int, payload: String) -> String {
        let signedHeaders = "content-type;host;x-tc-action"
        let canonicalHeaders =
            "content-type:application/json; charset=utf-8\n" +
            "host:\(host)\n" +
            "x-tc-action:\(action.lowercased())\n"
        let hashedPayload = sha256Hex(payload)
        // POST 到 "/"，无 query
        let canonicalRequest = [
            "POST", "/", "",
            canonicalHeaders, signedHeaders, hashedPayload
        ].joined(separator: "\n")

        let date = utcDate(timestamp)
        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(timestamp),
            credentialScope,
            sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let secretDate = hmac(key: Data("TC3\(secretKey)".utf8), msg: Data(date.utf8))
        let secretService = hmac(key: secretDate, msg: Data(service.utf8))
        let secretSigning = hmac(key: secretService, msg: Data("tc3_request".utf8))
        let signature = hmac(key: secretSigning, msg: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return "TC3-HMAC-SHA256 Credential=\(secretId)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, msg: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// 签名要求 UTC 的 yyyy-MM-dd，且必须与 X-TC-Timestamp 同一天
    private static func utcDate(_ timestamp: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
