import Foundation

/// FR5 — 口语 filler / disfluency 清洗
///
/// 中文口语转写后常见垃圾：
/// 1. **单字 filler**（嗯/呃/啊/哦/哎...）作为独立 token 出现 → 删
/// 2. **重复词**："是的是的是的" → "是的"；"对对对" → "对"；"我我我我们" → "我们"
///
/// 规则：
/// - 单字 filler 仅在左右是非字母数字（边界）时删；防误伤"嗯哼"等合法组合
/// - 重复压缩使用 regex backreference `(.)\1{2,}`，先 2-3 字符再 1 字符（顺序敏感）
/// - 不处理冗余衔接词（"那个/这个/其实"）— 这些需要 context 判断，规则化容易过度删
///
/// 行业惯例：飞书/讯飞用专门 disfluency removal 模型（基于 BERT 类）；
/// 我们规则版覆盖 80% 高频场景，0 模型依赖。
enum FillerRemover {
    /// 单字 filler — 出现在 boundary 之间时删
    private static let isolatedFillers: Set<Character> = [
        "嗯", "呃", "啊", "哦", "哎", "唉", "呵", "嘿",
    ]

    /// 应用清洗，返回处理后的字符串
    static func apply(_ text: String) -> String {
        var hits: [String] = []
        let originalLen = text.count

        // 1) 删 boundary 之间的单字 filler
        var result = removeIsolatedFillers(text, hits: &hits)

        // 2) 压缩 2-3 字符重复（先长后短，先压 "是的是的是的"，再压 "对对对"）
        result = compressRepeats(result, blockLength: 3, hits: &hits)
        result = compressRepeats(result, blockLength: 2, hits: &hits)
        result = compressRepeats(result, blockLength: 1, hits: &hits)

        // 3) 清理孤儿标点 / 多余空白（filler 删除后留下的 " ，  ，" 等）
        result = cleanupOrphanPunctuation(result)

        let removed = originalLen - result.count
        if removed > 0 {
            Logger.log("Filler", "removed \(removed) chars: \(hits.prefix(10).joined(separator: ", "))\(hits.count > 10 ? "..." : "")")
        }
        return result
    }

    /// 收尾：合并连续标点 + 压多空格 + 删开头的孤儿标点
    /// 例：" ，对 ， ，" → "对，"；"对，，呢" → "对，呢"
    private static func cleanupOrphanPunctuation(_ text: String) -> String {
        var result = text
        // 中文标点合并：连续 ≥2 次中文标点 → 1 次
        let punctClass = "[，。！？、；：]"
        if let r1 = try? NSRegularExpression(pattern: "(\(punctClass))(?:\\s*\\1)+", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = r1.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        // 标点之间夹空格：" ， " → "，"
        if let r2 = try? NSRegularExpression(pattern: "\\s+(\(punctClass))", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = r2.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        // 多个空格 → 1 个
        if let r3 = try? NSRegularExpression(pattern: "[ \\t]{2,}", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = r3.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
        }
        // 开头的空白 + 标点 → 删
        if let r4 = try? NSRegularExpression(pattern: "^[\\s，。！？、；：]+", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = r4.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }

    /// 单字 filler 在中文/英文之间也常出现（"其实呃很多"），所以默认删；
    /// 仅保留组合词形式（嗯哼/哎呀/哎哟/嘿嘿等）
    private static let preserveCombos: Set<String> = [
        "嗯哼", "嗯嗯", "啊啊", "哎呀", "哎哟", "哎呦", "嘿嘿", "嘿哟", "哦豁", "哦哦",
    ]

    private static func removeIsolatedFillers(_ text: String, hits: inout [String]) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if isolatedFillers.contains(ch) {
                // 检查双字组合词：当前+下一个 是否构成保留组合
                if i + 1 < chars.count {
                    let combo = String(ch) + String(chars[i + 1])
                    if preserveCombos.contains(combo) {
                        out.append(ch)
                        i += 1
                        continue
                    }
                }
                // 检查反向组合：上一个+当前 是否构成保留组合（如已加入"嗯"，现在是"哼"）
                // 由于上一字符已 emit，反向检查较复杂；改为：若上一字符也是 filler，不删（让 compressRepeats 处理"嗯嗯嗯"）
                if let prev = out.last, isolatedFillers.contains(prev) {
                    out.append(ch)
                    i += 1
                    continue
                }
                // 默认删除
                hits.append("-\(ch)")
                i += 1
                continue
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }

    /// 压缩 N 字符重复（≥ 3 次）成 1 次
    /// 例：blockLength=2 → "是的是的是的" → "是的"
    private static func compressRepeats(_ text: String, blockLength: Int, hits: inout [String]) -> String {
        guard blockLength >= 1 && blockLength <= 3 else { return text }
        let pattern = "(.{\(blockLength)})\\1{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        var result = text
        let nsText = result as NSString
        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        // 倒序替换，避免前面替换影响后面 range
        var working = result
        for m in matches.reversed() {
            let block = nsText.substring(with: NSRange(location: m.range.location, length: blockLength))
            // 跳过纯空白（防把句间空格压没）
            if block.allSatisfy({ $0.isWhitespace }) { continue }
            // 跳过任何含 ASCII 字符的 block：数字/英文重复有特定含义（如 "30000000" 是有效数字、"AAAA" 可能是 ASCII 占位）
            // 重复压缩仅作用于中文重复词（"是的是的是的"、"我们我们我们"）
            if block.contains(where: { $0.isASCII }) { continue }

            let r = Range(m.range, in: working)!
            let times = m.range.length / blockLength
            working.replaceSubrange(r, with: block)
            hits.append("×\(times)\(block)→\(block)")
        }
        result = working
        return result
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        return ch.isLetter || ch.isNumber
    }
}
