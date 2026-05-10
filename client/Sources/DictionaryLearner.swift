import Foundation

/// 错例反馈学习：把"用户实际说错过的词"沉淀到 learned 字典。
///
/// 写入 `~/.we/correction-dictionary-learned.txt`，格式与现有 `.txt` 字典一致：
///   `正字 | 错音1 | 错音2`
///
/// 幂等：同 `(正字, 错音)` 已存在不重复追加。
@MainActor
enum DictionaryLearner {
    /// learned 字典写入位置：优先 iCloud Drive（多 Mac 自动同步），fallback 本地
    static var learnedURL: URL {
        if let icloud = CorrectionDictionary.iCloudLearnedPath() {
            return URL(fileURLWithPath: icloud)
        }
        return WEDataDir.url.appendingPathComponent("correction-dictionary-learned.txt")
    }

    /// 学习一条 (错音 → 正字) 映射；返回人类可读结果。
    /// 调用后自动 reload 字典（VoicePipeline 下次按热键就生效）。
    static func learn(wrong: String, correct: String) -> String {
        let w = wrong.trimmingCharacters(in: .whitespaces)
        let c = correct.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !c.isEmpty, w != c else {
            return "skip: invalid pair (wrong='\(wrong)' correct='\(correct)')"
        }

        var lines = (try? String(contentsOf: learnedURL, encoding: .utf8)) ?? defaultHeader()
        if lines.isEmpty { lines = defaultHeader() }

        // 找已有同正字的行：`Correct | err1 | err2 ...`
        var found = false
        var alreadyHas = false
        let split = lines.components(separatedBy: .newlines)
        var newLines: [String] = []
        for line in split {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                newLines.append(line)
                continue
            }
            let parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = parts.first, head == c else {
                newLines.append(line)
                continue
            }
            // 已有此正字行 — 追加 wrong 到末尾（如果还没有）
            found = true
            if parts.dropFirst().contains(w) {
                alreadyHas = true
                newLines.append(line)
            } else {
                let merged = ([c] + parts.dropFirst() + [w]).joined(separator: " | ")
                newLines.append(merged)
            }
        }
        if !found {
            newLines.append("\(c) | \(w)")
        }

        let final = newLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        do {
            try final.write(to: learnedURL, atomically: true, encoding: .utf8)
        } catch {
            return "error: write failed: \(error)"
        }

        // reload 字典
        reloadAllDictionaries()

        // 翻 learning_happened flag（首次手动 learn 也算学习发生过）
        let already = (RuntimeConfig.shared.polishConfig["learning_happened"] as? Bool) ?? false
        if !already, !alreadyHas {
            RuntimeConfig.shared.setPolishField("learning_happened", value: true)
        }

        let action = alreadyHas ? "noop (already learned)" : (found ? "appended to existing" : "new entry")
        return "learn ok: \(c) | \(w) → \(action) → \(learnedURL.path)"
    }

    /// 重新加载所有字典（resolveEnabledPaths 已自动加进 learned + active_domains）
    private static func reloadAllDictionaries() {
        let polish = RuntimeConfig.shared.polishConfig
        if let cap = polish["dict_max_terms"] as? Int, cap > 0 { CorrectionDictionary.maxHintTerms = cap }
        if let cap = polish["dict_max_correction_terms"] as? Int, cap > 0 { CorrectionDictionary.maxCorrectionTerms = cap }
        let paths = CorrectionDictionary.resolveEnabledPaths(polish: polish)
        if !paths.isEmpty { CorrectionDictionary.shared.loadAll(from: paths) }
    }

    private static func defaultHeader() -> String {
        """
        # MK learned dictionary — 用户每次 --learn 自动追加
        # 格式：正字 | 错音1 | 错音2

        """
    }
}
