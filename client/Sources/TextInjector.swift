import AppKit

/// 文本注入器：单次 clipboard + ⌘V → 0.5s 后恢复剪贴板。
/// （实时态全部在 TranscriptionHUD 浮窗里；目标 app 只在结束时回填一次最终版。）
enum TextInjector {
    // ⌘V throttle：单位时间窗口内 paste 次数上限（安全阀，防异常情况下连发）
    @MainActor private static var pasteTimestamps: [CFAbsoluteTime] = []
    private static let pasteThrottleWindowSec: Double = 1.0
    private static let pasteThrottleMaxPerWindow: Int = 20

    /// 返回是否真的执行了 paste。false = 目标 app 已切走/退出，调用方应走 fallback（别把文本打进错误的 app）。
    @discardableResult
    @MainActor
    static func inject(text: String, to app: AppIdentity?) -> Bool {
        guard !text.isEmpty else { return false }

        // 处理期间用户切到别的 app / 原 app 退出 → 不 paste，交给上层兜底（只认这一种确定危险场景，
        // 不探 AX 可编辑控件——那会误伤 cc/iTerm/Ghostty/Warp 这类不暴露 AXTextArea 的终端）
        if let app {
            if NSRunningApplication(processIdentifier: app.processID) == nil {
                Logger.log("Injector", "Target app gone (pid \(app.processID)), skip paste")
                return false
            }
            if let cur = AppIdentity.current(), cur.processID != app.processID {
                Logger.log("Injector", "Frontmost changed (\(app.bundleID) → \(cur.bundleID)), skip paste")
                return false
            }
        }

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
        return true
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
