import Foundation

/// 加载 ~/.we/correction-dictionary.{json,txt,md}
/// - .json：`{"正确词": {...}, ...}` keys 即 terms；`_` 开头的 key 视为 meta 跳过
/// - .txt / .md：一行一词；空行忽略；`#` 开头视为注释
/// 注入 SA 的 contextualStrings，用正确词作为 hint
@MainActor
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private(set) var terms: [String] = []
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
            terms = []
            loadedPath = nil
            return false
        }

        let parsedTerms: [String]?
        if url.pathExtension.lowercased() == "json" {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            parsedTerms = json.map { Array($0.keys).filter { !$0.hasPrefix("_") } }
        } else {
            // .txt / .md / 其他：一行一词，# 开头注释，空行忽略
            parsedTerms = String(data: data, encoding: .utf8)?
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        guard let parsed = parsedTerms else {
            Logger.log("Dict", "Parse failed: \(expanded)")
            terms = []
            loadedPath = nil
            return false
        }

        terms = parsed
        loadedPath = expanded
        Logger.log("Dict", "Loaded \(parsed.count) terms from \(expanded)")
        return true
    }
}
