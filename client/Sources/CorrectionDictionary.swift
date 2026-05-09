import Foundation

/// 加载 ~/.we/correction-dictionary.{json,txt,md}
///
/// **terms**：注入 SA 的 contextualStrings
/// **corrections**：识别后做反向替换的 [错音 → 正字] 映射（VoicePipeline 用）
///
/// .json 格式：`{"正确词": {"errors": ["错音1","错音2"], ...}}`；`_` 前缀 key 视为 meta 跳过
/// .txt / .md 格式：
///   - 一行一词，`Word` 或 `Word | 错音1 | 错音2`
///   - 空行忽略，`#` 开头视为注释
@MainActor
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private(set) var terms: [String] = []
    /// 错音 → 正字映射；VoicePipeline 在 inject 前用 `correct(_:)` 应用
    private(set) var corrections: [String: String] = [:]
    /// 按错音长度倒序排好的 keys，确保替换时长词优先（避免 "Plus I can" 被 "I" 提前替换）
    private(set) var sortedErrorKeys: [String] = []
    private(set) var loadedPath: String?

    private init() {}

    /// 加载单个字典（向后兼容入口）
    @discardableResult
    func load(from path: String) -> Bool {
        return loadAll(from: [path])
    }

    /// 加载多个字典（按顺序合并）
    /// 后加载的 manual corrections 不覆盖前面的（先来先得）
    /// terms 去重保留首次出现顺序；C5 在合并完后统一一次派生
    @discardableResult
    func loadAll(from paths: [String]) -> Bool {
        var combinedTerms: [String] = []
        var combinedCorrections: [String: String] = [:]
        var seenTerms = Set<String>()
        var loadedPaths: [String] = []
        var manualCount = 0

        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: expanded),
                  let data = try? Data(contentsOf: url) else {
                Logger.log("Dict", "Load skip (missing): \(expanded)")
                continue
            }

            let parsed: (terms: [String], corrections: [String: String])?
            if url.pathExtension.lowercased() == "json" {
                parsed = parseJSON(data)
            } else {
                parsed = parseTxt(data)
            }
            guard let p = parsed else {
                Logger.log("Dict", "Parse failed: \(expanded)")
                continue
            }

            for term in p.terms where seenTerms.insert(term).inserted {
                combinedTerms.append(term)
            }
            for (err, correct) in p.corrections where combinedCorrections[err] == nil {
                combinedCorrections[err] = correct
                manualCount += 1
            }
            loadedPaths.append(expanded)
            Logger.log("Dict", "Loaded \(p.terms.count) terms + \(p.corrections.count) manual corrections from \(expanded)")
        }

        guard !combinedTerms.isEmpty else {
            reset()
            return false
        }

        // C5：自动派生错音变体（不覆盖手动 `|` 显式登记的）
        var synthesized = 0
        for term in combinedTerms {
            for variant in Self.synthesizeVariants(for: term) where combinedCorrections[variant] == nil {
                combinedCorrections[variant] = term
                synthesized += 1
            }
        }

        terms = combinedTerms
        corrections = combinedCorrections
        sortedErrorKeys = combinedCorrections.keys.sorted { $0.count > $1.count }
        loadedPath = loadedPaths.joined(separator: ", ")
        Logger.log("Dict", "Total: \(combinedTerms.count) terms + \(combinedCorrections.count) corrections (manual=\(manualCount), synth=\(synthesized)) from \(loadedPaths.count) files")
        return true
    }

    // MARK: - C5 synthesizeVariants

    /// ASR 字符级常见混淆表（中文模型把英文字母/缩写听错的常见替换）
    /// 表是经验性的，发现新错音模式直接加一行
    private static let confusionTable: [Character: [Character]] = [
        "V": ["A", "J", "F", "B"],
        "G": ["J", "C"],
        "B": ["P", "V", "D"],
        "M": ["N"],
        "S": ["X", "C", "F"],
        "Z": ["S", "C"],
        "X": ["S", "K"]
    ]

    /// 给一个 term 生成可能的错音变体（加载时一次性派生）
    static func synthesizeVariants(for term: String) -> [String] {
        var variants = Set<String>()

        // 规则 1：全大写缩写（≤6 字符纯字母）
        if term.count >= 2 && term.count <= 6,
           term.allSatisfy({ $0.isLetter && $0.isUppercase }) {
            // 1a. 字母间空格："SVG" → "S V G"
            variants.insert(term.map { String($0) }.joined(separator: " "))
            // 1b. 字母替换
            let chars = Array(term)
            for (i, ch) in chars.enumerated() {
                if let alts = confusionTable[ch] {
                    for alt in alts {
                        var copy = chars
                        copy[i] = alt
                        variants.insert(String(copy))
                    }
                }
            }
        }

        // 规则 2：驼峰命名（含大小写边界，无空格）
        if !term.contains(" "),
           zip(term, term.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) {
            // 2a. 拆词："SwiftUI" → "Swift UI"
            var spaced = ""
            for (i, ch) in term.enumerated() {
                if i > 0 {
                    let prev = term[term.index(term.startIndex, offsetBy: i - 1)]
                    if prev.isLowercase && ch.isUppercase {
                        spaced.append(" ")
                    }
                }
                spaced.append(ch)
            }
            variants.insert(spaced)
            // 2b. 拆词后小写
            variants.insert(spaced.lowercased())
        }

        // 规则 3：保底加全小写（"SwiftUI" → "swiftui"，"SVG" → "svg"）
        let lower = term.lowercased()
        if lower != term {
            variants.insert(lower)
        }

        variants.remove(term)  // 不与原词冲突
        return Array(variants)
    }

    /// 应用反向纠错（两层）：
    /// 1. 精确字符串替换（含 C5 派生的 corrections）— O(1) 哈希查找，<1ms
    /// 2. Levenshtein 模糊匹配 — 对未命中的英文 token 找距离最近的 term，5-15ms
    ///    阈值: max(1, token.count / 4)（"SwiftUI"=8字 → 容忍 2 字符差，"SVG"=3字 → 容忍 1 字符差）
    func correct(_ text: String) -> String {
        var result = text
        var hits: [String] = []

        // Layer 1: 精确字符串替换
        if !sortedErrorKeys.isEmpty {
            for err in sortedErrorKeys {
                guard let correct = corrections[err], result.contains(err) else { continue }
                result = result.replacingOccurrences(of: err, with: correct)
                hits.append("=\(err)→\(correct)")
            }
        }

        // Layer 2: Levenshtein 模糊匹配（兜底未命中的英文 token）
        let asciiTerms = terms.filter { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0 == " ") } && $0.count >= 2 }
        if !asciiTerms.isEmpty {
            // tokenize: 按空格/中文/标点切分
            let tokens = result.split(whereSeparator: { !$0.isASCII || $0.isWhitespace || $0.isPunctuation })
            var processed = Set<String>()  // 避免对同一 token 重复处理
            for token in tokens {
                let tok = String(token)
                guard tok.count >= 2,
                      tok.allSatisfy({ $0.isASCII && $0.isLetter }),
                      !asciiTerms.contains(tok),  // 已是字典正字，跳过
                      !processed.contains(tok) else { continue }
                processed.insert(tok)

                let maxDist = max(1, tok.count / 4)
                var best: (term: String, dist: Int)?
                for term in asciiTerms {
                    // 长度差 > maxDist 直接 skip（O(1) 早 reject）
                    if abs(term.count - tok.count) > maxDist { continue }
                    let d = Self.levenshtein(tok, term)
                    if d <= maxDist && d > 0 && (best == nil || d < best!.dist) {
                        best = (term, d)
                    }
                }
                if let b = best {
                    result = result.replacingOccurrences(of: tok, with: b.term)
                    hits.append("~\(tok)→\(b.term)(d=\(b.dist))")
                }
            }
        }

        if !hits.isEmpty {
            Logger.log("Dict", "correct: \(hits.joined(separator: ", "))")
        }
        return result
    }

    /// 经典 Damerau-Lite Levenshtein（不含相邻交换）。两行 DP，O(m×n)
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aArr = Array(a)
        let bArr = Array(b)
        let m = aArr.count
        let n = bArr.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                if aArr[i - 1] == bArr[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = 1 + min(prev, min(dp[j - 1], dp[j]))
                }
                prev = temp
            }
        }
        return dp[n]
    }

    // MARK: - parsing

    private func parseJSON(_ data: Data) -> (terms: [String], corrections: [String: String])? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var terms: [String] = []
        var corrections: [String: String] = [:]
        for (key, value) in json {
            guard !key.hasPrefix("_") else { continue }
            terms.append(key)
            if let entry = value as? [String: Any], let errors = entry["errors"] as? [String] {
                for err in errors where !err.isEmpty {
                    corrections[err] = key
                }
            }
        }
        return (terms, corrections)
    }

    private func parseTxt(_ data: Data) -> (terms: [String], corrections: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var terms: [String] = []
        var corrections: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let term = parts.first, !term.isEmpty else { continue }
            terms.append(term)
            for err in parts.dropFirst() where !err.isEmpty {
                corrections[err] = term
            }
        }
        return (terms, corrections)
    }

    private func reset() {
        terms = []
        corrections = [:]
        sortedErrorKeys = []
        loadedPath = nil
    }
}
