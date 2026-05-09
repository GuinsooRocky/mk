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

    /// 加载字典，返回是否成功
    @discardableResult
    func load(from path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded),
              let data = try? Data(contentsOf: url) else {
            Logger.log("Dict", "Load failed: \(expanded)")
            reset()
            return false
        }

        let parsed: (terms: [String], corrections: [String: String])?
        if url.pathExtension.lowercased() == "json" {
            parsed = parseJSON(data)
        } else {
            parsed = parseTxt(data)
        }

        guard let p = parsed else {
            Logger.log("Dict", "Parse failed: \(expanded)")
            reset()
            return false
        }

        terms = p.terms
        corrections = p.corrections
        sortedErrorKeys = corrections.keys.sorted { $0.count > $1.count }
        loadedPath = expanded
        Logger.log("Dict", "Loaded \(p.terms.count) terms + \(p.corrections.count) corrections from \(expanded)")
        return true
    }

    /// 应用反向纠错：扫描 text 把已知错音替换为正字
    /// 长错音优先匹配，避免短词把长词的子串提前替换掉
    func correct(_ text: String) -> String {
        guard !sortedErrorKeys.isEmpty else { return text }
        var result = text
        var hits: [String] = []
        for err in sortedErrorKeys {
            guard let correct = corrections[err], result.contains(err) else { continue }
            result = result.replacingOccurrences(of: err, with: correct)
            hits.append("\(err)→\(correct)")
        }
        if !hits.isEmpty {
            Logger.log("Dict", "correct: \(hits.joined(separator: ", "))")
        }
        return result
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
