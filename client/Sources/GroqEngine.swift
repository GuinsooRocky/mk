import Foundation

/// Groq Whisper 作为识别引擎（替换 Apple SpeechAnalyzer 的裸输出）。
///
/// SA 仍全程跑——负责录音落 WAV + 即时回落。engine=groq 时把转写文本换成 Groq 的，
/// 再交给原有管线（字典/filler/标点）收拾。Groq 失败就回落 SA，永不让用户空手。
///
/// 配置走 ~/.mk/config.json 的 polish 段：
///   "engine": "groq"                    // 或 "sa" 切回纯本地
///   "groq_api_key": "gsk_..."
///   "groq_model": "whisper-large-v3"    // 想更快换 whisper-large-v3-turbo
enum GroqEngine {
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    /// engine=groq 且有 key 才启用
    @MainActor
    static func isActive() -> Bool {
        let p = RuntimeConfig.shared.polishConfig
        guard (p["engine"] as? String) == "groq" else { return false }
        let key = (p["groq_api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    @MainActor
    private static func config() -> (key: String, model: String)? {
        let p = RuntimeConfig.shared.polishConfig
        let key = (p["groq_api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }
        let model = (p["groq_model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "whisper-large-v3"
        return (key, model)
    }

    /// 把 WAV 发 Groq 转写。任何失败返回 nil（调用方回落 SA）。
    nonisolated static func transcribe(wavPath: String) async -> String? {
        guard let cfg = await config() else { return nil }
        guard let audio = try? Data(contentsOf: URL(fileURLWithPath: wavPath)) else {
            Logger.log("GroqEngine", "读不到 wav \(wavPath)")
            return nil
        }
        let fileName = URL(fileURLWithPath: wavPath).lastPathComponent
        let boundary = "mk-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body(boundary: boundary, model: cfg.model, fileName: fileName, audio: audio)

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
                Logger.log("GroqEngine", "HTTP \(code): \(snippet)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return nil }
            Logger.log("GroqEngine", "\(cfg.model) \(ms)ms \(audio.count / 1024)KB → \(text.count)字")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Logger.log("GroqEngine", "request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func body(boundary: String, model: String, fileName: String, audio: Data) -> Data {
        var b = Data()
        func field(_ name: String, _ value: String) {
            b.append("--\(boundary)\r\n".data(using: .utf8)!)
            b.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            b.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        // 不传 language：让 Whisper 自动检测，才扛得住中英混杂
        b.append("--\(boundary)\r\n".data(using: .utf8)!)
        b.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        b.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        b.append(audio)
        b.append("\r\n".data(using: .utf8)!)
        b.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return b
    }
}
