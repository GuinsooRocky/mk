import AppKit

/// 文本注入器
/// 单次：clipboard + Cmd+V → 0.5s 后恢复
/// 流式（实验，菜单可关）：beginStreaming → backspace + pasteText（多次）→ endStreaming
enum TextInjector {
    @MainActor private static var streamingSavedClipboard: String?
    @MainActor private static var streamingActive = false

    // ⌘V throttle：单位时间窗口内 paste 次数上限，防 chunk 流式 bug 灌爆 iTerm 这类 app
    @MainActor private static var pasteTimestamps: [CFAbsoluteTime] = []
    private static let pasteThrottleWindowSec: Double = 1.0
    private static let pasteThrottleMaxPerWindow: Int = 20

    // MARK: - 单次注入（默认路径 / 短句 / 流式 disabled）

    @MainActor
    static func inject(text: String, to app: AppIdentity?) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCountAfterPaste = pb.changeCount

        postCmdV()

        Logger.log("Injector", "Pasted to \(app?.bundleID ?? "unknown")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if pb.changeCount == changeCountAfterPaste, let saved = savedString {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }

        // 学习模式 V1：30s 后读 AX 看用户改了啥 → 自动入字典
        CorrectionCapture.shared.scheduleCheck(injected: text, targetApp: app)
    }

    // MARK: - 流式注入

    @MainActor
    static func beginStreaming() {
        guard !streamingActive else { return }
        let pb = NSPasteboard.general
        streamingSavedClipboard = pb.string(forType: .string)
        streamingActive = true
        Logger.log("Injector", "[Stream] begin (saved \(streamingSavedClipboard?.count ?? 0) chars)")
    }

    @MainActor
    static func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        postCmdV()
    }

    @MainActor
    static func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    @MainActor
    static func endStreaming() {
        guard streamingActive else { return }
        let saved = streamingSavedClipboard
        streamingSavedClipboard = nil
        streamingActive = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let saved else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(saved, forType: .string)
            Logger.log("Injector", "[Stream] end + restored clipboard")
        }
    }

    // MARK: - 内部

    @MainActor
    private static func postCmdV() {
        // ⌘V throttle：清掉过期时间戳，超阈值就跳过这次 paste
        let now = CFAbsoluteTimeGetCurrent()
        pasteTimestamps.removeAll { now - $0 > pasteThrottleWindowSec }
        if pasteTimestamps.count >= pasteThrottleMaxPerWindow {
            Logger.log("Injector", "[Throttle] paste skipped: \(pasteTimestamps.count) within \(pasteThrottleWindowSec)s window")
            return
        }
        pasteTimestamps.append(now)

        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
