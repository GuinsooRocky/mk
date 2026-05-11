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
    private var captureSession: AVCaptureSession?
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

    /// 识别完成时的回调
    var onResult: ((TranscriptionResult) -> Void)?

    /// 实时部分结果回调（可选，用于 UI 显示）
    var onPartialResult: ((String) -> Void)?

    // MARK: - Chunk 流式

    /// 分块流式间隔（毫秒）；0 = 禁用（默认）。打开后每隔此时间主动重启 SA 拿一段累计文本。
    var chunkIntervalMs: Int = 0

    /// 每次 chunk 完成时的回调，参数是**从录音开始至今**的累积文本。
    var onFinalChunk: ((String) -> Void)?

    /// 已经 commit 过的 chunk 累计文本（chunk 之间不丢，stop 时 + 当前 finalize 输出 = 完整 fullText）
    private var cumulativeChunkText: String = ""

    /// 防止 chunk timer 与正在执行的 flushChunk 重入
    private var flushInProgress: Bool = false

    /// stop 已开始 — 阻止后续 flushChunk 触发（防 chunk timer 跟 stop 抢资源 → state 卡死）
    private var isStopping: Bool = false

    /// chunk 定时器 task
    private var chunkTimer: Task<Void, Never>?

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
        cumulativeChunkText = ""
        flushInProgress = false
        isStopping = false

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
                        self.onPartialResult?(self.finalizedText + text)
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

        // 9. 启动 AVCaptureSession（替代 AVAudioEngine，兼容蓝牙设备）
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw VoiceError.noAudioDevice
        }
        Logger.log("Voice", "Audio device: \(audioDevice.localizedName)")

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        let captureQueue = DispatchQueue(label: "com.lengmo.mk.audio-capture")

        // 创建 delegate，捕获所有需要的局部变量（避免访问 @MainActor 的 self）
        let delegate = AudioCaptureDelegate(
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioFileURL: url
        )
        audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.addOutput(audioOutput)

        self.captureDelegate = delegate
        self.captureSession = session

        session.startRunning()
        self.isRunning = true

        Logger.log("Voice", "Session started (AVCaptureSession + SpeechAnalyzer)")

        // 启动 chunk 定时器（如果开启）
        if chunkIntervalMs > 0 {
            let intervalMs = chunkIntervalMs
            chunkTimer = Task { [weak self] in
                while !(Task.isCancelled) {
                    try? await Task.sleep(for: .milliseconds(intervalMs))
                    if Task.isCancelled { break }
                    guard let self else { break }
                    let stillRunning = await MainActor.run { self.isRunning }
                    if !stillRunning { break }
                    await self.flushChunk()
                }
            }
            Logger.log("Voice", "Chunk timer started (interval=\(chunkIntervalMs)ms)")
        }
    }

    /// chunk timer 触发：把当前 SA 终结、拿累计文本、原子切换到一个新 SA
    /// 关键：captureDelegate 的 inputBuilder 通过 swapInputBuilder 原子换；音频流不停。
    /// stop 已开始时立即返回（防 chunk timer 跟 stop 抢资源 → state 卡死）
    private func flushChunk() async {
        guard isRunning, !isStopping, !flushInProgress else { return }
        flushInProgress = true
        defer { flushInProgress = false }

        let chunkT0 = CFAbsoluteTimeGetCurrent()

        // 1. 创建一套新的 SA pipeline
        let bestLocale = await findChineseLocale()
        guard let bestLocale, let analyzerFormat = self.analyzerFormat else {
            Logger.log("Voice", "[Chunk] missing locale/format, skip")
            return
        }
        let newTranscriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let newAnalyzer = SpeechAnalyzer(
            modules: [newTranscriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try? await newAnalyzer.prepareToAnalyze(in: analyzerFormat)
        let (newSequence, newBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        do {
            try await newAnalyzer.start(inputSequence: newSequence)
        } catch {
            Logger.log("Voice", "[Chunk] new analyzer.start failed: \(error)")
            return
        }

        let newResultTask: Task<Void, Never> = Task { [weak self] in
            do {
                for try await result in newTranscriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                        let words = self.extractWords(from: result.text)
                        self.allWords.append(contentsOf: words)
                    } else {
                        self.volatileText = text
                        self.onPartialResult?(self.cumulativeChunkText + self.finalizedText + text)
                    }
                }
            } catch {
                Logger.log("Voice", "[Chunk] new SA result error: \(error)")
            }
        }

        // 2. 原子切换 captureDelegate 的 builder（音频从此流向新 SA）
        let oldAnalyzer = self.analyzer
        let oldBuilder = self.inputBuilder
        let oldResultTask = self.resultTask
        captureDelegate?.swapInputBuilder(to: newBuilder)
        self.analyzer = newAnalyzer
        self.transcriber = newTranscriber
        self.inputBuilder = newBuilder
        self.resultTask = newResultTask

        // 3. 给老 SA 收尾，拿累计文本
        oldBuilder?.finish()
        if let oldAnalyzer {
            try? await withThrowingTimeout(seconds: 2) {
                try await oldAnalyzer.finalizeAndFinishThroughEndOfInput()
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                if let oldResultTask { await oldResultTask.value }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
            }
            await group.next()
            group.cancelAll()
        }
        oldResultTask?.cancel()

        // 4. 拿到这一段（老 SA 的）累计文本，加到 cumulativeChunkText
        // 砍掉 chunk 末尾的「。」+ 空白：SA finalize 每个 chunk 都会加假句号（chunk 边界 ≠ 真句号）
        // 真句号在松手时由全文 SA finalize / PunctuationNormalizer 决定
        var chunkOnlyText = finalizedText + volatileText
        while let last = chunkOnlyText.last, last == "。" || last.isWhitespace {
            chunkOnlyText.removeLast()
        }
        finalizedText = ""
        volatileText = ""
        cumulativeChunkText += chunkOnlyText

        let chunkMs = Int((CFAbsoluteTimeGetCurrent() - chunkT0) * 1000)
        Logger.log("Voice", "[Chunk] flush \(chunkMs)ms +\(chunkOnlyText.count)字 → cumulative=\(cumulativeChunkText.count)字: \(chunkOnlyText)")

        if !chunkOnlyText.isEmpty {
            onFinalChunk?(cumulativeChunkText)
        }
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
    func stop() async -> TranscriptionResult {
        guard isRunning else {
            return TranscriptionResult(fullText: "", words: [], audioPath: nil, timestamp: Date())
        }

        // 先打 stop 标记 + 停 chunk 定时器，避免 stop 与 flushChunk 同时跑
        // 注意：Task.cancel() 协作式取消，flushChunk 入口会检查 isStopping；这里再等当前 flush 完成（最多 200ms）
        isStopping = true
        chunkTimer?.cancel()
        chunkTimer = nil

        // 等待可能正在跑的 flushChunk 完成（最多 200ms）
        var waitMs = 0
        while flushInProgress && waitMs < 200 {
            try? await Task.sleep(for: .milliseconds(20))
            waitMs += 20
        }
        if flushInProgress {
            Logger.log("Voice", "[DIAG] stop: flushChunk still running after 200ms wait, proceeding anyway")
        }

        let stopT0 = CFAbsoluteTimeGetCurrent()
        let bufferCountBefore = captureDelegate?.bufferCount ?? 0

        // 停止音频采集
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate?.close()
        captureDelegate = nil

        let stopT1 = CFAbsoluteTimeGetCurrent()
        Logger.log("Voice", "[DIAG] stop: capture stopped in \(String(format: "%.3f", stopT1 - stopT0))s, buffers received: \(bufferCountBefore)")
        Logger.log("Voice", "[DIAG] stop: finalizedText=\(finalizedText.count)字, volatileText=\(volatileText.count)字, words=\(allWords.count)")

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

        // chunk 流式：fullText = 之前所有 chunk 的累积 + 这次 stop 收到的尾段
        let tailText = finalizedText + volatileText
        let fullText = cumulativeChunkText + tailText
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

    // MARK: - WAV 整段重处理（流式路径修 chunk 边界切碎）

    /// 用 WAV 文件跑一次纯净 SA pass，绕过 chunk 边界切碎问题
    /// 用于 stop 时拿"全段连续音频识别的 ground truth"
    /// RT factor ~0.05-0.1（M5 上 10s 音频 ~500ms-1s）
    @MainActor
    static func transcribeFromFile(at url: URL) async -> (text: String, words: [WordInfo])? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Logger.log("Voice", "[Reprocess] WAV not found: \(url.path)")
            return nil
        }

        let t0 = CFAbsoluteTimeGetCurrent()

        // 1) locale
        let supported = await SpeechTranscriber.supportedLocales
        let prefixes = ["zh-Hans", "zh-CN", "zh-Hant", "zh"]
        var bestLocale: Locale?
        for prefix in prefixes {
            if let m = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                bestLocale = m
                break
            }
        }
        guard let locale = bestLocale else { return nil }

        // 2) 创建 SA pipeline
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )

        // 3) 开 audio file
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            Logger.log("Voice", "[Reprocess] open WAV failed: \(error)")
            return nil
        }

        // 4) result task
        let resultTask: Task<(text: String, words: [WordInfo]), Never> = Task {
            var fullText = ""
            var allWords: [WordInfo] = []
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        fullText += text
                        var words: [WordInfo] = []
                        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
                        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute
                        for (confidence, timeRange, range) in result.text.runs[ConfKey.self, TimeKey.self] {
                            let wordText = String(result.text[range].characters)
                            guard !wordText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                            words.append(WordInfo(
                                text: wordText,
                                confidence: Float(confidence ?? 1.0),
                                alternatives: [],
                                startTime: timeRange?.start.seconds ?? 0,
                                duration: timeRange?.duration.seconds ?? 0
                            ))
                        }
                        allWords.append(contentsOf: words)
                    }
                }
            } catch {
                Logger.log("Voice", "[Reprocess] result stream error: \(error)")
            }
            return (text: fullText, words: allWords)
        }

        // 5) start with file
        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            Logger.log("Voice", "[Reprocess] analyzer.start failed: \(error)")
            resultTask.cancel()
            return nil
        }

        // 6) wait for drain
        let result = await resultTask.value

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        Logger.log("Voice", "[Reprocess] WAV→text \(elapsedMs)ms (\(result.text.count)字, \(result.words.count) words)")
        return result
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
    private let builderLock = NSLock()
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    private var converter: AVAudioConverter?
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?
    private(set) var bufferCount = 0

    init(inputBuilder: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat?, audioFileURL: URL) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        // 改用 .wav 扩展名
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        super.init()
    }

    /// chunk 流式：把音频路由到新 builder。后续 captureOutput 喂入新流，不丢音频。
    func swapInputBuilder(to new: AsyncStream<AnalyzerInput>.Continuation) {
        builderLock.lock()
        defer { builderLock.unlock() }
        inputBuilder = new
    }

    func close() {
        finalizeWAV()
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

        // 发送给 SpeechAnalyzer
        let input = AnalyzerInput(buffer: outputBuffer)
        inputBuilder.yield(input)
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

/// 带超时的 async 执行（non-throwing 版本）
func withTimeout(seconds: TimeInterval, operation: @Sendable @escaping () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
        }
        await group.next()
        group.cancelAll()
    }
}
