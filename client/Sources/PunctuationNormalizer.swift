import Foundation

/// FR4 v0.1 — 中文口语 → 标点符号
///
/// 触发规则：仅当口语词作为**独立 token** 出现时才替换。
/// 「独立 token」= 前后是空格/标点/字符串边界，不是中英文字母数字。
/// 避免「括号里的内容」被误伤为「（里的内容」。
///
/// 行业惯例（飞书/腾讯/讯飞）：用专门的 ITN（Inverse Text Normalization）
/// 模型 + 上下文理解。我们用简化版规则匹配 + 边界条件，覆盖 80% 高频场景。
enum PunctuationNormalizer {
    /// 口语 → 符号映射；按 source 长度倒序匹配，避免「右括号」被「括号」覆盖
    private static let rules: [(source: String, target: String)] = [
        ("回车", "\n"),
        ("换行", "\n"),
        ("感叹号", "！"),
        ("左括号", "（"),
        ("右括号", "）"),
        ("反括号", "）"),
        ("分号", "；"),
        ("冒号", "："),
        ("问号", "？"),
        ("逗号", "，"),
        ("句号", "。"),
        ("括号", "（"),       // 兜底，仅在 left/right 未匹配时
    ]

    /// 字符是否属于"会让左右成为非边界"的类型（中英字母 / 数字）
    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    /// 应用 normalize，返回处理后的字符串
    /// - 仅替换满足"独立 token"条件的 source
    static func apply(_ text: String) -> String {
        var result = text
        var hits: [String] = []
        for (source, target) in rules {
            // 重复扫直到找不到独立 token 形式的 source
            while let range = findIsolatedRange(of: source, in: result) {
                result.replaceSubrange(range, with: target)
                hits.append("\(source)→\(target == "\n" ? "\\n" : target)")
            }
        }
        if !hits.isEmpty {
            Logger.log("Punct", "normalize: \(hits.joined(separator: ", "))")
        }
        return result
    }

    /// 找一个"独立 token"形式的 source 在 text 里的 range；找不到返回 nil
    /// 独立 = 左侧字符不是 wordChar，右侧字符也不是 wordChar（边界视为非 wordChar）
    private static func findIsolatedRange(of source: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: source, range: searchStart..<text.endIndex) {
            let leftIsBoundary: Bool = (r.lowerBound == text.startIndex) ||
                !isWordChar(text[text.index(before: r.lowerBound)])
            let rightIsBoundary: Bool = (r.upperBound == text.endIndex) ||
                !isWordChar(text[r.upperBound])
            if leftIsBoundary && rightIsBoundary {
                return r
            }
            searchStart = r.upperBound
        }
        return nil
    }
}
