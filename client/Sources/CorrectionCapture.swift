import AppKit
import ApplicationServices

/// 学习模式 V1：注入后 30s 内监听用户改字 → 自动入 learned 字典
///
/// 工作流：
/// 1. TextInjector 注入完后调 `CorrectionCapture.shared.scheduleCheck(injected:targetApp:)`
/// 2. 等 30s（可配置 polish.learning_window_sec）
/// 3. 用 Accessibility API 读目标 app 当前 focused 元素的文本
/// 4. 找 injected 在 current 里的位置（精确不命中→对齐位置范围）
/// 5. 中文分词 → token 对齐 → 抽 (oldToken, newToken) pair
/// 6. 过滤：长度 2-5 字 + Levenshtein 距离 ≤ 2 + 长度比 0.5-2x → 视为 ASR 错例
/// 7. 调 DictionaryLearner.learn(wrong:correct:) 自动落字典
///
/// 默认开。`polish.learning_enabled = false` 关闭。
///
/// 已知限制（V1）：
/// - cc 终端 raw mode：AX 读不到完整文本（同 backspace 那道墙）
/// - "用户改本意" vs "用户纠 ASR 错"难区分；V1 用 Levenshtein 距离 ≤2 的强约束兜底
/// - 跨段 token 对齐用 LCS，O(N×M) 复杂度，文本长 > 1000 字节会慢（设上限 800 字符）
@MainActor
final class CorrectionCapture {
    static let shared = CorrectionCapture()

    private struct Pending {
        let injected: String
        let app: AppIdentity?
        let scheduledAt: Date
        let task: Task<Void, Never>
    }

    private var pending: Pending?

    private init() {}

    /// 注入完成后调（TextInjector 内部调用）
    func scheduleCheck(injected: String, targetApp: AppIdentity?) {
        // 取消之前还没跑的任务（用户连续录音时只看最后一次）
        pending?.task.cancel()

        let polish = RuntimeConfig.shared.polishConfig
        let enabled = (polish["learning_enabled"] as? Bool) ?? true
        guard enabled, !injected.isEmpty else {
            pending = nil
            return
        }

        let windowSec = (polish["learning_window_sec"] as? Int) ?? 30
        let scheduledAt = Date()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(windowSec))
            if Task.isCancelled { return }
            await self?.runDiff(injected: injected, app: targetApp, scheduledAt: scheduledAt)
        }

        pending = Pending(
            injected: injected,
            app: targetApp,
            scheduledAt: scheduledAt,
            task: task
        )
    }

    /// 30s 后读 AX，对比 injected 与 current，抽 (raw, corrected) pair
    private func runDiff(injected: String, app: AppIdentity?, scheduledAt: Date) async {
        guard let app else {
            Logger.log("Learn", "skip: no pinned app")
            pending = nil
            return
        }

        // 1) 通过 AX 读目标 app 当前 focused 文本
        let current = readFocusedText(pid: app.processID)
        guard let current, !current.isEmpty else {
            Logger.log("Learn", "skip: AX read empty/failed for \(app.bundleID ?? "?")")
            pending = nil
            return
        }

        // 长文本（cc 终端有几万字历史）：只取末尾 ~ injected 长度 × 4 的窗口
        // 用户改字一定在最近注入位置附近，没必要扫整个文档
        let scanWindow = max(injected.count * 4, 200)
        let scanText: String
        if current.count > scanWindow {
            scanText = String(current.suffix(scanWindow))
        } else {
            scanText = current
        }

        // 2) injected 完整出现在 scanText 里 → 用户没改，不学
        if scanText.contains(injected) {
            Logger.log("Learn", "no change in \(app.bundleID ?? "?"): injected unchanged (scanned \(scanText.count)/\(current.count) chars)")
            pending = nil
            return
        }

        // 3) 在 scanText 窗口里找 injected 大致对应位置
        guard let modifiedSegment = findModifiedSegment(injected: injected, current: scanText) else {
            Logger.log("Learn", "no overlap with scanned text in \(app.bundleID ?? "?") (scanned \(scanText.count) chars)")
            pending = nil
            return
        }

        // 4) 三元组 stability 信号：injected vs modifiedSegment 的字符比例
        // 接近 1.0 = 用户基本保留（small edits = 真纠错）
        // 远离 1.0 = 大改 / 大删（不是 ASR 错例，是用户改本意，不学）
        let lenRatio = Double(modifiedSegment.count) / max(1.0, Double(injected.count))
        guard lenRatio >= 0.5, lenRatio <= 2.0 else {
            Logger.log("Learn", "skip: length ratio \(String(format: "%.2f", lenRatio)) out of [0.5, 2.0] (probably intent change, not ASR fix)")
            pending = nil
            return
        }

        // 5) 中文分词 → token 对齐
        let oldTokens = chineseTokens(of: injected)
        let newTokens = chineseTokens(of: modifiedSegment)

        // 6) LCS 对齐 → 提取差异 pair
        let pairs = extractPairs(oldTokens: oldTokens, newTokens: newTokens)

        // 7) 三元组：token 重合比例（共保留多少 token）
        let oldSet = Set(oldTokens)
        let newSet = Set(newTokens)
        let kept = oldSet.intersection(newSet).count
        let total = max(1, oldSet.union(newSet).count)
        let keepRatio = Double(kept) / Double(total)
        guard keepRatio >= 0.4 else {
            Logger.log("Learn", "skip: keep ratio \(String(format: "%.2f", keepRatio)) too low (kept \(kept)/\(total) tokens, probably full rewrite)")
            pending = nil
            return
        }

        // 8) 过滤 + 学习（带三元组 stability 元数据）
        var learned = 0
        for (wrong, correct) in pairs {
            guard isValidLearnPair(wrong: wrong, correct: correct) else { continue }
            let result = DictionaryLearner.learn(wrong: wrong, correct: correct)
            Logger.log("Learn", "auto[stability=\(String(format: "%.2f", keepRatio))]: \(wrong) → \(correct) | \(result)")
            learned += 1
        }
        if learned == 0, !pairs.isEmpty {
            Logger.log("Learn", "found \(pairs.count) pairs, all filtered: \(pairs.prefix(3).map { "\($0.0)→\($0.1)" }.joined(separator: ", "))")
        }

        pending = nil
    }

    // MARK: - AX 读

    nonisolated private func readFocusedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let r = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard r == .success, let focusedAXObj = focused else { return nil }
        // CFTypeRef → AXUIElement
        let focusedEl = focusedAXObj as! AXUIElement
        var value: AnyObject?
        let r2 = AXUIElementCopyAttributeValue(focusedEl, kAXValueAttribute as CFString, &value)
        if r2 == .success, let str = value as? String, !str.isEmpty {
            return str
        }
        // fallback：试 selectedText / 整个 textArea content
        var sel: AnyObject?
        AXUIElementCopyAttributeValue(focusedEl, kAXSelectedTextAttribute as CFString, &sel)
        if let s = sel as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: - 找改动片段

    /// 在 current 里找 injected 大致对应的位置 → 返回 current 的子串
    /// 简化：用 injected 的首 N 字 + 末 N 字作为 anchor
    private func findModifiedSegment(injected: String, current: String) -> String? {
        let chars = Array(injected)
        let len = chars.count
        guard len >= 4 else { return nil }
        // anchor 长度：取 injected 长度的 1/4，但至少 2 字
        let anchorLen = max(2, len / 4)
        let prefixAnchor = String(chars.prefix(anchorLen))
        let suffixAnchor = String(chars.suffix(anchorLen))

        guard let pStart = current.range(of: prefixAnchor)?.lowerBound,
              let sEnd = current.range(of: suffixAnchor, options: .backwards)?.upperBound,
              pStart < sEnd else {
            return nil
        }
        let segment = String(current[pStart..<sEnd])
        // 长度限制：modified segment 不应比 injected 大太多（>2x 视为加了别的内容）
        if segment.count > len * 2 { return nil }
        return segment
    }

    // MARK: - 中文 token 化

    /// 用 CFStringTokenizer 分词
    nonisolated private func chineseTokens(of text: String) -> [String] {
        let cf = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cf,
            range,
            kCFStringTokenizerUnitWord,
            Locale(identifier: "zh-CN") as CFLocale
        )
        var tokens: [String] = []
        var type = CFStringTokenizerGoToTokenAtIndex(tokenizer, 0)
        while type != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if r.length > 0 {
                let substr = CFStringCreateWithSubstring(kCFAllocatorDefault, cf, r) as String
                let trimmed = substr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tokens.append(trimmed)
                }
            }
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return tokens
    }

    // MARK: - LCS 对齐 + 抽差异 pair

    /// 经典 LCS DP，回溯出对齐路径，相邻不匹配 token 视为 (wrong, correct) pair
    /// 用 token 级而非字符级，避免破坏中文词
    private func extractPairs(oldTokens: [String], newTokens: [String]) -> [(String, String)] {
        let m = oldTokens.count
        let n = newTokens.count
        guard m > 0 && n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if oldTokens[i - 1] == newTokens[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // 回溯：相邻 mismatch 当 pair
        var pairs: [(String, String)] = []
        var i = m, j = n
        var pendingOld: [String] = []
        var pendingNew: [String] = []
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldTokens[i - 1] == newTokens[j - 1] {
                // match：把 pending 收一对
                if !pendingOld.isEmpty || !pendingNew.isEmpty {
                    pairs.append((pendingOld.reversed().joined(), pendingNew.reversed().joined()))
                    pendingOld = []
                    pendingNew = []
                }
                i -= 1; j -= 1
            } else if i > 0 && (j == 0 || dp[i - 1][j] >= dp[i][j - 1]) {
                pendingOld.append(oldTokens[i - 1])
                i -= 1
            } else {
                pendingNew.append(newTokens[j - 1])
                j -= 1
            }
        }
        if !pendingOld.isEmpty || !pendingNew.isEmpty {
            pairs.append((pendingOld.reversed().joined(), pendingNew.reversed().joined()))
        }
        return pairs.reversed()
    }

    // MARK: - 过滤

    /// 一对 (wrong, correct) 是否值得入字典
    /// 严格规则：长度 2-5 字 + Levenshtein 距离 ≤2 + 长度比 0.5-2x + 都不空
    private func isValidLearnPair(wrong: String, correct: String) -> Bool {
        guard !wrong.isEmpty, !correct.isEmpty, wrong != correct else { return false }
        let wLen = wrong.count
        let cLen = correct.count
        // 长度范围
        guard wLen >= 2, wLen <= 5, cLen >= 2, cLen <= 5 else { return false }
        // 长度比
        let ratio = Double(wLen) / Double(cLen)
        guard ratio >= 0.5, ratio <= 2.0 else { return false }
        // Levenshtein
        let dist = CorrectionDictionary.levenshtein(wrong, correct)
        guard dist <= 2 else { return false }
        return true
    }
}
