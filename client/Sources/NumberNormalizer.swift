import Foundation

/// FR6 — 中文数字读法 → 阿拉伯数字（轻量 ITN）
///
/// 业界叫 ITN (Inverse Text Normalization)，主流方案 WFST + NN（飞书/讯飞/Google）。
/// 我们端侧 + 240ms 上限不允许 LLM，写一个轻量规则版覆盖中文数字 80% 场景。
///
/// 支持：
/// - **L1 单字符**：零一二三四五六七八九 → 0-9
/// - **L2 复合**：一千二百三十四 → 1234（状态机：digit + unit + 累加）
/// - **L3 量级**：三千万 → 30000000；一亿三千万 → 130000000
/// - **L4 小数**：三点一四 → 3.14
///
/// **不支持**（规则极限）：
/// - 大写数字（壹贰叁）— 罕见
/// - 百分号转换（百分之九十 → 90%）— 留后续
/// - 时间表达（三点半 → 3:30）— 歧义
/// - 上下文敏感量级补全（"100 token" → "100k token"）— 需 LLM
/// - 截断恢复（"024 年" → "2024 年"）— 需 LLM
///
/// **算法**：
/// 1. Tokenize：扫文本，找连续的"数字读法 span"（含中文数字字符 + 可选"点"）
/// 2. Parse 每个 span 成数值（区分 digit-by-digit vs unit-based）
/// 3. Format 回文本，替换原 span
enum NumberNormalizer {
    // MARK: - Character tables

    /// 0-9 数字字符 → 数值
    private static let digitMap: [Character: Int] = [
        "零": 0, "〇": 0, "○": 0,
        "一": 1, "壹": 1,
        "二": 2, "两": 2, "贰": 2,
        "三": 3, "叁": 3,
        "四": 4, "肆": 4,
        "五": 5, "伍": 5,
        "六": 6, "陆": 6,
        "七": 7, "柒": 7,
        "八": 8, "捌": 8,
        "九": 9, "玖": 9,
    ]

    /// 小单位（十/百/千） — 累加到当前 section
    private static let smallUnitMap: [Character: Int] = [
        "十": 10, "拾": 10,
        "百": 100, "佰": 100,
        "千": 1000, "仟": 1000,
    ]

    /// 大单位（万/亿） — flush 到 result
    private static let largeUnitMap: [Character: Int] = [
        "万": 10_000, "萬": 10_000,
        "亿": 100_000_000, "億": 100_000_000,
    ]

    private static let decimalChar: Character = "点"

    /// 一个字符是否参与"数字 span"
    private static func isNumberChar(_ ch: Character) -> Bool {
        return digitMap[ch] != nil
            || smallUnitMap[ch] != nil
            || largeUnitMap[ch] != nil
            || ch == decimalChar
    }

    // MARK: - Public API

    static func apply(_ text: String) -> String {
        var hits: [(span: String, replaced: String)] = []
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            // 找一个 number span
            if isNumberChar(chars[i]) {
                let spanStart = i
                while i < chars.count && isNumberChar(chars[i]) {
                    i += 1
                }
                let spanEnd = i  // exclusive
                let span = String(chars[spanStart..<spanEnd])

                // 解析 + format
                if let formatted = parseAndFormat(span: span) {
                    out.append(contentsOf: formatted)
                    hits.append((span, formatted))
                } else {
                    // 无法 parse，原样保留
                    out.append(contentsOf: span)
                }
                continue
            }
            out.append(chars[i])
            i += 1
        }

        if !hits.isEmpty {
            let preview = hits.prefix(5).map { "\($0.span)→\($0.replaced)" }.joined(separator: ", ")
            Logger.log("Number", "normalize \(hits.count): \(preview)\(hits.count > 5 ? "..." : "")")
        }
        return String(out)
    }

    /// 解析一段连续中文数字 span，返回阿拉伯字符串；解析失败 → nil（保留原文）
    private static func parseAndFormat(span: String) -> String? {
        let chars = Array(span)
        guard !chars.isEmpty else { return nil }

        // 1) 长度 1：单字符 digit
        if chars.count == 1 {
            if let d = digitMap[chars[0]] { return String(d) }
            return nil  // 单个 unit 字符（"十"/"万"等）没有数字意义，保留
        }

        // 2) 含小数点 → split + parse 两段
        if let dotIdx = chars.firstIndex(of: decimalChar) {
            let intPart = Array(chars[..<dotIdx])
            let fracPart = Array(chars[(dotIdx + 1)...])
            // 整数部分用 unit-based 或 digit-by-digit
            guard let intStr = formatPart(intPart) else { return nil }
            // 小数部分必须 digit-by-digit（"点一四" → ".14"）
            var fracStr = ""
            for c in fracPart {
                guard let d = digitMap[c] else { return nil }
                fracStr.append(String(d).first!)
            }
            // 末尾若有 large unit，"一点三亿" → 1.3 * 10^8
            // （但 "一点三亿" 我们这条路不会进 — 因为 dotIdx 之后还有大单位的话，fracPart 解析会失败）
            return intStr + (fracStr.isEmpty ? "" : "." + fracStr)
        }

        // 3) 全 digit 字符 → digit-by-digit（年份/电话号场景：二零二四 → 2024）
        if chars.allSatisfy({ digitMap[$0] != nil }) {
            return chars.compactMap { digitMap[$0] }.map(String.init).joined()
        }

        // 4) 含 unit → unit-based parse
        return formatPart(chars)
    }

    /// 把一段 chars 解析成阿拉伯字符串。
    /// 优先 unit-based；如果全是 digit 走 digit-by-digit。
    private static func formatPart(_ chars: [Character]) -> String? {
        if chars.isEmpty { return "" }

        // 全 digit → digit-by-digit
        if chars.allSatisfy({ digitMap[$0] != nil }) {
            return chars.compactMap { digitMap[$0] }.map(String.init).joined()
        }

        // unit-based 状态机
        // section: 当前小节累加值（含十/百/千）
        // result: 已 flush 的大单位部分（万 flush 后, 亿 flush 后）
        var result = 0
        var section = 0
        var lastDigit = -1  // -1 表示无；当前累积的 single digit（待乘 unit 或并入 section）

        for ch in chars {
            if let d = digitMap[ch] {
                if lastDigit >= 0 {
                    // 连续两个 digit char（如 "三五" — 视为非法 unit-based，保守 fail）
                    return nil
                }
                lastDigit = d
            } else if let u = smallUnitMap[ch] {
                // 十/百/千 — 把 lastDigit（默认 1）乘进去，并入 section
                let mult = lastDigit >= 0 ? lastDigit : 1
                section += mult * u
                lastDigit = -1
            } else if let bu = largeUnitMap[ch] {
                // 万/亿 — flush section 到 result
                let base = section + (lastDigit >= 0 ? lastDigit : 0)
                let toFlush = base == 0 ? 1 : base  // "亿" 单独出现视为 1 亿
                result += toFlush * bu
                section = 0
                lastDigit = -1
            } else {
                // 不应该走到（tokenize 已过滤）
                return nil
            }
        }

        // 收尾
        if lastDigit >= 0 { section += lastDigit }
        result += section

        return result == 0 ? nil : String(result)
    }
}
