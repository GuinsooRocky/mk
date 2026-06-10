import AVFoundation
import CoreMedia
import Speech

// MARK: - 转写数据类型

/// 转写结果的词级信息
struct WordInfo: Codable {
    let text: String
    let confidence: Float
    let alternatives: [String]
    let startTime: TimeInterval
    let duration: TimeInterval
}

/// 一次语音会话的完整转写结果
struct TranscriptionResult: Codable {
    let fullText: String
    let words: [WordInfo]
    let audioPath: String?
    let timestamp: Date
}

// MARK: - VoiceSession

/// 语音会话：使用 Apple SpeechAnalyzer (WWDC 2025) 做端侧实时转写
/// 音频采集用 AVCaptureSession（兼容蓝牙等各类音频设备）
/// AVAudioEngine 的 installTap 在蓝牙设备上不触发回调
@MainActor
final class VoiceSession {
    private var captureDelegate: AudioCaptureDelegate?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?
    private var audioFileURL: URL?

    private(set) var isRunning = false

    // 转写结果累积
    private var finalizedText = ""
    private var volatileText = ""
    private var allWords: [WordInfo] = []

    // MARK: - Live 分段流式（SenseVoice VAD）

    /// live 分段流式开关（VoiceModule 按 config.live_segment_enabled 设置）
    var liveSegmentEnabled = false
    /// 每段 SenseVoice 解码完成的回调（已 hop 到主线程、按时间顺序）
    var onLiveSegment: ((String) -> Void)?

    /// live 段回调的 Sendable sink（start 建立，stop 的 liveEnd flush 复用）
    private var liveSink: (@Sendable (String) -> Void)?

    /// 旁路一份原始 PCM（16k/16bit/mono LE）出去，给腾讯实时流式边录边发。nil = 不流式，零开销。
    var onPCM16k: (@Sendable (Data) -> Void)?

    init() {}

    nonisolated static func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Logger.log("Voice", "Microphone auth: \(granted)")
        }
    }

    nonisolated static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 开始录音 + 实时转写
    func start() async throws {
        guard Self.isAuthorized else {
            throw VoiceError.notAuthorized
        }

        finalizedText = ""
        volatileText = ""
        allWords = []

        // 1. 查找最佳中文 locale
        let bestLocale = await findChineseLocale()
        guard let bestLocale else {
            throw VoiceError.recognizerUnavailable
        }
        Logger.log("Voice", "Using locale: \(bestLocale.identifier(.bcp47))")

        // 2. 配置 SpeechTranscriber
        // - volatileResults: 实时回显
        // - alternativeTranscriptions: 给每个 final segment 拿候选列表（C1 用于英文 rescue）
        // - confidence/timeRange: 词级置信度 + 时间，给字典纠错和服务端蒸馏用
        let transcriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        self.transcriber = transcriber

        // 3. 确保语音模型已安装
        try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

        // 4. 创建 SpeechAnalyzer（processLifetime 让模型在进程内常驻，避免热键间歇被卸载）
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        self.analyzer = analyzer

        // 获取最佳音频格式
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        Logger.log("Voice", "Analyzer format: \(analyzerFormat as Any)")

        // 5. 预热模型（首次热键响应从 ~800ms 降到 <100ms）
        let prepareT0 = CFAbsoluteTimeGetCurrent()
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)
        Logger.log("Voice", "prepareToAnalyze took \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - prepareT0))s")

        // 6. 创建 AsyncStream 用于音频输入
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // 7. 启动分析器
        try await analyzer.start(inputSequence: inputSequence)

        // 7. 启动结果处理任务
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)

                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""

                        let words = self.extractWords(from: result.text)
                        self.allWords.append(contentsOf: words)

                        // C1 阶段 1：观察 SA 给的候选数据
                        let alts = result.alternatives.map { String($0.characters) }
                        let altsExceptBest = alts.filter { $0 != text }
                        if !altsExceptBest.isEmpty {
                            Logger.log("Voice", "Final segment: \(text) (\(words.count) words, \(alts.count) alts)")
                            for (i, alt) in altsExceptBest.prefix(5).enumerated() {
                                Logger.log("Voice", "  alt[\(i)]: \(alt)")
                            }
                        } else {
                            Logger.log("Voice", "Final segment: \(text) (\(words.count) words, no alts)")
                        }
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                Logger.log("Voice", "Result stream error: \(error)")
            }
        }

        // 8. 准备音频文件
        let fileName = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = WEDataDir.url.appendingPathComponent("audio/\(fileName).wav")
        audioFileURL = url

        // 9. 麦克风采集 — 走 MicCapture 热麦续命（复用热会话省冷启动 ~150ms，见 MicCapture）
        // 先建 delegate，wire 好 live 路由，最后才 acquire + attach → 样本开始流入时一切就绪
        let delegate = AudioCaptureDelegate(
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioFileURL: url,
            queue: MicCapture.shared.captureQueue
        )
        self.captureDelegate = delegate

        // live 分段流式：开 SenseVoice VAD live 会话，把采集样本路由进去；
        // 段回调用 DispatchQueue.main.async 有序 hop 到主线程（保段顺序，不用乱序的 Task{}）。
        if liveSegmentEnabled {
            let ok = await SenseVoiceEngine.shared.liveBegin()
            if ok {
                let sink: @Sendable (String) -> Void = { [weak self] text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.onLiveSegment?(text) }
                    }
                }
                self.liveSink = sink
                delegate.onSamples = { samples in
                    SenseVoiceEngine.shared.liveAccept(samples: samples, onSegment: sink)
                }
                Logger.log("Voice", "[Live] 分段流式已启用")
            } else {
                Logger.log("Voice", "[Live] liveBegin 失败，回落非流式")
            }
        }

        // 腾讯实时流式：把原始 PCM 旁路给 WS 会话边录边发（与 SA / WAV / SenseVoice 各路并行）
        if let onPCM16k { delegate.onPCM16k = onPCM16k }

        // 拿到（热复用 or 冷启动）采集输出，attach delegate → 样本开始流入
        let (audioOutput, coldStarted) = try MicCapture.shared.acquire()
        audioOutput.setSampleBufferDelegate(delegate, queue: MicCapture.shared.captureQueue)
        self.isRunning = true

        Logger.log("Voice", "Session started (\(coldStarted ? "冷启动" : "热复用") + SpeechAnalyzer)")

    }

    /// G3 → G2：运行时注入屏幕上下文到 SA（提升专有名词/术语识别率）
    func updateContext(contextualWords: [String]) async {
        guard let analyzer, !contextualWords.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualWords
        do {
            try await analyzer.setContext(context)
            let preview = contextualWords.prefix(5).joined(separator: ", ")
            let suffix = contextualWords.count > 5 ? "..." : ""
            Logger.log("Voice", "SA context injected \(contextualWords.count) contextualStrings: [\(preview)\(suffix)]")
        } catch {
            Logger.log("Voice", "SA context update failed: \(error)")
        }
    }

    /// 停止录音并等待最终结果
    /// skipLiveTail：短句快路径——live 尾段不 flush 不解码（调用方保证有引擎对整段 WAV 出定稿）
    func stop(skipLiveTail: Bool = false) async -> TranscriptionResult {
        guard isRunning else {
            return TranscriptionResult(fullText: "", words: [], audioPath: nil, timestamp: Date())
        }

        let stopT0 = CFAbsoluteTimeGetCurrent()
        let bufferCountBefore = captureDelegate?.bufferCount ?? 0

        // 停止音频采集：摘 delegate + 启动续命计时器（不立刻 stopRunning，热麦续命复用，见 MicCapture）
        MicCapture.shared.release()
        captureDelegate?.close()
        captureDelegate = nil

        let stopT1 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: capture stopped in \(String(format: "%.3f", stopT1 - stopT0))s, buffers received: \(bufferCountBefore)")
        Logger.log("Voice", "[DIAG] stop: finalizedText=\(finalizedText.count)字, volatileText=\(volatileText.count)字, words=\(allWords.count)")

        // live 分段流式：flush 尾段（残余样本 + VAD flush）→ 段经 liveSink 有序 append 到 cc。
        // await 返回时尾段的 main.async append 已全部入队在本 continuation 之前 → 收尾顺序正确。
        // 随后快速拆 SA（live 不用 SA 文本），省掉最多 5s 的 finalize。
        if liveSegmentEnabled, let sink = liveSink {
            if skipLiveTail {
                await SenseVoiceEngine.shared.liveCancel()
            } else {
                await SenseVoiceEngine.shared.liveEnd(onSegment: sink)
            }
            liveSink = nil
            inputBuilder?.finish()
            resultTask?.cancel()
            resultTask = nil
            analyzer = nil
            transcriber = nil
            isRunning = false
            Logger.log("Voice", "[Live] stop fast-teardown (跳过 SA finalize)")
            return TranscriptionResult(
                fullText: "",
                words: allWords,
                audioPath: audioFileURL?.path,
                timestamp: Date()
            )
        }

        // 告诉分析器音频结束
        inputBuilder?.finish()
        Logger.log("Voice", "[DIAG] stop: inputBuilder.finish()")

        // 等待分析器完成（带超时）
        let stopT2 = CFAbsoluteTimeGetCurrent()
        var finalizeTimedOut = false
        do {
            try await withThrowingTimeout(seconds: 5) {
                try await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
            let finalizeTime = CFAbsoluteTimeGetCurrent() - stopT2
            Logger.log("Voice", "[DIAG] stop: finalize completed in \(String(format: "%.3f", finalizeTime))s")
        } catch {
            let finalizeTime = CFAbsoluteTimeGetCurrent() - stopT2
            finalizeTimedOut = true
            Logger.log("Voice", "[DIAG] stop: finalize TIMEOUT/ERROR in \(String(format: "%.3f", finalizeTime))s: \(error)")
        }

        // 等 resultTask 自然 drain：finalize() 后 transcriber.results 流关闭，
        // for-await 循环读完队列后 Task 退出。await drainTask.value 精确等到这一刻。
        // 加 100ms 兜底超时防极端 race condition（实测 finalize 完成时 finalizedText 已齐，drain 通常 0-5ms）。
        let stopT3 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: post-finalize finalizedText=\(finalizedText.count)字, volatileText=\(volatileText.count)字")
        let drainTask = resultTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let drainTask { await drainTask.value }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await group.next()
            group.cancelAll()
        }
        resultTask?.cancel()
        resultTask = nil
        let stopT4 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: drain+cancel took \(String(format: "%.3f", stopT4 - stopT3))s")

        let fullText = finalizedText + volatileText
        isRunning = false

        // 清理
        analyzer = nil
        transcriber = nil

        // 诊断摘要
        let totalStopTime = CFAbsoluteTimeGetCurrent() - stopT0
        let lastWordEnd = allWords.last.map { $0.startTime + $0.duration } ?? 0
        Logger.log("Voice", "[DIAG] stop: SUMMARY | total=\(String(format: "%.3f", totalStopTime))s | timedOut=\(finalizeTimedOut) | finalizedText=\(finalizedText.count)字 | volatileText=\(volatileText.count)字 | fullText=\(fullText.count)字 | lastWordEnd=\(String(format: "%.1f", lastWordEnd))s | words=\(allWords.count)")
        Logger.log("Voice", "Session stopped, text: \(fullText)")

        return TranscriptionResult(
            fullText: fullText,
            words: allWords,
            audioPath: audioFileURL?.path,
            timestamp: Date()
        )
    }

    // MARK: - Locale 查找

    private func findChineseLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let ids = supported.map { $0.identifier(.bcp47) }
        Logger.log("Voice", "Supported locales: \(ids)")

        let prefixes = ["zh-Hans", "zh-CN", "zh-Hant", "zh"]
        for prefix in prefixes {
            if let match = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                return match
            }
        }

        Logger.log("Voice", "No Chinese locale found")
        return nil
    }

    // MARK: - 词级信息提取

    private func extractWords(from attrText: AttributedString) -> [WordInfo] {
        var words: [WordInfo] = []
        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        for (confidence, timeRange, range) in attrText.runs[ConfKey.self, TimeKey.self] {
            let wordText = String(attrText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let startTime = timeRange?.start.seconds ?? 0
            let duration = timeRange?.duration.seconds ?? 0

            words.append(WordInfo(
                text: wordText,
                confidence: Float(confidence ?? 1.0),
                alternatives: [],
                startTime: startTime,
                duration: duration
            ))
        }
        return words
    }

    // MARK: - 模型管理

    private func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)

        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }
        Logger.log("Voice", "Installed locales: \(installedIDs)")

        if installedIDs.contains(localeID) {
            Logger.log("Voice", "Model for \(localeID) already installed")
            return
        }

        Logger.log("Voice", "Downloading speech model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Voice", "Model downloaded")
        }
    }
}

// MARK: - 音频采集代理（nonisolated，在后台队列运行）

/// 从 AVCaptureSession 接收 CMSampleBuffer，转换为 AVAudioPCMBuffer 后
/// 喂给 SpeechAnalyzer 的 inputBuilder，同时写入 WAV 音频文件
///
/// 音频文件使用手动 WAV 写入，彻底避免 AVAudioFile 内部 AudioConverter 的 abort 崩溃
final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    /// 采集回调队列（= setSampleBufferDelegate 用的那条串行队列）。finalizeWAV 丢上去跑，消除竞争。
    private let queue: DispatchQueue
    private var converter: AVAudioConverter?
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?
    private(set) var bufferCount = 0

    /// live 分段流式：旁路一份归一化 Float 样本出去（VoiceSession 设置，路由到 SenseVoice live）。
    /// nil = 未开 live，零开销。
    var onSamples: (@Sendable ([Float]) -> Void)?

    /// 旁路一份原始 PCM（Int16 16k mono LE）给腾讯实时流式。nil = 不流式，零开销。
    var onPCM16k: (@Sendable (Data) -> Void)?

    init(inputBuilder: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat?, audioFileURL: URL, queue: DispatchQueue) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        // 改用 .wav 扩展名
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        self.queue = queue
        super.init()
    }

    /// 收尾 WAV。必须从采集队列「外」调用（现仅 stop() @MainActor 调）。
    /// queue.sync：①等掉在途的最后一帧 captureOutput（drain）②与 writeToWAV 同队列串行 → 句柄/字节数零竞争。
    func close() {
        queue.sync { finalizeWAV() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1

        // CMSampleBuffer → AVAudioPCMBuffer
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Voice", "Audio #\(bufferCount): failed to convert CMSampleBuffer") }
            return
        }

        if bufferCount <= 5 {
            Logger.log("Voice", "Audio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // 格式转换（如果采集格式 ≠ analyzer 格式）
        let outputBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat {

            // 延迟创建 converter（需要知道输入格式）
            if converter == nil {
                converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Voice", "Created converter: \(pcmBuffer.format) → \(targetFormat)")
            }

            guard let converter,
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 5 { Logger.log("Voice", "Audio #\(bufferCount): conversion failed") }
                return
            }
            outputBuffer = converted
        } else {
            outputBuffer = pcmBuffer
        }

        // 写入 WAV 文件（用 outputBuffer，格式始终一致：Int16 16kHz mono）
        writeToWAV(buffer: outputBuffer)

        // live 分段流式：旁路一份归一化 Float 样本给 SenseVoice live（不影响 SA / WAV 主路）
        if let onSamples, let floats = Self.normalizedFloats(from: outputBuffer) {
            onSamples(floats)
        }

        // 发送给 SpeechAnalyzer
        let input = AnalyzerInput(buffer: outputBuffer)
        inputBuilder.yield(input)
    }

    /// outputBuffer（analyzerFormat，16k mono；Int16 或 Float32）→ 归一化 [Float] [-1,1]。
    /// SenseVoice decode 吃归一化 Float；与 readWav 的归一化口径一致。
    private static func normalizedFloats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let ch = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: ch[0], count: n))
        case .pcmFormatInt16:
            guard let ch = buffer.int16ChannelData else { return nil }
            let p = ch[0]
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = Float(p[i]) / 32768.0 }
            return out
        default:
            return nil
        }
    }

    // MARK: - WAV 手动写入（绕过 AVAudioFile）

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        // 首次写入：创建文件 + 占位 WAV header
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            // 写入 44 字节占位 header
            fileHandle?.write(Data(count: 44))
            wavDataSize = 0
        }

        // 提取 PCM 数据
        let abl = buffer.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return }
        let byteCount = Int(abl.mBuffers.mDataByteSize)
        let data = Data(bytes: mData, count: byteCount)
        fileHandle?.write(data)
        wavDataSize += UInt32(byteCount)

        // 旁路给腾讯实时流式（同一份 Int16 16k PCM，发 WS 边录边转）
        onPCM16k?(data)
    }

    private func finalizeWAV() {
        guard let fh = fileHandle, let fmt = wavFormat else {
            fileHandle = nil
            return
        }

        let asbd = fmt.streamDescription.pointee
        let numChannels = UInt16(asbd.mChannelsPerFrame)
        let sampleRate = UInt32(asbd.mSampleRate)
        let bitsPerSample = UInt16(asbd.mBitsPerChannel)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)

        var header = Data(capacity: 44)
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16))            // chunk size
        header.appendLE(UInt16(1))             // PCM format
        header.appendLE(numChannels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        // data chunk
        header.append(contentsOf: "data".utf8)
        header.appendLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Voice", "WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - 格式转换

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        return (error == nil && output.frameLength > 0) ? output : nil
    }
}

// MARK: - Data little-endian helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        return pcmBuffer
    }
}

// MARK: - Errors & Helpers

enum VoiceError: Error {
    case recognizerUnavailable
    case notAuthorized
    case noAudioDevice
    case timeout
}

/// 带超时的 async 执行（throwing 版本）
func withThrowingTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw VoiceError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
