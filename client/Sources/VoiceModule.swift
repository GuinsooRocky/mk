import AppKit
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
    private var liveLastChar: Character?
    private var liveSegmentAccum = ""

    // 实时流式会话（按 config.stream_provider 选 Soniox/腾讯）；本模式下 HUD 吃云端 interim
    private var streamSession: (any StreamingSession)?
    // interim 上屏节流（纠错管线按节流频率跑，预览≈定稿口径）
    private var interimThrottleT: CFAbsoluteTime = 0

    // 收尾死线/看门狗：云引擎到点降级本地（=网络差自动降级）；整条收尾 Task 卡死时强制收浮窗
    private static let cloudDeadlineSec: Double = 4.0
    private static let processingWatchdogSec: Double = 8.0
    private var processingGen = 0  // 每轮收尾 +1；看门狗/迟到 Task 据此判作废

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

        // 实时流式（Soniox/腾讯）：边录边发 PCM，HUD 吃云端 interim（比本地 SenseVoice 更准、且与最终版一致）。
        // 此模式下不再跑 SenseVoice 本地 live（省算力、避免双路）。没配 stream_provider → stream=nil，照旧。
        let stream = StreamingEngine.makeSession()
        self.streamSession = stream
        if let stream {
            interimThrottleT = 0
            stream.onInterim = { [weak self] text in
                DispatchQueue.main.async { self?.handleInterim(text) }
            }
            voiceSession.onPCM16k = { pcm in stream.feed(pcm) }
            Logger.log("Voice", "[Stream] 实时流式 ON（HUD 吃云端 interim）")
        }

        // 实时预览（SenseVoice VAD 边说边出）：仅「非流式」时启用，与最终引擎无关。
        // 段文本只刷新 HUD 浮窗，不进目标 app；最终版松手后由所选引擎整段产出、一次性回填。
        let liveSegment = stream == nil
            && ((polish["live_segment_enabled"] as? Bool) ?? false)
            && SenseVoiceEngine.shared.isAvailable
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
                streamSession?.abort()
                streamSession = nil
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
        // 松手后（processing）只累积不渲染：浮窗不再闪尾段；accum 仍是引擎失败时的回落文本
        if state == .recording {
            hud.update(text: liveSegmentAccum)
        }
    }

    /// 流式 interim（主线程）：节流 200ms 过纠错管线再上浮窗，预览与定稿同口径
    private func handleInterim(_ raw: String) {
        guard state == .recording else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - interimThrottleT >= 0.2 else { return }
        interimThrottleT = now
        hud.update(text: pipeline.correctText(raw))
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

        // 收尾看门狗：万一下面的收尾 Task 被某个 await（网络/引擎）卡死，到点强制收尾，
        // 绝不让浮窗永远停在 processing。正常路径下 Task 结束会 cancel 掉它。
        processingGen &+= 1
        let gen = processingGen
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.processingGen == gen, self.state == .processing else { return }
            Logger.log("Voice", "[Watchdog] 收尾超时 \(Self.processingWatchdogSec)s，强制收尾")
            self.processingGen &+= 1  // 作废可能迟到的 Task 收尾
            let salvage = self.liveSegmentAccum
            if salvage.isEmpty {
                self.hud.hide()
            } else {
                self.presentFallback(text: self.pipeline.correctText(salvage))
            }
            self.state = .idle
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.processingWatchdogSec, execute: watchdog)

        Task {
            defer { watchdog.cancel() }
            // 短句快路径：松手后有引擎对整段 WAV 出定稿时，<1s 的录音跳过 live 尾段解码
            // （尾段反正来不及上屏，省 50-100ms；engine=sa 时 live accum 就是定稿，不能跳）
            let engine = RuntimeConfig.shared.polishConfig["engine"] as? String
            let hasFinalEngine = self.streamSession != nil
                || ["sensevoice", "groq", "tencent"].contains(engine ?? "")
            let result = await session.stop(skipLiveTail: hasFinalEngine && recordingMs < 1000)
            let stopMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            self.session = nil

            let tPipe = CFAbsoluteTimeGetCurrent()

            // 文本来源：SA 整段优先；live 模式跳过 SA finalize 时回落到 live 预览累积版
            var bestText = result.fullText.isEmpty ? self.liveSegmentAccum : result.fullText

            // 文本来源优先级：① 流式会话定稿（provider 无关）② 各非流式引擎整段转写 ③ SA/live 兜底
            if let stream = self.streamSession {
                // 流式：松手收尾，等最后一个分片刷新定稿（~250ms）。失败回落一句话识别，永不让用户空手。
                let t = await stream.finish()
                self.streamSession = nil
                if let t, !t.isEmpty {
                    Logger.log("Voice", "[Stream] \(bestText) → \(t)")
                    bestText = t
                } else if let audioPath = result.audioPath,
                          let one = await self.withDeadline(Self.cloudDeadlineSec, label: "tencent-oneshot", { await TencentEngine.transcribe(wavPath: audioPath) }), !one.isEmpty {
                    Logger.log("Voice", "[Stream] 空，回落一句话识别 → \(one)")
                    bestText = one
                } else {
                    Logger.log("Voice", "[Stream] 失败，回落: \(bestText)")
                }
            } else if let audioPath = result.audioPath {
                switch RuntimeConfig.shared.polishConfig["engine"] as? String {
                case "sensevoice":
                    if let t = await SenseVoiceEngine.shared.transcribe(wavPath: audioPath) {
                        Logger.log("Voice", "[Engine=sensevoice] \(bestText) → \(t)")
                        bestText = t
                    } else {
                        Logger.log("Voice", "[Engine=sensevoice] 失败，回落: \(bestText)")
                    }
                case "groq":
                    if let t = await self.withDeadline(Self.cloudDeadlineSec, label: "groq", { await GroqEngine.transcribe(wavPath: audioPath) }), !t.isEmpty {
                        Logger.log("Voice", "[Engine=groq] \(bestText) → \(t)")
                        bestText = t
                    } else {
                        Logger.log("Voice", "[Engine=groq] 失败，回落: \(bestText)")
                    }
                case "tencent":
                    if let t = await self.withDeadline(Self.cloudDeadlineSec, label: "tencent", { await TencentEngine.transcribe(wavPath: audioPath) }), !t.isEmpty {
                        Logger.log("Voice", "[Engine=tencent] \(bestText) → \(t)")
                        bestText = t
                    } else {
                        Logger.log("Voice", "[Engine=tencent] 失败，回落: \(bestText)")
                    }
                default:
                    break  // "sa" 或未设：直接用 SA / live 文本
                }
            }

            // 看门狗已强制收尾（或已开新一轮录音）→ 这条迟到的收尾作废，别重复注入/乱动浮窗
            guard self.processingGen == gen else {
                Logger.log("Voice", "[Watchdog] 收尾迟到作废 (gen \(gen)≠\(self.processingGen))")
                return
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
            let injected = await pipeline.process(
                transcription: result,
                finalRawText: bestText,
                targetApp: pinnedApp
            )
            let finalText = self.pipeline.correctText(bestText)
            if injected {
                // 成功：定稿唯一落点是 input，浮窗立即收（不回显最终文本，消除双份并存）
                self.hud.dismissQuick()
            } else if finalText.isEmpty {
                // 全是语气词，过滤后空了 → 没东西可贴，跟"识别为空"一样直接收浮窗，别弹兜底盘
                self.hud.dismissQuick()
            } else {
                // 目标 app 切走/退出 → 没 paste。文本已识别好，浮窗不消失，等用户决定放哪儿
                self.presentFallback(text: finalText)
            }

            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - tPipe) * 1000)
            let voiceTotalMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            Logger.log("Voice", "Timing: recording=\(recordingMs)ms stop_finalize=\(stopMs)ms pipeline=\(pipelineMs)ms voice_total=\(voiceTotalMs)ms")
            state = .idle
        }
    }

    /// 给一个 async 操作套硬死线。到点（网络差/引擎挂）返回 nil，调用方按"引擎失败"回落本地，
    /// 并取消底层网络任务（URLSession 收到取消会拆连接）。这既根治"浮窗卡死"，也实现"网络差自动降级"。
    private func withDeadline<T: Sendable>(
        _ seconds: Double, label: String, _ op: @Sendable @escaping () async -> T?
    ) async -> T? {
        await withTaskGroup(of: (Bool, T?).self) { group in
            group.addTask { (false, await op()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return (true, nil)
            }
            defer { group.cancelAll() }
            guard let first = await group.next() else { return nil }
            if first.0 { Logger.log("Voice", "[Deadline] \(label) \(seconds)s 未返回，降级本地") }
            return first.1
        }
    }

    /// 注入失败兜底：HUD 临时变成「待处理小托盘」，给 重新粘贴 / 复制 / 取消（不丢用户说过的话）
    private func presentFallback(text: String) {
        Logger.log("Voice", "[Fallback] 目标丢失，文本待处置: \(text)")
        hud.showFallback(
            text: text,
            onRetry: { [weak self] in self?.retryInject(text) },
            onCopy: {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Logger.log("Voice", "[Fallback] 已复制到剪贴板")
            },
            onCancel: {
                Logger.log("Voice", "[Fallback] 取消，剪贴板不动")
            }
        )
    }

    /// 重新粘贴：重新激活原 app 再 paste；还是失败（app 真没了）就继续留着兜底，不丢文本
    private func retryInject(_ text: String) {
        if let pid = pinnedApp?.processID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        // 给激活留一点时间（前台切换不是同步的），再 paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if TextInjector.inject(text: text, to: self.pinnedApp) {
                self.hud.dismissQuick()
            } else {
                self.presentFallback(text: text)
            }
        }
    }
}
