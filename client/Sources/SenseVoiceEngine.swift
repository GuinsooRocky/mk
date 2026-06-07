import AVFoundation
import Foundation

/// SenseVoice 本地引擎（sherpa-onnx 原生，无 Python、无后台进程）。
///
/// 松手后整段转写。模型常驻内存（首次加载 ~几百 ms，之后只算推理）。
/// 加载与推理都在专用串行队列执行，**绝不阻塞主线程**（调用方 await）。
/// 模型文件：`~/.mk/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx`
final class SenseVoiceEngine: @unchecked Sendable {
    static let shared = SenseVoiceEngine()

    /// recognizer 只在此队列上创建/访问，保证 sherpa-onnx C 句柄不被并发触碰。
    private let queue = DispatchQueue(label: "com.lengmo.mk.sensevoice", qos: .userInitiated)
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?

    /// live 分段流式：跨 accept 调用累积的不足一窗（512）余量
    private var liveResidual: [Float] = []
    /// live 会话是否进行中（liveBegin 置 true，liveEnd 置 false）
    private var liveActive = false

    /// 短于此长度的音频直接整段解码（保持原行为、零额外延迟）。
    /// 超过则用 silero VAD 切成自然语音段逐段解码 —— SenseVoice 是 NAR 离线模型，
    /// 整段塞超长音频会延迟暴涨且中段塌掉（只剩头尾）；按停顿切段后每段都在模型舒适区。
    private static let directDecodeMaxSamples = 16_000 * 10   // 10s @16k

    private var modelDir: String {
        WEDataDir.url
            .appendingPathComponent("models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17")
            .path
    }

    /// silero VAD 模型路径（download-model.sh 下到 models 根目录，与 sense-voice 子目录平级）。
    private var vadModelPath: String {
        WEDataDir.url.appendingPathComponent("models/silero_vad.onnx").path
    }

    private init() {}

    /// 模型在不在（决定 engine=sensevoice 能不能启用）。纯文件检查，任意线程安全。
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: modelDir + "/model.int8.onnx")
    }

    /// 后台加载模型（建图慢）。已加载则立即返回 true。
    @discardableResult
    func ensureLoaded() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.loadOnQueue()) }
        }
    }

    /// 转写 WAV 文件 → 文本（失败返 nil，调用方回落 SA）。推理在后台队列跑。
    func transcribe(wavPath: String) async -> String? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.transcribeOnQueue(wavPath: wavPath)) }
        }
    }

    // MARK: - Live 分段流式（录音中逐段吐字）
    //
    // 录音时持续喂样本 → silero VAD 一遇停顿就切出语音段 → 立刻 SenseVoice 解码 → 回调段文本。
    // 全程在串行 queue 上跑，onSegment 因此天然按时间顺序回调。
    // 与松手后的 transcribe(wavPath:) 互斥使用：live 模式下上层不再走 WAV 整段重处理。

    /// 录音开始时调：确保模型+VAD 加载、reset VAD、清余量。返回 false = 缺模型，上层别开 live。
    func liveBegin() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                guard self.loadOnQueue(), let vad = self.loadVadOnQueue() else {
                    Logger.log("SenseVoice", "[Live] begin 失败：缺 recognizer/VAD 模型")
                    cont.resume(returning: false)
                    return
                }
                vad.reset()
                self.liveResidual = []
                self.liveActive = true
                Logger.log("SenseVoice", "[Live] begin")
                cont.resume(returning: true)
            }
        }
    }

    /// 录音中持续喂样本（来自采集后台队列，归一化 Float @16k）。
    /// 按 512 窗口喂 VAD，每检出完整段就解码并回调。onSegment 在本 queue 上调用（有序）。
    func liveAccept(samples: [Float], onSegment: @escaping (String) -> Void) {
        queue.async {
            guard self.liveActive, let vad = self.vad, let rec = self.recognizer else { return }
            self.liveResidual.append(contentsOf: samples)
            let window = 512
            while self.liveResidual.count >= window {
                let chunk = Array(self.liveResidual.prefix(window))
                self.liveResidual.removeFirst(window)
                vad.acceptWaveform(samples: chunk)
                self.liveDrain(vad: vad, rec: rec, onSegment: onSegment)
            }
        }
    }

    /// 松手时调：喂尾部余量 + flush 强吐在途段 → 收尾段解码回调 → 结束 live。
    func liveEnd(onSegment: @escaping (String) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                defer {
                    self.liveActive = false
                    self.liveResidual = []
                    cont.resume()
                }
                guard let vad = self.vad, let rec = self.recognizer else { return }
                if !self.liveResidual.isEmpty {
                    vad.acceptWaveform(samples: self.liveResidual)
                    self.liveResidual = []
                    self.liveDrain(vad: vad, rec: rec, onSegment: onSegment)
                }
                vad.flush()
                self.liveDrain(vad: vad, rec: rec, onSegment: onSegment)
                Logger.log("SenseVoice", "[Live] end")
            }
        }
    }

    /// 把 VAD 已切出的段逐个解码、回调（仅在 queue 上调用）。
    private func liveDrain(
        vad: SherpaOnnxVoiceActivityDetectorWrapper,
        rec: SherpaOnnxOfflineRecognizer,
        onSegment: (String) -> Void
    ) {
        while !vad.isEmpty() {
            let seg = vad.front()
            let t0 = CFAbsoluteTimeGetCurrent()
            let segText = rec.decode(samples: seg.samples, sampleRate: 16_000).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            vad.pop()
            if !segText.isEmpty {
                Logger.log("SenseVoice", "[Live] 段 \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms → \(segText)")
                onSegment(segText)
            }
        }
    }

    /// 自测（不需麦克风）：把 WAV 按 chunkSamples 小块"实时"喂进 live 路径，返回有序段文本。
    /// 验证 liveBegin/liveAccept 残余缓冲/liveDrain/liveEnd 的分块切段 + 段顺序与整段口径一致。
    func liveTestFromWav(_ path: String, chunkSamples: Int = 1600) async -> [String] {
        guard let (samples, _) = Self.readWav(path) else { return [] }
        guard await liveBegin() else { return [] }
        let box = LiveSegBox()
        let sink: (String) -> Void = { box.append($0) }
        var i = 0
        while i < samples.count {
            let end = min(i + chunkSamples, samples.count)
            liveAccept(samples: Array(samples[i..<end]), onSegment: sink)
            i = end
        }
        await liveEnd(onSegment: sink)
        return box.all()
    }

    // MARK: - 队列内部实现（仅在 queue 上调用）

    private func loadOnQueue() -> Bool {
        if recognizer != nil { return true }
        let model = modelDir + "/model.int8.onnx"
        let tokens = modelDir + "/tokens.txt"
        guard FileManager.default.fileExists(atPath: model),
              FileManager.default.fileExists(atPath: tokens) else {
            Logger.log("SenseVoice", "模型缺失: \(model)")
            return false
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let sv = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: model,
            language: "zh",   // 锁中文：auto LID 会把部分中英音频误判成 ja 吐假名；强制 zh 仍正常出中英 code-switch
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            numThreads: 4,
            senseVoice: sv
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: modelConfig
        )
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        Logger.log("SenseVoice", "模型加载 \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        return true
    }

    /// 懒加载 silero VAD（仅长音频用）。模型不在就返 nil → 调用方回落整段解码。
    private func loadVadOnQueue() -> SherpaOnnxVoiceActivityDetectorWrapper? {
        if let vad { return vad }
        guard FileManager.default.fileExists(atPath: vadModelPath) else {
            Logger.log("SenseVoice", "silero_vad 缺失，长音频回落整段解码: \(vadModelPath)")
            return nil
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let silero = sherpaOnnxSileroVadModelConfig(
            model: vadModelPath,
            threshold: 0.5,
            minSilenceDuration: 0.15,   // ≥150ms 停顿处切段（出字更碎更快；250ms 体感偏长，2026-06-02 调）
            minSpeechDuration: 0.1,     // 保住孤立短词（对/嗯/是 这类 <250ms 单音节），靠后面空文本过滤挡噪声
            windowSize: 512,
            maxSpeechDuration: 4.0      // 无停顿长独白的强切上限：连续不停说话时每 4s 强切出段解码，避免等到 10s 才返回（2026-06-07 由 10s 下调）
        )
        var config = sherpaOnnxVadModelConfig(sileroVad: silero, sampleRate: 16000, numThreads: 1)
        let v = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 30)
        vad = v
        Logger.log("SenseVoice", "silero_vad 加载 \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        return v
    }

    private func transcribeOnQueue(wavPath: String) -> String? {
        guard loadOnQueue(), let rec = recognizer else { return nil }
        guard let (samples, sampleRate) = Self.readWav(wavPath) else {
            Logger.log("SenseVoice", "读不到 wav \(wavPath)")
            return nil
        }
        let t0 = CFAbsoluteTimeGetCurrent()

        let text: String
        if samples.count > Self.directDecodeMaxSamples, let vad = loadVadOnQueue() {
            // 长音频：VAD 切段逐解
            text = transcribeSegmented(samples: samples, sampleRate: sampleRate, rec: rec, vad: vad)
        } else {
            // 短音频（或无 VAD 模型）：保持原整段解码
            text = rec.decode(samples: samples, sampleRate: sampleRate).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        Logger.log("SenseVoice", "\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (\(samples.count / 16_000)s) → \(text)")
        return text.isEmpty ? nil : text
    }

    /// silero VAD 切段：按 512 样本窗口喂入 → 检出语音段就逐段解码 → 喂尾部余量 → flush 收尾段。
    /// 尾部余量必须显式喂：松手常在说话中途结束，最后不足一窗的样本不喂进去就丢尾巴；
    /// flush 只能强制吐出「已喂入、还没遇尾静音」的在途段，喂不进去的样本它救不回来。
    private func transcribeSegmented(
        samples: [Float],
        sampleRate: Int,
        rec: SherpaOnnxOfflineRecognizer,
        vad: SherpaOnnxVoiceActivityDetectorWrapper
    ) -> String {
        vad.reset()  // 清掉上一次会话的内部缓冲/状态
        var parts: [String] = []

        func drain() {
            while !vad.isEmpty() {
                let seg = vad.front()
                let segText = rec.decode(samples: seg.samples, sampleRate: sampleRate).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segText.isEmpty { parts.append(segText) }
                vad.pop()
            }
        }

        let window = 512  // silero @16k 固定窗口
        var i = 0
        while i + window <= samples.count {
            vad.acceptWaveform(samples: Array(samples[i..<i + window]))
            i += window
            drain()
        }
        if i < samples.count {          // 不足一窗的尾部余量也得喂，否则丢尾巴
            vad.acceptWaveform(samples: Array(samples[i..<samples.count]))
            drain()
        }
        vad.flush()                     // 强制吐出未遇尾静音的在途段
        drain()

        // VAD 没切出可用语音（纯噪声/低能量，或切出的段全解成空）→ 返回空让上层回落 SA。
        // SA 全程跑过、对长音频不丢中段，是比"整段重解码"更好的兜底（整段重解会重演中段塌的老 bug）。
        if parts.isEmpty {
            Logger.log("SenseVoice", "[VAD] 无可用语音段，回落 SA")
            return ""
        }
        Logger.log("SenseVoice", "[VAD] \(parts.count) 段")
        return Self.joinSegments(parts)
    }

    /// 拼接段文本：下一段以 ASCII 字母/数字开头、且当前尾字符非空白时补一个空格
    /// （"done."/"hello"/"你好" + "Next" → "… Next"，修跨段英文粘连）；
    /// 下一段首字是 CJK 则不补（"你好"+"世界"→"你好世界"），避免中文里塞空格。
    private static func joinSegments(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if let last = out.last, let first = p.first,
               !last.isWhitespace,
               first.isASCII, first.isLetter || first.isNumber {
                out += " "
            }
            out += p
        }
        return out
    }

    /// 读 16k mono WAV → 归一化 [Float]。AVAudioFile.processingFormat 恒为 float32 deinterleaved。
    private static func readWav(_ path: String) -> (samples: [Float], sampleRate: Int)? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: ch[0], count: n)), Int(fmt.sampleRate))
    }
}

/// live 自测用的线程安全段收集器（onSegment 在 SenseVoice 队列上回调）。
private final class LiveSegBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}
