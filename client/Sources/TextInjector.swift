import AppKit

/// 文本注入器：单次 clipboard + ⌘V → 0.5s 后恢复剪贴板。
/// （实时态全部在 TranscriptionHUD 浮窗里；目标 app 只在结束时回填一次最终版。）
enum TextInjector {
    // ⌘V throttle：单位时间窗口内 paste 次数上限（安全阀，防异常情况下连发）
    @MainActor private static var pasteTimestamps: [CFAbsoluteTime] = []
    private static let pasteThrottleWindowSec: Double = 1.0
    private static let pasteThrottleMaxPerWindow: Int = 20

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
