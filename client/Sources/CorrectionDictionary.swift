import Foundation

/// 加载 ~/.we/correction-dictionary.{json,txt,md} （多文件合并）
///
/// **职责拆开**（避免一份大表跑所有事）：
/// - **terms** → 注入 SA `contextualStrings`（hint 越多识别越准，硬上限 `maxHintTerms` 默认 800）
/// - **correctionTerms** → 应用层 `correct()` 的 Levenshtein 兜底跑全表（硬上限 `maxCorrectionTerms` 默认 300，是 terms 的 prefix）
/// - **corrections**（错音 → 正字哈希）：含**手动 |** 登记 + **C5 自动派生**；synth 仅对 correctionTerms 派生（不对 hint-only 词派生噪音）
/// - **asciiCorrectionByLength**：correctionTerms 按长度分桶，Levenshtein 只扫 ±maxDist 范围
///
/// .json 格式：`{"正确词": {"errors": ["错音1","错音2"], ...}}`；`_` 前缀 key 视为 meta 跳过
/// .txt / .md 格式：一行一词 `Word` 或 `Word | 错音1 | 错音2`；`#` 注释；空行忽略
@MainActor
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    /// SA hint 用 — 全量（去重 + cap 后）
    private(set) var terms: [String] = []
    /// Levenshtein 兜底用 — terms 前 maxCorrectionTerms 个
    private(set) var correctionTerms: [String] = []
    /// 错音 → 正字
    private(set) var corrections: [String: String] = [:]
    /// 按错音长度倒序排好的 keys（长词优先替换）
    private(set) var sortedErrorKeys: [String] = []
    /// 按错音首字符分桶（Layer 1 single-pass 扫描时按当前位置首字符 O(1) 查 bucket，每桶内已按长度倒序）
    private(set) var errKeysByFirstChar: [Character: [String]] = [:]
    /// correctionTerms 中 ASCII 词按长度分桶（Levenshtein 用）
    private(set) var asciiCorrectionByLength: [Int: [String]] = [:]
    private(set) var loadedPath: String?

    /// 英文 stop words / 极短常用词 — synth 派生小写时若撞到这里则跳过，避免 AND→and 这类把 bandwidth 改成 bANDwidth 的事故
    /// 也用于 Levenshtein 白名单（系统词典 + 这里都视为"已经对的"）
    static let englishStopWords: Set<String> = [
        // 极常见冠词/连词/介词
        "a", "an", "the", "and", "or", "but", "if", "of", "in", "on", "at",
        "to", "from", "for", "with", "by", "as", "is", "are", "was", "were",
        "be", "been", "being", "do", "does", "did", "have", "has", "had",
        "will", "would", "could", "should", "may", "might", "can", "must",
        // 代词
        "i", "we", "you", "he", "she", "it", "they", "them", "us", "him", "her",
        "my", "our", "your", "his", "their", "its",
        // 否定/限定
        "no", "not", "yes", "so", "too", "very", "also",
        "all", "any", "some", "more", "most", "many", "much", "few",
        // 疑问
        "what", "when", "where", "why", "how",
        // 高频技术缩写小写形式（这些其实是合法术语，被 synth 派生出小写后会污染普通文本）
        "ai", "ar", "vr", "ml", "dl", "ux", "ui", "url", "api", "cpu", "gpu", "ram"
    ]

    /// 内置高频英文词白名单（~500 词），Levenshtein 兜底前查这个，命中即跳过。
    /// 替代 NSSpellChecker（首次冷启动 200ms 不可接受），常驻内存零延迟。
    /// 来源：Oxford 1000 + 常见技术 / 商务高频。覆盖 80% 普通英文文本。
    static let commonEnglishWords: Set<String> = [
        // a-c
        "able", "about", "above", "accept", "according", "account", "across", "act", "action", "active", "actually", "add", "address", "after", "again", "against", "age", "ago", "agree", "ahead", "air", "all", "allow", "almost", "alone", "along", "already", "also", "although", "always", "am", "among", "amount", "an", "and", "another", "answer", "any", "anyone", "anything", "appear", "apply", "are", "area", "arm", "around", "art", "as", "ask", "at", "attack", "attempt", "attention", "available", "away",
        "back", "bad", "ball", "bar", "base", "be", "beautiful", "because", "become", "bed", "been", "before", "begin", "behind", "being", "believe", "below", "best", "better", "between", "big", "bit", "black", "blood", "blue", "board", "body", "book", "born", "both", "bottom", "boy", "break", "bring", "brother", "build", "business", "but", "buy", "by",
        "call", "came", "camera", "can", "cannot", "car", "card", "care", "case", "catch", "cause", "cell", "center", "century", "certain", "chair", "chance", "change", "character", "charge", "check", "child", "choice", "choose", "city", "claim", "class", "clean", "clear", "close", "code", "color", "come", "common", "company", "compare", "complete", "compute", "computer", "concern", "condition", "consider", "consist", "contain", "continue", "control", "cool", "cost", "could", "country", "course", "cover", "create", "cup", "current", "cut",
        // d-f
        "data", "day", "dead", "deal", "dear", "decide", "deep", "describe", "design", "detail", "develop", "did", "die", "difference", "different", "difficult", "direct", "do", "doctor", "does", "dog", "done", "door", "double", "down", "draw", "dream", "drink", "drive", "drop", "during",
        "each", "early", "easy", "eat", "economic", "edge", "education", "effect", "eight", "either", "else", "end", "energy", "enjoy", "enough", "enter", "entire", "environment", "equal", "especially", "even", "evening", "event", "ever", "every", "everyone", "everything", "evidence", "exactly", "example", "except", "exist", "expect", "experience", "explain", "eye",
        "face", "fact", "fall", "family", "famous", "far", "fast", "father", "fear", "feel", "feet", "few", "field", "fight", "figure", "fill", "film", "final", "finally", "find", "fine", "finger", "finish", "fire", "first", "fish", "five", "fix", "flag", "floor", "flow", "fly", "follow", "food", "foot", "for", "force", "forget", "form", "former", "forward", "found", "four", "free", "fresh", "friend", "from", "front", "full", "fund", "future",
        // g-j
        "game", "gave", "general", "get", "girl", "give", "glass", "go", "goal", "god", "gold", "gone", "good", "got", "government", "great", "green", "ground", "group", "grow", "growth",
        "had", "hair", "half", "hand", "hang", "happen", "happy", "hard", "has", "have", "he", "head", "health", "hear", "heart", "heat", "heavy", "hello", "help", "her", "here", "herself", "high", "him", "himself", "his", "history", "hit", "hold", "hole", "home", "hope", "hospital", "hot", "hour", "house", "how", "however", "human", "hundred",
        "i", "idea", "if", "imagine", "important", "in", "include", "increase", "indeed", "industry", "inside", "instead", "into", "involve", "is", "issue", "it", "item", "its", "itself",
        "job", "join", "just",
        // k-m
        "keep", "kept", "key", "kid", "kill", "kind", "kitchen", "knew", "know", "known",
        "land", "language", "large", "last", "late", "later", "laugh", "law", "lay", "lead", "leader", "learn", "least", "leave", "led", "left", "leg", "less", "let", "letter", "level", "lie", "life", "light", "like", "likely", "line", "list", "listen", "little", "live", "load", "local", "long", "look", "loss", "lost", "lot", "love", "low",
        "machine", "made", "main", "major", "make", "man", "manage", "many", "mark", "market", "match", "matter", "may", "maybe", "me", "mean", "meaning", "measure", "meet", "meeting", "member", "memory", "men", "mention", "mess", "message", "method", "middle", "might", "mile", "military", "million", "mind", "minute", "miss", "mode", "modern", "moment", "money", "month", "more", "morning", "most", "mother", "mouth", "move", "movement", "movie", "mr", "mrs", "much", "music", "must", "my", "myself",
        // n-p
        "name", "nation", "national", "natural", "near", "necessary", "need", "never", "new", "news", "next", "nice", "night", "nine", "no", "none", "nor", "north", "not", "note", "nothing", "now", "number",
        "object", "of", "off", "offer", "office", "officer", "official", "often", "oh", "ok", "old", "on", "once", "one", "only", "open", "operate", "opportunity", "or", "order", "other", "others", "our", "ours", "ourselves", "out", "outside", "over", "own",
        "page", "paint", "paper", "parent", "part", "particular", "party", "pass", "past", "patient", "pay", "peace", "people", "per", "perhaps", "period", "person", "personal", "phone", "physical", "pick", "picture", "piece", "place", "plan", "plant", "plastic", "play", "player", "please", "point", "police", "policy", "political", "poor", "popular", "population", "position", "possible", "post", "power", "practice", "prepare", "present", "president", "press", "pretty", "prevent", "price", "private", "probably", "problem", "process", "produce", "product", "production", "professor", "program", "project", "property", "protect", "prove", "provide", "public", "pull", "purpose", "push", "put",
        // q-s
        "quality", "question", "quick", "quickly", "quiet", "quite",
        "race", "radio", "raise", "range", "rate", "rather", "reach", "read", "ready", "real", "really", "reason", "receive", "recent", "recently", "recognize", "record", "red", "reduce", "reference", "refer", "reflect", "region", "relate", "relationship", "remain", "remember", "remove", "report", "represent", "republican", "require", "resource", "respond", "response", "rest", "result", "return", "reveal", "rich", "right", "rise", "risk", "river", "road", "rock", "role", "room", "round", "row", "rule", "run",
        "safe", "said", "same", "save", "saw", "say", "scene", "school", "science", "score", "sea", "season", "seat", "second", "section", "security", "see", "seek", "seem", "sell", "send", "sense", "series", "serious", "serve", "service", "set", "seven", "several", "sex", "shake", "share", "she", "ship", "shoe", "shoot", "shop", "short", "shot", "should", "shoulder", "show", "side", "sign", "significant", "similar", "simple", "simply", "since", "sing", "single", "sister", "sit", "site", "situation", "six", "size", "skill", "skin", "small", "smile", "so", "social", "society", "some", "somebody", "someone", "something", "sometimes", "son", "song", "soon", "sort", "sound", "south", "space", "speak", "special", "specific", "speech", "spend", "sport", "spring", "staff", "stage", "stand", "standard", "star", "start", "state", "station", "stay", "step", "still", "stop", "store", "story", "strategy", "street", "strong", "structure", "student", "study", "stuff", "style", "subject", "success", "such", "sudden", "suddenly", "suffer", "suggest", "summer", "sun", "support", "sure", "surface", "system",
        // t-z
        "table", "take", "talk", "task", "tax", "teach", "teacher", "team", "technology", "telephone", "tell", "ten", "tend", "term", "test", "text", "than", "thank", "that", "the", "their", "them", "themselves", "then", "theory", "there", "these", "they", "thing", "think", "third", "this", "those", "though", "thought", "thousand", "threat", "three", "through", "throw", "thus", "time", "to", "today", "together", "told", "tonight", "too", "took", "top", "total", "toward", "town", "trade", "traditional", "training", "travel", "treat", "tree", "trial", "trip", "trouble", "true", "trust", "truth", "try", "turn", "two", "type",
        "under", "understand", "until", "up", "upon", "us", "use", "used", "user", "usually",
        "value", "various", "very", "victim", "view", "violence", "visit", "voice", "vote",
        "wait", "walk", "wall", "want", "war", "warm", "was", "wash", "watch", "water", "way", "we", "weapon", "wear", "week", "weight", "well", "went", "were", "west", "what", "whatever", "when", "where", "whether", "which", "while", "white", "who", "whole", "whom", "whose", "why", "wide", "wife", "will", "win", "wind", "window", "wish", "with", "within", "without", "woman", "women", "wonder", "word", "work", "worker", "world", "worry", "would", "write", "writer", "wrong",
        "yard", "yeah", "year", "yes", "yet", "you", "young", "your", "yourself"
    ]

    /// 配置上限（由 RuntimeConfig 读 polish.dict_max_terms / dict_max_correction_terms 注入；缺省走默认）
    static var maxHintTerms: Int = 800
    static var maxCorrectionTerms: Int = 300

    private init() {}

    /// 加载单个字典（向后兼容入口）
    @discardableResult
    func load(from path: String) -> Bool {
        return loadAll(from: [path])
    }

    /// 从 polish 配置一次性 resolve 出"应当加载的字典文件路径列表"。
    /// 所有 callers（WEApp/ContextEnhancer/DictionaryLearner）都走这个，避免 3 处重复构造。
    ///
    /// 优先级：
    /// 1. `context_dictionary_path` 用户主字典
    /// 2. `context_dictionary_paths` legacy 列表（向后兼容）
    /// 3. `dictionary_domains[name]` 中 `active_domains` 启用的圈子包
    /// 4. `~/.we/correction-dictionary-learned.txt` learned 字典（如果存在且未被前面包括）
    static func resolveEnabledPaths(polish: [String: Any]) -> [String] {
        var paths: [String] = []
        if let p = polish["context_dictionary_path"] as? String, !p.isEmpty {
            paths.append(p)
        }
        if let extras = polish["context_dictionary_paths"] as? [String] {
            paths.append(contentsOf: extras)
        }
        if let domains = polish["dictionary_domains"] as? [String: String],
           let active = polish["active_domains"] as? [String] {
            for name in active {
                if let dpath = domains[name], !dpath.isEmpty {
                    paths.append(dpath)
                }
            }
        }
        // learned 自动加上（除非用户已显式列）
        let learned = "~/.we/correction-dictionary-learned.txt"
        let learnedExpanded = (learned as NSString).expandingTildeInPath
        let alreadyHas = paths.contains { ($0 as NSString).expandingTildeInPath == learnedExpanded }
        if !alreadyHas, FileManager.default.fileExists(atPath: learnedExpanded) {
            paths.append(learned)
        }
        return paths
    }

    /// 加载多个字典（按顺序合并）
    /// - 先读完所有源 → 去重 → cap maxHintTerms → 取前 maxCorrectionTerms 做 correction 子集
    /// - manual `|` 错音映射全保留（不受 cap 影响）
    /// - C5 synth 仅对 correctionTerms 派生
    @discardableResult
    func loadAll(from paths: [String]) -> Bool {
        // 1) 读取 + 去重（保留首次出现顺序）
        var combinedTerms: [String] = []
        var manualCorrections: [String: String] = [:]
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
            for (err, correct) in p.corrections where manualCorrections[err] == nil {
                manualCorrections[err] = correct
                manualCount += 1
            }
            loadedPaths.append(expanded)
            Logger.log("Dict", "Loaded \(p.terms.count) terms + \(p.corrections.count) manual corrections from \(expanded)")
        }

        guard !combinedTerms.isEmpty else {
            reset()
            return false
        }

        // 2) Cap：terms = 前 maxHintTerms；correctionTerms = 前 maxCorrectionTerms
        let cappedTerms = combinedTerms.count > Self.maxHintTerms
            ? Array(combinedTerms.prefix(Self.maxHintTerms))
            : combinedTerms
        let cappedCorrection = Array(cappedTerms.prefix(Self.maxCorrectionTerms))

        // 3) corrections = manual + synth（synth 仅对 correctionTerms 范围）
        var allCorrections = manualCorrections
        var synthesized = 0
        for term in cappedCorrection {
            for variant in Self.synthesizeVariants(for: term) where allCorrections[variant] == nil {
                allCorrections[variant] = term
                synthesized += 1
            }
        }

        // 4) ASCII 长度桶（Levenshtein 用）
        let asciiCorr = cappedCorrection.filter {
            $0.count >= 2 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0 == " ") }
        }
        let bucketed = Dictionary(grouping: asciiCorr) { $0.count }

        // 5) 提交
        terms = cappedTerms
        correctionTerms = cappedCorrection
        corrections = allCorrections
        let sortedKeys = allCorrections.keys.sorted { $0.count > $1.count }
        sortedErrorKeys = sortedKeys
        asciiCorrectionByLength = bucketed

        // 首字符桶（Layer 1 single-pass 用）：每桶内已按 length 倒序（沿用 sortedKeys 顺序）
        var byFirst: [Character: [String]] = [:]
        for key in sortedKeys {
            if let first = key.first {
                byFirst[first, default: []].append(key)
            }
        }
        errKeysByFirstChar = byFirst

        loadedPath = loadedPaths.joined(separator: ", ")

        let dropped = combinedTerms.count - cappedTerms.count
        let dropMsg = dropped > 0 ? " [dropped \(dropped) over hint cap \(Self.maxHintTerms)]" : ""
        Logger.log("Dict", "Total: hint=\(cappedTerms.count) correction=\(cappedCorrection.count) errKeys=\(allCorrections.count) (manual=\(manualCount), synth=\(synthesized)) buckets=\(bucketed.count)\(dropMsg)")
        return true
    }

    // MARK: - C5 synthesizeVariants（限范围版）

    /// ASR 字符级常见混淆表
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
    ///
    /// **限范围**（A 优化）—— 不无脑全派生：
    /// - **全大写缩写 ≤6 字母**：派生最多（加空格 + 字母替换 + 小写）
    /// - **驼峰**：仅派生"拆词" 1 个（如 `SwiftUI → Swift UI`）
    /// - **其他**（普通小写、含数字、≥7 字母全大写）：不派生
    static func synthesizeVariants(for term: String) -> [String] {
        var variants = Set<String>()

        let isShortAcronym = term.count >= 2 && term.count <= 6
            && term.allSatisfy { $0.isLetter && $0.isUppercase }
        let isCamel = !term.contains(" ")
            && zip(term, term.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase })

        if isShortAcronym {
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
            // 1c. 全小写 ("SVG" → "svg")，但若小写形式是英文 stop word 则跳过（防 AND→and 这种污染）
            let lower = term.lowercased()
            if !englishStopWords.contains(lower) {
                variants.insert(lower)
            }
        } else if isCamel {
            // 2a. 仅拆词 ("SwiftUI" → "Swift UI")，不再派生小写、不字母替换
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
        }
        // else: 普通词不派生

        variants.remove(term)
        return Array(variants)
    }

    /// 应用反向纠错（两层）：
    /// 1. **精确替换** — single-pass left-to-right，遇到首字符匹配的桶按"长词优先"试匹配，
    ///    命中后跳过被替换段（**已替换部分不会再被后续 err 二次触发** — 修 cascading bug A）
    /// 2. **Levenshtein 兜底** — 长度桶定向 + NSSpellChecker 英文常用词白名单
    ///    （系统词典里的词如 "AI"、"compute" 不再被误纠成 API/computer）
    func correct(_ text: String) -> String {
        let tStart = CFAbsoluteTimeGetCurrent()
        var hits: [String] = []
        var result = text

        // Layer 1: single-pass left-to-right + 长词优先 + word boundary
        if !errKeysByFirstChar.isEmpty {
            let chars = Array(text)
            var newResult = ""
            newResult.reserveCapacity(text.count + 16)
            var i = 0
            while i < chars.count {
                var matched = false
                if let bucket = errKeysByFirstChar[chars[i]] {
                    // 左边界：上一个字符是 ASCII word char？是则跳过（说明 err 嵌入在更长 word 里，如 t<oken>ifficience）
                    let leftIsWord = i > 0 && Self.isAsciiWordChar(chars[i - 1])
                    for err in bucket {  // 已按 length 倒序（长词优先）
                        let errChars = Array(err)
                        if i + errChars.count <= chars.count {
                            var equal = true
                            for k in 0..<errChars.count where chars[i + k] != errChars[k] {
                                equal = false
                                break
                            }
                            if equal, let correct = corrections[err] {
                                // 右边界检查：err 后一个字符是 ASCII word char？是则跳过（防 ide→IDE 把 idea 改成 IDEa）
                                let nextIdx = i + errChars.count
                                let rightIsWord = nextIdx < chars.count && Self.isAsciiWordChar(chars[nextIdx])
                                // err 自身末字符若是 ASCII word char，左右都不能是 word char（否则误纠嵌入式）
                                let errEndIsWord = Self.isAsciiWordChar(errChars[errChars.count - 1])
                                let errStartIsWord = Self.isAsciiWordChar(errChars[0])
                                let leftBlocks = errStartIsWord && leftIsWord
                                let rightBlocks = errEndIsWord && rightIsWord
                                if leftBlocks || rightBlocks { continue }

                                newResult += correct
                                i += errChars.count
                                hits.append("=\(err)→\(correct)")
                                matched = true
                                break
                            }
                        }
                    }
                }
                if !matched {
                    newResult.append(chars[i])
                    i += 1
                }
            }
            result = newResult
        }

        // Layer 2: Levenshtein 兜底（仅 correctionTerms + 长度桶定向 + NSSpellChecker 白名单）
        if !asciiCorrectionByLength.isEmpty {
            let tokens = result.split(whereSeparator: { !$0.isASCII || $0.isWhitespace || $0.isPunctuation })
            var processed = Set<String>()
            for token in tokens {
                let tok = String(token)
                guard tok.count >= 2,
                      tok.allSatisfy({ $0.isASCII && $0.isLetter }),
                      !processed.contains(tok) else { continue }
                processed.insert(tok)

                // 白名单 1：本地 stopWords（小写比较）
                if Self.englishStopWords.contains(tok.lowercased()) { continue }
                // 白名单 2：已是 correctionTerms 的正字
                if asciiCorrectionByLength[tok.count]?.contains(tok) == true { continue }
                // 白名单 3：内置高频英文词集合（commonEnglishWords）— 不调 NSSpellChecker（首次 200ms 太慢）
                if Self.commonEnglishWords.contains(tok.lowercased()) { continue }

                let maxDist = max(1, tok.count / 4)
                var best: (term: String, dist: Int)?
                let lenLow = max(2, tok.count - maxDist)
                let lenHigh = tok.count + maxDist
                for len in lenLow...lenHigh {
                    guard let bucket = asciiCorrectionByLength[len] else { continue }
                    for term in bucket {
                        let d = Self.levenshtein(tok, term)
                        if d <= maxDist && d > 0 && (best == nil || d < best!.dist) {
                            best = (term, d)
                        }
                    }
                }
                if let b = best {
                    result = result.replacingOccurrences(of: tok, with: b.term)
                    hits.append("~\(tok)→\(b.term)(d=\(b.dist))")
                }
            }
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        if !hits.isEmpty {
            Logger.log("Dict", "correct \(String(format: "%.1fms", elapsedMs)) (\(text.count)c): \(hits.joined(separator: ", "))")
        } else if elapsedMs > 5 {
            Logger.log("Dict", "correct slow \(String(format: "%.1fms", elapsedMs)) (\(text.count)c, no hits)")
        }
        return result
    }

    /// ASCII word char = 字母 / 数字（中文不算，便于英文术语两侧紧贴汉字时仍能替换）
    private static func isAsciiWordChar(_ c: Character) -> Bool {
        return c.isASCII && (c.isLetter || c.isNumber)
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
        correctionTerms = []
        corrections = [:]
        sortedErrorKeys = []
        errKeysByFirstChar = [:]
        asciiCorrectionByLength = [:]
        loadedPath = nil
        // spell 缓存不清——它只跟系统英文词典相关，跟我们字典内容无关
    }
}
