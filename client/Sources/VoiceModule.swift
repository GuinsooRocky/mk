import Foundation

/// 语音模块
/// 交互：按住右 Option 开始录音+转写 → 松开停止 → 自动注入（push-to-talk）
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
    private let hud = TranscriptionHUD()
    private var pinnedApp: AppIdentity?
    private var recordingStartT: CFAbsoluteTime = 0

    // live 分段（SenseVoice VAD）运行态——只喂浮窗 HUD，绝不注入目标 app
    private var liveSegmentMode = false
    private var liveLastChar: Character?
    private var liveSegmentAccum = ""

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

        // 实时态只进 MK 自己的浮窗（目标 app 只在松手时回填一次最终版）
        hud.show(targetPID: pinnedApp?.processID)

        let voiceSession = VoiceSession()
        self.session = voiceSession

        // 每次录音读最新配置（菜单刚切换的话立即生效）
        let polish = RuntimeConfig.shared.polishConfig

        // 热麦续命秒数：录音结束后麦克风保持热多久（复用省冷启动）；可由 config 调，默认 6
        if let keep = polish["mic_keepalive_sec"] as? Double {
            MicCapture.shared.keepAliveSec = keep
        } else if let keep = polish["mic_keepalive_sec"] as? Int {
            MicCapture.shared.keepAliveSec = Double(keep)
        }

        // 实时预览（SenseVoice VAD 边说边出）：实时分段开 + 本地模型在即生效，与最终引擎无关。
        // 段文本只刷新 HUD 浮窗，不进目标 app；最终版松手后由所选引擎整段产出、一次性回填。
        let liveSegment = ((polish["live_segment_enabled"] as? Bool) ?? false)
            && SenseVoiceEngine.shared.isAvailable
        self.liveSegmentMode = liveSegment
        liveLastChar = nil
        liveSegmentAccum = ""
        if liveSegment {
            voiceSession.liveSegmentEnabled = true
            voiceSession.onLiveSegment = { [weak self] seg in
                self?.handleLiveSegment(seg)
            }
            Logger.log("Voice", "[Live] 边说边出 ON（仅浮窗）")
        }

        Task {
            do {
                try await voiceSession.start()
                Logger.log("Voice", "Recording...")

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
                hud.hide()
                state = .idle
            }
        }
    }

    /// live 分段（已在主线程、按时间顺序）→ 纠错 → 累积并刷新 HUD 浮窗（不进目标 app）。
    private func handleLiveSegment(_ raw: String) {
        let corrected = pipeline.correctText(raw)
        guard !corrected.isEmpty else { return }
        // 段间隔：上一段尾字非空白、本段以 ASCII 字母/数字开头 → 补空格（跨段英文不粘连）
        var piece = corrected
        if let last = liveLastChar, !last.isWhitespace,
           let first = corrected.first, first.isASCII, first.isLetter || first.isNumber {
            piece = " " + corrected
        }
        liveSegmentAccum += piece
        liveLastChar = piece.last
        hud.update(text: liveSegmentAccum)
    }

    private func stopAndProcess() {
        guard let session else {
            state = .idle
            return
        }

        let tStop0 = CFAbsoluteTimeGetCurrent()
        let recordingMs = Int((tStop0 - recordingStartT) * 1000)
        state = .processing
        hud.setProcessing(currentText: liveSegmentAccum)
        Logger.log("Voice", "Stopping... (recorded \(recordingMs)ms)")

        Task {
            let result = await session.stop()
            let stopMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            self.session = nil
            self.liveSegmentMode = false

            let tPipe = CFAbsoluteTimeGetCurrent()

            // 文本来源：SA 整段优先；live 模式跳过 SA finalize 时回落到 live 预览累积版
            var bestText = result.fullText.isEmpty ? self.liveSegmentAccum : result.fullText

            // 引擎切换：用所选引擎的整段转写替换；失败回落上面的 bestText，永不让用户空手
            if let audioPath = result.audioPath {
                switch RuntimeConfig.shared.polishConfig["engine"] as? String {
                case "sensevoice":
                    if let t = await SenseVoiceEngine.shared.transcribe(wavPath: audioPath) {
                        Logger.log("Voice", "[Engine=sensevoice] \(bestText) → \(t)")
                        bestText = t
                    } else {
                        Logger.log("Voice", "[Engine=sensevoice] 失败，回落: \(bestText)")
                    }
                case "groq":
                    if let t = await GroqEngine.transcribe(wavPath: audioPath), !t.isEmpty {
                        Logger.log("Voice", "[Engine=groq] \(bestText) → \(t)")
                        bestText = t
                    } else {
                        Logger.log("Voice", "[Engine=groq] 失败，回落: \(bestText)")
                    }
                case "tencent":
                    if let t = await TencentEngine.transcribe(wavPath: audioPath), !t.isEmpty {
                        Logger.log("Voice", "[Engine=tencent] \(bestText) → \(t)")
                        bestText = t
                    } else {
                        Logger.log("Voice", "[Engine=tencent] 失败，回落: \(bestText)")
                    }
                default:
                    break  // "sa" 或未设：直接用 SA / live 文本
                }
            }

            self.liveSegmentAccum = ""
            self.liveLastChar = nil

            guard !bestText.isEmpty else {
                Logger.log("Voice", "Empty transcription, skipping")
                self.hud.hide()
                state = .idle
                return
            }

            // 最终版：一次性回填目标 app（pipeline.process 内部跑 correctText + inject + 落历史 + 学习）
            await pipeline.process(
                transcription: result,
                finalRawText: bestText,
                targetApp: pinnedApp
            )
            // 浮窗显示最终版（与回填同步），停留后淡出
            self.hud.showFinal(text: self.pipeline.correctText(bestText))

            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - tPipe) * 1000)
            let voiceTotalMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            Logger.log("Voice", "Timing: recording=\(recordingMs)ms stop_finalize=\(stopMs)ms pipeline=\(pipelineMs)ms voice_total=\(voiceTotalMs)ms")
            state = .idle
        }
    }
}
