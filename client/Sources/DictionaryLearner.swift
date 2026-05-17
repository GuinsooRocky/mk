import Foundation

/// 错例反馈学习：把"用户实际说错过的词"沉淀到 learned 字典。
///
/// 写入 `~/.mk/correction-dictionary-learned.txt`：
///   `正字 | 错音1#次数 | 错音2#次数`
///
/// - 同 `(正字, 错音)` 重复学习 → 次数累加（不再去重丢弃）。
/// - 同一错音映射到多个正字 → 全部保留，load 时按学习次数高者裁决（见 CorrectionDictionary.parseTxt）。
/// - 错音侧本身是合法词（域内术语 / 常见英文词）→ 拒学：这种对天然歧义、注定投毒。
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

        // Fix 2：错音侧本身是合法词 → 拒学。学这条会让你以后再也没法正常听写出该词。
        if let realKind = realWordKind(w) {
            Logger.log("Learn", "reject: '\(w)' 是\(realKind)，拒学 '\(w)'→'\(c)'（会让 '\(w)' 永远没法被听写出来）")
            return "skip: '\(w)' 本身是\(realKind)，学 '\(w)'→'\(c)' 会污染该词的正常听写（拒学）"
        }

        var lines = (try? String(contentsOf: learnedURL, encoding: .utf8)) ?? defaultHeader()
        if lines.isEmpty { lines = defaultHeader() }

        // 扫全文：命中同正字行 → 次数累加；w 出现在别的正字行 → 记冲突（不动它）。
        var found = false
        var bumped = false
        var conflictWith: [String] = []
        let split = lines.components(separatedBy: .newlines)
        var newLines: [String] = []
        for line in split {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                newLines.append(line)
                continue
            }
            let parts = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = parts.first, !head.isEmpty else {
                newLines.append(line)
                continue
            }
            let errToks = parts.dropFirst().filter { !$0.isEmpty }

            if head != c {
                // Fix 1：w 已映射到别的正字 → 冲突。保留原行不动，交给 load 时按次数裁决。
                if errToks.contains(where: { CorrectionDictionary.parseErrToken($0).err == w }) {
                    conflictWith.append(head)
                }
                newLines.append(line)
                continue
            }

            // 命中同正字行：找到 w 则次数 +1，否则追加 `w#1`
            found = true
            var rebuilt: [String] = [c]
            var hitW = false
            for tok in errToks {
                let (err, count) = CorrectionDictionary.parseErrToken(tok)
                if err == w {
                    hitW = true
                    rebuilt.append("\(err)#\(count + 1)")
                } else {
                    rebuilt.append("\(err)#\(count)")
                }
            }
            if !hitW { rebuilt.append("\(w)#1") }
            bumped = hitW
            newLines.append(rebuilt.joined(separator: " | "))
        }
        if !found {
            newLines.append("\(c) | \(w)#1")
        }

        let final = newLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        do {
            try final.write(to: learnedURL, atomically: true, encoding: .utf8)
        } catch {
            return "error: write failed: \(error)"
        }

        // reload 字典
        reloadAllDictionaries()

        // 翻 learning_happened flag（首次 learn 即算学习发生过）
        let already = (RuntimeConfig.shared.polishConfig["learning_happened"] as? Bool) ?? false
        if !already {
            RuntimeConfig.shared.setPolishField("learning_happened", value: true)
        }

        // Fix 1：冲突显式上报，不静默
        if !conflictWith.isEmpty {
            Logger.log("Learn", "⚠️ conflict: 错音 '\(w)' 同时映射到 [\(conflictWith.joined(separator: ", "))] 和 '\(c)' — 全部保留，load 时学习次数高者赢")
        }

        let countAction = found ? (bumped ? "次数 +1" : "追加新错音 #1") : "新建条目 #1"
        let conflictNote = conflictWith.isEmpty ? "" : " ⚠️ 与 [\(conflictWith.joined(separator: ", "))] 冲突，按次数裁决"
        return "learn ok: \(c) | \(w) → \(countAction)\(conflictNote) → \(learnedURL.path)"
    }

    /// 错音侧若本身是合法词，返回它的类别描述；否则 nil。
    /// 命中 → 不该学这条纠错对（学了该词会永远被改写、没法正常听写出来）。
    private static func realWordKind(_ w: String) -> String? {
        let lower = w.lowercased()
        if CorrectionDictionary.commonEnglishWords.contains(lower) { return "常见英文词" }
        // 域内字典术语 — ASCII 词大小写不敏感比较
        if CorrectionDictionary.shared.termsSet.contains(where: { $0.lowercased() == lower }) {
            return "字典术语"
        }
        return nil
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
        # 格式：正字 | 错音1#次数 | 错音2#次数

        """
    }
}
