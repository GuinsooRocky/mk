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
    /// 这些规则**严格 isolated token 边界**才替换，防误伤"括号里的内容"等
    /// 命令词的长 source 在前：吸掉 SA 自动追加的尾标点（"回车。" 整体替换，避免残留 。）
    private static let rules: [(source: String, target: String)] = [
        ("回车。", "\n"),
        ("回车，", "\n"),
        ("回车！", "\n"),
        ("回车？", "\n"),
        ("回车", "\n"),
        ("换行。", "\n"),
        ("换行，", "\n"),
        ("换行！", "\n"),
        ("换行？", "\n"),
        ("换行", "\n"),
        // 中划线/横杠/减号 → ASCII -（用户偏好：技术文本里要 ASCII 而非全角 —）
        ("中划线。", "-"), ("中划线，", "-"), ("中划线！", "-"), ("中划线？", "-"), ("中划线", "-"),
        ("短横线。", "-"), ("短横线，", "-"), ("短横线！", "-"), ("短横线？", "-"), ("短横线", "-"),
        ("横杠。", "-"), ("横杠，", "-"), ("横杠！", "-"), ("横杠？", "-"), ("横杠", "-"),
        ("减号。", "-"), ("减号，", "-"), ("减号！", "-"), ("减号？", "-"), ("减号", "-"),
        // 单字"杠" 风险词：会误伤"抬杠/杠精/单杠/杠杠的"；但 isolated token 检查（前后非 wordChar）能挡住——
        // 中文字符在 Swift Character.isLetter 里是 true，所以 "杠杠" 这种连续不会被替换。
        ("杠。", "-"), ("杠，", "-"), ("杠！", "-"), ("杠？", "-"), ("杠", "-"),
        ("感叹号", "！"),
        // 注：左括号/右括号/反括号/括号 全部移交 smartParens 智能处理（栈式配对 + 半角输出）
        ("分号", "；"),
        ("冒号", "："),
        ("问号", "？"),
        ("逗号", "，"),
        ("句号", "。"),
    ]

    /// 不要边界检查，全文匹配的"硬替换"规则
    /// 用于在自然中文语境（无空白）下也想强制触发的口语词
    /// 风险：如果用户真要打这两字（如"键盘空格键"），会被改。但语音输入里这种场景极少
    /// 长 source 在前：吸掉 SA 自动追加的尾标点（"空格。" 整体替换，避免残留 。）
    private static let unboundedRules: [(source: String, target: String)] = [
        ("空格。", "\n"),
        ("空格，", "\n"),
        ("空格！", "\n"),
        ("空格？", "\n"),
        ("空格", "\n"),       // 用户偏好：说"空格" 强制另起一行，不管前后是啥
    ]

    /// 字符是否属于"会让左右成为非边界"的类型（中英字母 / 数字）
    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    /// 应用 normalize，返回处理后的字符串
    /// - 0. smartParens：栈式配对处理所有 "[左/右/反/又/U/...]括号" 字眼，输出半角 ( )
    /// - 严格规则：仅替换满足"独立 token"条件的 source（不再含括号类规则）
    /// - unboundedRules：不管边界，全文搜索替换
    static func apply(_ text: String) -> String {
        var hits: [String] = []
        // 砍掉引擎在松手时自动补的句尾「。」(含其后空白)：push-to-talk 常说半句就松手、后面再补，
        // 强行加的句号几乎都是错的（用户反馈：逗号好用、就这个尾句号烦）。
        // 注意：必须在 rules 之前做——用户口述的"句号"此刻还是文字"句号"，rules 之后才变「。」，所以不受影响。
        var stripped = text
        while let last = stripped.last, last == "。" || last.isWhitespace {
            stripped.removeLast()
        }
        // 0. 智能括号配对——见 smartParens 详注
        var result = smartParens(in: stripped, hits: &hits)
        for (source, target) in rules {
            // 重复扫直到找不到独立 token 形式的 source
            while let range = findIsolatedRange(of: source, in: result) {
                result.replaceSubrange(range, with: target)
                hits.append("\(source)→\(target == "\n" ? "\\n" : target)")
            }
        }
        // unboundedRules：全文替换（无边界）
        for (source, target) in unboundedRules {
            if result.contains(source) {
                let count = result.components(separatedBy: source).count - 1
                result = result.replacingOccurrences(of: source, with: target)
                hits.append("\(source)→\(target == "\n" ? "\\n" : target)×\(count)")
            }
        }
        // SA 句号过频降级：「。」紧跟中文字（CJK）→「，」
        // 因为 SA 中文模型在每个停顿都加一个 。，但很多其实是句子内停顿
        // 真句号只保留在「字符串结尾 / 紧跟空白 / 紧跟英文 / 紧跟其他标点」前
        let demoted = demoteSentencePeriods(in: result, hits: &hits)
        if demoted != result {
            result = demoted
        }
        if !hits.isEmpty {
            Logger.log("Punct", "normalize: \(hits.joined(separator: ", "))")
        }
        return result
    }

    /// 「。」+ 中日韩字符 → 「，」+ 中日韩字符
    /// CJK Unified: U+4E00-U+9FFF（中文）、U+3040-U+30FF（日文假名）
    private static func demoteSentencePeriods(in text: String, hits: inout [String]) -> String {
        guard text.contains("。") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text)
        var demoteCount = 0
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch == "。", i + 1 < chars.count {
                let next = chars[i + 1]
                if isCJK(next) {
                    out.append("，")
                    demoteCount += 1
                    continue
                }
            }
            out.append(ch)
        }
        if demoteCount > 0 {
            hits.append("。→，×\(demoteCount)")
        }
        return out
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            // 中文（CJK Unified）
            if (0x4E00...0x9FFF).contains(v) { return true }
            // 日文平假名 + 片假名
            if (0x3040...0x309F).contains(v) { return true }
            if (0x30A0...0x30FF).contains(v) { return true }
        }
        return false
    }

    /// 智能括号：所有"括号"字眼按栈奇偶配对，输出半角 ( )
    ///
    /// Why: 中文连续语流 + Apple SA 错识别"左/右"为"又/U/啊"等同音字，让命令式 "左括号/右括号"
    ///      规则在用户实际使用时极不稳定。统一改成"只认'括号'两字 + 栈状态"。
    ///
    /// 规则：
    /// - 文本里已有的 `(`/`（`/`)`/`）` 字符照常进出栈，参与判断
    /// - 遇到"括号"两字：
    ///     - 前一个字是"左"     → 强制开 `(`，吃掉"左"前缀
    ///     - 前一个字是"右/反"    → 强制闭 `)`，吃掉前缀
    ///     - 其他前缀（"又/U/啊"等同音误识别）或无前缀 → 按栈奇偶：栈空开 `(`，栈非空闭 `)`
    /// - 输出始终半角，方便代码场景
    ///
    /// How to apply: 在 strict rules 之前调用，避免与"括号"兜底冲突（兜底已删）
    private struct BracketKind {
        let opener: Character
        let closer: Character
    }

    private static let roundKind  = BracketKind(opener: "(", closer: ")")
    private static let squareKind = BracketKind(opener: "[", closer: "]")
    private static let curlyKind  = BracketKind(opener: "{", closer: "}")
    private static let angleKind  = BracketKind(opener: "<", closer: ">")

    /// modifier 字 → 括号种类
    /// 中/方 → 方括号 []，大/花 → 花括号 {}，尖 → 尖括号 <>
    private static let modifierMap: [Character: BracketKind] = [
        "中": squareKind, "方": squareKind,
        "大": curlyKind,  "花": curlyKind,
        "尖": angleKind,
    ]

    /// "括"字的常见 ASR 同音/近音误识别集合
    /// Why: Apple SA 把"括"(kuò) 频繁错为 国/火/惑/扩/后/阔/廓 — 日志里能看见 alt 候选其实有"括"，
    ///      但默认输出了同音字。我们在 normalize 层兜底，让任何同音字 + "号" 都当 bracket 处理。
    private static let kuoChars: Set<Character> = ["括", "国", "火", "惑", "扩", "后", "阔", "廓"]

    /// 识别既有的括号字符；入栈用于无 prefix 时判断开/闭
    private static func isOpenerChar(_ ch: Character) -> Bool {
        ch == "(" || ch == "（" || ch == "[" || ch == "【" || ch == "{" || ch == "<"
    }
    private static func isCloserChar(_ ch: Character) -> Bool {
        ch == ")" || ch == "）" || ch == "]" || ch == "】" || ch == "}" || ch == ">"
    }

    private static func smartParens(in text: String, hits: inout [String]) -> String {
        // 任何 kuoChars 字 + 文本里有"号" 才值得进算法体扫一遍
        guard text.contains(where: { kuoChars.contains($0) }), text.contains("号") else { return text }
        var chars = Array(text)
        var stack: [Character] = []  // 只用空/非空状态
        var changed = 0
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if isOpenerChar(ch) {
                stack.append(ch)
                i += 1
                continue
            }
            if isCloserChar(ch) {
                if !stack.isEmpty { stack.removeLast() }
                i += 1
                continue
            }
            if kuoChars.contains(ch) {
                // 向后跳 filler 找"号"
                var j = i + 1
                while j < chars.count && isFiller(chars[j]) { j += 1 }
                guard j < chars.count && chars[j] == "号" else {
                    i += 1
                    continue
                }
                // 向左跳 filler 找 prev1（可能是 modifier 或 left/right 前缀）
                var leftBound = i
                var kind = roundKind
                var commandIsLeft = false
                var commandIsRight = false
                var k = i - 1
                while k >= 0 && isFiller(chars[k]) { k -= 1 }
                if k >= 0 {
                    if let m = modifierMap[chars[k]] {
                        // 命中 modifier，先吞 modifier，再回看 left/right
                        kind = m
                        leftBound = k
                        var k2 = k - 1
                        while k2 >= 0 && isFiller(chars[k2]) { k2 -= 1 }
                        if k2 >= 0 {
                            if leftPrefixChars.contains(chars[k2]) {
                                commandIsLeft = true
                                leftBound = k2
                            } else if rightPrefixChars.contains(chars[k2]) {
                                commandIsRight = true
                                leftBound = k2
                            }
                        }
                    } else if leftPrefixChars.contains(chars[k]) {
                        commandIsLeft = true
                        leftBound = k
                    } else if rightPrefixChars.contains(chars[k]) {
                        commandIsRight = true
                        leftBound = k
                    }
                }
                let shouldOpen: Bool
                if commandIsLeft {
                    shouldOpen = true
                } else if commandIsRight {
                    shouldOpen = false
                } else {
                    shouldOpen = stack.isEmpty
                }
                let symbol = shouldOpen ? kind.opener : kind.closer
                chars.replaceSubrange(leftBound..<(j + 1), with: [symbol])
                if shouldOpen {
                    stack.append(symbol)
                } else if !stack.isEmpty {
                    stack.removeLast()
                }
                changed += 1
                i = leftBound + 1
                continue
            }
            i += 1
        }
        if changed > 0 {
            hits.append("智能括号×\(changed)")
        }
        return String(chars)
    }

    /// 命令字与"括号"两字间允许出现的"填充"字符（ASR token 边界产物）
    private static func isFiller(_ ch: Character) -> Bool {
        ch == " " || ch == "\t" || ch == "。" || ch == "，" || ch == "！" || ch == "？" || ch == "；" || ch == "："
    }

    /// Left bracket 命令前缀：包含"左"及其常见同音误识别（"左"拼音 zuǒ，相对没什么同音字）
    private static let leftPrefixChars: Set<Character> = ["左"]

    /// Right bracket 命令前缀：包含"右"及其常见同音误识别字
    /// Why: Apple SA 把"右"(yòu) 经常识别成 又/诱/幼/佑/釉，日志里能看见"括"才是真正想要的 alt
    private static let rightPrefixChars: Set<Character> = ["右", "又", "诱", "幼", "佑", "釉", "反"]

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
