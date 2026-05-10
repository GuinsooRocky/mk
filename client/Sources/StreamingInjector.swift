import Foundation

/// 真·流式注入器（实验性，菜单 toggle 默认关）
///
/// 已知限制（菜单已标"实验"）：
/// 1. SA zh-CN volatile 延迟严重（实测 11+ 秒才喷一次），多数场景跟不上说话节奏
/// 2. cc 终端 raw mode 下 backspace 不可靠，回退会失败导致 raw + corrected 并存
///    → 仅推荐在 Notes / 文档类 app 用
///
/// 工作流：
/// 1. SA 不停发 volatile（"finalizedText + currentVolatile" 累积串）
/// 2. 触发条件（5 字 OR 800ms）满足后开始流式
/// 3. 每次新 volatile 来：debounce N ms，期间没新 volatile 就 commit
/// 4. commit = 与已注入文本算 common prefix → backspace 差异 + 贴新增
/// 5. release 时调 finalize(corrected)：跑完字典/ITN/filler/punct 的最终文本，
///    再做一次 diff + backspace + 贴 corrected 末段；最后 endStreaming 恢复剪贴板
@MainActor
final class StreamingInjector {
    private var injectedText: String = ""
    private var pendingVolatile: String = ""
    private var commitTask: Task<Void, Never>?
    private var targetApp: AppIdentity?
    private var active: Bool = false
    private var triggered: Bool = false
    private var startedAt: CFAbsoluteTime = 0
    private var commitCount: Int = 0

    private let stabilityBufferMs: Int
    private let activationCharThreshold: Int
    private let activationTimeMs: Int

    init(
        stabilityBufferMs: Int = 500,
        activationCharThreshold: Int = 5,
        activationTimeMs: Int = 800
    ) {
        self.stabilityBufferMs = stabilityBufferMs
        self.activationCharThreshold = activationCharThreshold
        self.activationTimeMs = activationTimeMs
    }

    func start(targetApp: AppIdentity?) {
        self.targetApp = targetApp
        self.injectedText = ""
        self.pendingVolatile = ""
        self.active = true
        self.triggered = false
        self.commitCount = 0
        self.startedAt = CFAbsoluteTimeGetCurrent()
        commitTask?.cancel()
        commitTask = nil
    }

    func onVolatile(text: String) {
        guard active else { return }
        pendingVolatile = text

        if !triggered {
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            let charOK = text.count >= activationCharThreshold
            let timeOK = elapsedMs >= activationTimeMs
            if charOK || timeOK {
                triggered = true
                TextInjector.beginStreaming()
                Logger.log("Stream", "triggered (chars=\(text.count) elapsed=\(elapsedMs)ms reason=\(charOK ? "chars" : "time"))")
            } else {
                return
            }
        }

        commitTask?.cancel()
        let buffer = stabilityBufferMs
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(buffer))
            if Task.isCancelled { return }
            await self?.commit()
        }
    }

    func flushPending() -> String {
        commitTask?.cancel()
        commitTask = nil
        if triggered && pendingVolatile != injectedText {
            commitSync()
        }
        return injectedText
    }

    func finalize(finalCorrected: String) -> Bool {
        guard triggered else {
            active = false
            return false
        }

        let common = commonPrefixLength(injectedText, finalCorrected)
        let toRemove = injectedText.count - common
        let toAdd = String(finalCorrected.dropFirst(common))

        if toRemove > 0 {
            TextInjector.backspace(count: toRemove)
        }
        if !toAdd.isEmpty {
            TextInjector.pasteText(toAdd)
        }
        injectedText = finalCorrected
        Logger.log("Stream", "finalize: backspace=\(toRemove) add=\"\(toAdd)\" (commits=\(commitCount))")

        TextInjector.endStreaming()
        active = false

        // 学习模式：流式路径也安排 30s 后 AX 检查
        CorrectionCapture.shared.scheduleCheck(injected: finalCorrected, targetApp: targetApp)
        return true
    }

    func cancel() {
        commitTask?.cancel()
        commitTask = nil
        if triggered {
            TextInjector.endStreaming()
        }
        active = false
        triggered = false
    }

    var didTrigger: Bool { triggered }

    // MARK: - private

    private func commit() async {
        commitSync()
    }

    private func commitSync() {
        let target = pendingVolatile
        if target == injectedText { return }

        let common = commonPrefixLength(injectedText, target)
        let toRemove = injectedText.count - common
        let toAdd = String(target.dropFirst(common))

        if toRemove > 0 {
            TextInjector.backspace(count: toRemove)
        }
        if !toAdd.isEmpty {
            TextInjector.pasteText(toAdd)
        }
        injectedText = target
        commitCount += 1
        Logger.log("Stream", "commit#\(commitCount): -\(toRemove) +\"\(toAdd)\" → \(target.count)字")
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var i = 0
        while i < aChars.count && i < bChars.count && aChars[i] == bChars[i] {
            i += 1
        }
        return i
    }
}
