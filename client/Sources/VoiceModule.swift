import Foundation

/// 语音模块
/// 交互：按住右 Option 开始录音+转写 → 松开停止 → 自动注入（push-to-talk）
///
/// 流式（实验，菜单 toggle 默认关）：
/// - `polish.streaming_enabled = false`（默认）→ 纯非流式 ~150ms 注入
/// - `polish.streaming_enabled = true`（用户在菜单里开启）→ volatile diff + backspace；
///   仅推荐 Notes/文档类 app（cc 终端 backspace 不可靠）
@MainActor
final class VoiceModule: WEModule {
    let name = "Voice"
    var isActive = false

    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private var session: VoiceSession?
    private let pipeline = VoicePipeline()
    private let streamingInjector: StreamingInjector
    private var pinnedApp: AppIdentity?
    private var recordingStartT: CFAbsoluteTime = 0

    init() {
        let polish = RuntimeConfig.shared.polishConfig
        // chunk 流式：stability=0（chunk 输入本身已经稳定），activation 极低（首个 chunk 就触发）
        let stabilityMs = (polish["streaming_stability_ms"] as? Int) ?? 0
        let actChars = (polish["streaming_activation_chars"] as? Int) ?? 1
        let actTimeMs = (polish["streaming_activation_time_ms"] as? Int) ?? 100
        self.streamingInjector = StreamingInjector(
            stabilityBufferMs: stabilityMs,
            activationCharThreshold: actChars,
            activationTimeMs: actTimeMs
        )
    }

    func onHotKeyDown() {
        if state == .idle {
            startRecording()
        }
    }

    func onHotKeyUp() {
        if state == .recording {
            stopAndProcess()
        }
    }

    private func startRecording() {
        guard VoiceSession.isAuthorized else {
            Logger.log("Voice", "Not authorized, requesting permissions")
            VoiceSession.requestPermissions()
            return
        }

        state = .recording
        recordingStartT = CFAbsoluteTimeGetCurrent()

        pinnedApp = AppIdentity.current()
        Logger.log("Voice", "Pinned app: \(pinnedApp?.bundleID ?? "unknown")")

        let voiceSession = VoiceSession()
        self.session = voiceSession

        // 每次录音读最新配置（菜单刚切换的话立即生效）
        let polish = RuntimeConfig.shared.polishConfig
        let streamingEnabled = (polish["streaming_enabled"] as? Bool) ?? false

        if streamingEnabled {
            streamingInjector.start(targetApp: pinnedApp)

            // 仅走分块流式 — 每 chunkInterval 主动重启 SA 拿累积文本
            // 不订阅 onPartialResult：chunk swap 后 SA 会快速 emit 多个 volatile（积压音频），
            // 字符级触发会给目标 app 灌一堆 ⌘V，iTerm 类终端会卡死。
            let chunkInterval = (polish["streaming_chunk_interval_ms"] as? Int) ?? 2000
            voiceSession.chunkIntervalMs = chunkInterval
            voiceSession.onFinalChunk = { [weak self] cumulative in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 飞书思路：chunk 期间贴 raw（快但糙），松手时 finalize 全文纠错一次性大刷新
                    // 不在 chunk 里跑 correctText，避免 punct 把上次的「。」改成「，」时 backspace
                    self.streamingInjector.onVolatile(text: cumulative)
                }
            }
        }

        Task {
            do {
                try await voiceSession.start()
                Logger.log("Voice", "Recording... (streaming=\(streamingEnabled))")

                Task {
                    // 走 polish-aware 入口，自动包含 learned + active_domains（避免漏字典源）
                    let polish = RuntimeConfig.shared.polishConfig
                    let words = await ContextEnhancer.enhance(for: self.pinnedApp, polish: polish)
                    if !words.isEmpty {
                        await voiceSession.updateContext(contextualWords: words)
                    }
                }
            } catch {
                Logger.log("Voice", "Failed to start: \(error)")
                session = nil
                streamingInjector.cancel()
                state = .idle
            }
        }
    }

    private func stopAndProcess() {
        guard let session else {
            state = .idle
            return
        }

        let tStop0 = CFAbsoluteTimeGetCurrent()
        let recordingMs = Int((tStop0 - recordingStartT) * 1000)
        state = .processing
        Logger.log("Voice", "Stopping... (recorded \(recordingMs)ms)")

        // 切断回调防 stop 期间还触发 streamingInjector
        session.onPartialResult = nil
        session.onFinalChunk = nil

        Task {
            // 先 flush streaming pending（让最新 raw volatile 落地）
            let streamedRawSoFar = streamingInjector.flushPending()

            let result = await session.stop()
            let stopMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            self.session = nil

            guard !result.fullText.isEmpty else {
                Logger.log("Voice", "Empty transcription, skipping")
                streamingInjector.cancel()
                state = .idle
                return
            }

            Logger.log("Voice", "Transcribed: \(result.fullText) | streamedRaw=\(streamedRawSoFar.count)字")

            let tPipe = CFAbsoluteTimeGetCurrent()

            // 引擎切换：用所选引擎的转写替换 SA 文本，再交给下面原有管线（字典/filler/标点）。
            // SA 全程跑（录音落 WAV + 即时回落）；引擎失败就回落 SA，永不让用户空手。
            // WAV 整段重处理（修流式 chunk 边界切碎）只在「纯 SA 路径」或「所选引擎失败」时才跑——
            // sensevoice/groq 成功时不再白跑一遍 SA 整段解码（那是纯浪费延迟）。
            var bestText = result.fullText

            // 流式路径才有 chunk 边界切碎问题，需要 WAV 整段重处理拿干净 SA 文本；非流式返回 nil。
            @MainActor func saReprocess() async -> String? {
                guard streamingInjector.didTrigger, let audioPath = result.audioPath,
                      let clean = await VoiceSession.transcribeFromFile(at: URL(fileURLWithPath: audioPath)),
                      !clean.text.isEmpty else { return nil }
                return clean.text
            }

            if let audioPath = result.audioPath {
                switch RuntimeConfig.shared.polishConfig["engine"] as? String {
                case "sensevoice":
                    if let t = await SenseVoiceEngine.shared.transcribe(wavPath: audioPath) {
                        Logger.log("Voice", "[Engine=sensevoice] \(bestText) → \(t)")
                        bestText = t
                    } else if let clean = await saReprocess() {
                        Logger.log("Voice", "[Engine=sensevoice] 失败，回落 SA(WAV重处理): \(clean)")
                        bestText = clean
                    } else {
                        Logger.log("Voice", "[Engine=sensevoice] 失败，回落 SA: \(bestText)")
                    }
                case "groq":
                    if let t = await GroqEngine.transcribe(wavPath: audioPath), !t.isEmpty {
                        Logger.log("Voice", "[Engine=groq] \(bestText) → \(t)")
                        bestText = t
                    } else if let clean = await saReprocess() {
                        Logger.log("Voice", "[Engine=groq] 失败，回落 SA(WAV重处理): \(clean)")
                        bestText = clean
                    } else {
                        Logger.log("Voice", "[Engine=groq] 失败，回落 SA: \(bestText)")
                    }
                default:
                    // "sa" 或未设：流式路径仍需 WAV 重处理修 chunk 边界切碎
                    if let clean = await saReprocess() {
                        Logger.log("Voice", "[Reprocess] using clean text: chunked=\(result.fullText.count)字 → wav=\(clean.count)字")
                        bestText = clean
                    }
                }
            }

            let corrected = pipeline.correctText(bestText)

            // 流式：让 streamingInjector 做 final diff 注入；它返回 false 说明没触发
            let usedStreaming = streamingInjector.finalize(finalCorrected: corrected)

            if usedStreaming {
                pipeline.saveStreamingResult(
                    transcription: result,
                    finalText: corrected,
                    targetApp: pinnedApp
                )
            } else {
                await pipeline.process(
                    transcription: result,
                    targetApp: pinnedApp
                )
            }

            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - tPipe) * 1000)
            let voiceTotalMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            Logger.log("Voice", "Timing: recording=\(recordingMs)ms stop_finalize=\(stopMs)ms pipeline=\(pipelineMs)ms voice_total=\(voiceTotalMs)ms streamed=\(usedStreaming)")
            state = .idle
        }
    }
}
