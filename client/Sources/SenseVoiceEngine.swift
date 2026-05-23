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

    private var modelDir: String {
        WEDataDir.url
            .appendingPathComponent("models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17")
            .path
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

    private func transcribeOnQueue(wavPath: String) -> String? {
        guard loadOnQueue(), let rec = recognizer else { return nil }
        guard let (samples, sampleRate) = Self.readWav(wavPath) else {
            Logger.log("SenseVoice", "读不到 wav \(wavPath)")
            return nil
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let text = rec.decode(samples: samples, sampleRate: sampleRate).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.log("SenseVoice", "\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms → \(text)")
        return text.isEmpty ? nil : text
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
