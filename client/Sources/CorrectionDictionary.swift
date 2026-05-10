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
    /// terms 的 Set 形式，pinyin Layer 3 用来跳过"输入子串本身就是字典正字"的情况
    private(set) var termsSet: Set<String> = []
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
    /// **算法 A**：拼音 → 字典中文正字反向索引（液 shi → 流式）
    /// 第 1 个写入的 term 胜出（先来先得）；同音字若有多个 term 时认第一个。
    private(set) var chinesePinyinIndex: [String: String] = [:]
    /// **算法 B**：英文短语 token-wise Levenshtein 索引
    /// 按 token 数分桶（"event loop" 进 [2]，"Apple Developer ID" 进 [3]）
    /// 每个 phrase 是 (tokens: [String], canonical: String)
    private(set) var englishPhrasesByTokenCount: [Int: [(tokens: [String], canonical: String)]] = [:]
    /// **算法 B-extended**：单 token ASCII canonical 按长度分桶
    /// 用于 "trans former"(2 tokens) → join 成 "transformer" → 跟单 token canonical 算 Levenshtein
    /// 解决 SA 把 1 个英文词拆成多 token 的最大类（59 条 KEEP 中的 token-mismatch）
    private(set) var asciiSingleTokenByLength: [Int: [String]] = [:]
    /// **算法 C**：metaphone 音相似度 → 英文单 token canonical
    /// "depsec" / "depshake" 都 metaphone 成 "TPSK" → 全归 "DeepSeek"
    private(set) var metaphoneIndex: [String: String] = [:]

    /// **算法 D**：中式拼音 → 英文 canonical 反向索引（跨字符集）
    /// 用户说 "Option" 被 SA 听成 "又不慎"（pinyin "youbushen"）→ 查表归 Option
    /// V1 硬编码表（高频键名/UI 词）；未来扩通用启发式
    private static let englishToCnPinyinHints: [String: [String]] = [
        // 键盘按键
        "Option":  ["youbushen", "youbusheng", "youbushen", "yopushen", "youbusen"],
        "Command": ["kemande", "kanmaodi", "kanmoer"],
        "Cmd":     ["kanmd", "kanm"],
        "Shift":   ["shifute", "shifu", "shifuti", "xifute"],
        "Control": ["kongtuoluo", "kangte", "kongte"],
        "Ctrl":    ["kongtuoluo", "kongte"],
        "Delete":  ["dileite", "dilete", "dilieite"],
        "Escape":  ["yisikaipu", "yisikai"],
        "Enter":   ["entela", "yintela", "enteer"],
        "Tab":     ["tabo", "taipo", "tabu"],
        "Caps":    ["kabusi", "kapus"],
        "Space":   ["sipaisi", "sipei"],
        // 通用 UI/系统词
        "Window":  ["wendou", "wenduo"],
        "Browser": ["bulaowusa"],
        "Cursor":  ["kerso", "kuerso"],
        "Folder":  ["fude", "fuluode"],
        "Finder":  ["fende", "fainde"]
    ]

    /// 启动时构建：拼音 (中式) → 英文 canonical
    private(set) var cnPinyinToEnglish: [String: String] = [:]

    private(set) var loadedPath: String?

    // MARK: - 纠错记录 + Gate（#3 + #1 V0）

    /// 每条替换的可解释记录
    /// 灵感：Anthropic 内省机制论文的 Evidence Carrier + Gate 模式
    struct CorrectionRecord {
        let layer: String          // "L1-exact-manual" / "L1-exact-synth" / "L2-lev" / "L3-pinyin" / "L4-phrase" / "L5-meta"
        let original: String
        let replacement: String
        let confidence: Double     // 0..1
        let reason: String         // 人类可读
        let accepted: Bool         // Gate 决策结果
    }

    /// 上次 correct() 产生的所有替换记录（含被 Gate 拒绝的）
    /// VoicePipeline 用它写 VoiceHistory 做审计；未来 Gate 调参也基于这个
    private(set) var lastCorrections: [CorrectionRecord] = []

    /// Gate V1：默认阈值 0.5（过滤 L2/L4 floor 边界 + L5 弱 metaphone 边界）
    /// 阈值由 polish.gate_threshold 配；现有 L1=0.95 全留 / L3 ≥0.7 全留 / 只砍最弱的
    /// 调阈值前用 `MK --eval-gate "raw"` 预览影响
    var gateThresholdOverride: Double? = nil  // eval 工具用
    private var gateThreshold: Double {
        if let o = gateThresholdOverride { return o }
        return (RuntimeConfig.shared.polishConfig["gate_threshold"] as? Double) ?? 0.5
    }

    /// Gate 决策：true = 应用替换，false = 拒绝
    /// V0 简单按阈值过滤；V1 可加多源加权（拼写距离 × 长度 × 历史采纳率 × 应用上下文）
    private func gateAccept(_ confidence: Double) -> Bool {
        return confidence >= gateThreshold
    }

    /// mtime 缓存：上次 loadAll 时各文件的 (path → mtime)
    /// 同样 paths 列表 + 各文件 mtime 都不变 → skip reload（每次录音省 ~10ms）
    private var lastLoadedMtimes: [String: TimeInterval] = [:]

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
    /// 4. **iCloud Drive learned 字典（多 Mac 同步）** —— 如果存在
    /// 5. `~/.we/correction-dictionary-learned.txt` learned 字典（fallback）
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

        // learned 自动加上 — 优先 iCloud，fallback 本地
        let icloudLearned = iCloudLearnedPath()
        let localLearned = "~/.we/correction-dictionary-learned.txt"

        // 加 iCloud（如果存在 + 没被 caller 显式列了）
        if let icloud = icloudLearned {
            let alreadyHas = paths.contains { ($0 as NSString).expandingTildeInPath == icloud }
            if !alreadyHas, FileManager.default.fileExists(atPath: icloud) {
                paths.append(icloud)
            }
        }

        // 加本地（同样防重复）
        let localExpanded = (localLearned as NSString).expandingTildeInPath
        let alreadyHasLocal = paths.contains { ($0 as NSString).expandingTildeInPath == localExpanded }
        if !alreadyHasLocal, FileManager.default.fileExists(atPath: localExpanded) {
            paths.append(localLearned)
        }

        return paths
    }

    /// iCloud Drive 的 learned 字典路径（如果用户开了 iCloud Drive）
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/MK/correction-dictionary-learned.txt`
    /// 返回 nil 表示 iCloud Drive 不可用
    static func iCloudLearnedPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloudRoot = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        guard FileManager.default.fileExists(atPath: cloudRoot) else { return nil }
        let mkDir = "\(cloudRoot)/MK"
        // 自动 mkdir MK 目录
        if !FileManager.default.fileExists(atPath: mkDir) {
            try? FileManager.default.createDirectory(atPath: mkDir, withIntermediateDirectories: true)
        }
        return "\(mkDir)/correction-dictionary-learned.txt"
    }

    /// 加载多个字典（按顺序合并）
    /// - 先读完所有源 → 去重 → cap maxHintTerms → 取前 maxCorrectionTerms 做 correction 子集
    /// - manual `|` 错音映射全保留（不受 cap 影响）
    /// - C5 synth 仅对 correctionTerms 派生
    /// - mtime 缓存：同样文件 + 同样 mtime → skip（每次录音前调省 ~10ms）
    @discardableResult
    func loadAll(from paths: [String]) -> Bool {
        // mtime 检查：所有文件都没变 + paths 列表也一致 → skip
        var currentMtimes: [String: TimeInterval] = [:]
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
               let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
                currentMtimes[expanded] = mt
            }
        }
        if !lastLoadedMtimes.isEmpty,
           currentMtimes.keys.sorted() == lastLoadedMtimes.keys.sorted(),
           currentMtimes.allSatisfy({ lastLoadedMtimes[$0.key] == $0.value }) {
            // 全 hit cache，跳
            return true
        }

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
        termsSet = Set(cappedTerms)
        correctionTerms = cappedCorrection
        corrections = allCorrections
        let sortedKeys = allCorrections.keys.sorted { $0.count > $1.count }
        sortedErrorKeys = sortedKeys
        asciiCorrectionByLength = bucketed
        // 算法 A：建拼音 → 字典中文正字反向索引
        var pinyinIdx: [String: String] = [:]
        var pinyinDup = 0
        for term in cappedTerms {
            guard let key = Self.pinyinKey(term) else { continue }
            if pinyinIdx[key] == nil {
                pinyinIdx[key] = term
            } else {
                pinyinDup += 1
            }
        }
        chinesePinyinIndex = pinyinIdx

        // 算法 B：建英文短语 token-wise Levenshtein 索引（按 token 数分桶）
        // 仅 ASCII letters / 点 / 横线 的多 token term 入索引
        var phrasesIdx: [Int: [(tokens: [String], canonical: String)]] = [:]
        var phraseTermCount = 0
        for term in cappedTerms {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard parts.count >= 2, parts.count <= 4 else { continue }
            // 全部 ASCII（字母/数字/. -）才入；中文/混合短语跳过
            let allAsciiPhraseChars = parts.allSatisfy { tok in
                tok.allSatisfy { c in
                    c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-")
                }
            }
            guard allAsciiPhraseChars else { continue }
            phrasesIdx[parts.count, default: []].append((tokens: parts, canonical: trimmed))
            phraseTermCount += 1
        }
        englishPhrasesByTokenCount = phrasesIdx

        // 算法 B-extended：单 token ASCII canonical 按长度分桶
        // 仅纯 ASCII letter / 数字 / 点 / 横线，长度 ≥ 4
        var singleTokenIdx: [Int: [String]] = [:]
        for term in cappedTerms {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            // 必须单 token
            guard !trimmed.isEmpty, !trimmed.contains(" ") else { continue }
            // ASCII only + 长度 ≥4
            guard trimmed.count >= 4,
                  trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
                  else { continue }
            // 跳过常见英文（防 over-correction）
            let lower = trimmed.lowercased()
            if Self.englishStopWords.contains(lower) || Self.commonEnglishWords.contains(lower) { continue }
            singleTokenIdx[trimmed.count, default: []].append(trimmed)
        }
        asciiSingleTokenByLength = singleTokenIdx

        // 算法 C：建 metaphone → 英文单 token canonical 索引
        // 仅纯 ASCII letters，长度 ≥ 4（短词噪音多）
        var metaIdx: [String: String] = [:]
        var metaDup = 0
        for term in cappedTerms {
            let t = term.trimmingCharacters(in: .whitespaces)
            // 单 token only（多 token 走算法 B），全 ASCII letters，长度 ≥ 4
            guard !t.isEmpty,
                  !t.contains(" "),
                  t.count >= 4,
                  t.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            // 跳过 stop word / 常见英文词避免污染
            let lower = t.lowercased()
            if Self.englishStopWords.contains(lower) || Self.commonEnglishWords.contains(lower) { continue }
            let key = Self.metaphone(t)
            if key.isEmpty { continue }
            if metaIdx[key] == nil {
                metaIdx[key] = t
            } else {
                metaDup += 1
            }
        }
        metaphoneIndex = metaIdx

        // 首字符桶（Layer 1 single-pass 用）：每桶内已按 length 倒序（沿用 sortedKeys 顺序）
        var byFirst: [Character: [String]] = [:]
        for key in sortedKeys {
            if let first = key.first {
                byFirst[first, default: []].append(key)
            }
        }
        errKeysByFirstChar = byFirst

        loadedPath = loadedPaths.joined(separator: ", ")
        lastLoadedMtimes = currentMtimes

        let dropped = combinedTerms.count - cappedTerms.count
        let dropMsg = dropped > 0 ? " [dropped \(dropped) over hint cap \(Self.maxHintTerms)]" : ""
        // 算法 D：建中式拼音 → 英文 canonical 反向索引
        var cnEnIdx: [String: String] = [:]
        let cappedSet = Set(cappedTerms)
        for (eng, cnPinyins) in Self.englishToCnPinyinHints {
            guard cappedSet.contains(eng) else { continue }
            for py in cnPinyins {
                if cnEnIdx[py] == nil { cnEnIdx[py] = eng }
            }
        }
        cnPinyinToEnglish = cnEnIdx

        let singleTokenTotal = singleTokenIdx.values.reduce(0) { $0 + $1.count }
        Logger.log("Dict", "Total: hint=\(cappedTerms.count) correction=\(cappedCorrection.count) errKeys=\(allCorrections.count) (manual=\(manualCount), synth=\(synthesized)) buckets=\(bucketed.count) pinyin=\(pinyinIdx.count)(\(pinyinDup) dup) phrases=\(phraseTermCount) meta=\(metaIdx.count)(\(metaDup) dup) singleTok=\(singleTokenTotal) cn2en=\(cnEnIdx.count)\(dropMsg)")
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
        lastCorrections.removeAll()  // 重置上次记录

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

                                // L1 exact: confidence = 0.95（最高，因为是字典精确匹配）
                                let conf = 0.95
                                let accept = gateAccept(conf)
                                let record = CorrectionRecord(
                                    layer: "L1-exact", original: err, replacement: correct,
                                    confidence: conf,
                                    reason: "exact dict match",
                                    accepted: accept
                                )
                                lastCorrections.append(record)
                                if !accept {
                                    Logger.log("Dict", "[Gate-reject] L1: \(err)→\(correct) conf=\(conf) < threshold")
                                    continue
                                }

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
                    // L2 Lev: confidence = 1 - dist/len，floor 0.5
                    let conf = max(0.5, 1.0 - Double(b.dist) / Double(tok.count))
                    let accept = gateAccept(conf)
                    let record = CorrectionRecord(
                        layer: "L2-lev", original: tok, replacement: b.term,
                        confidence: conf,
                        reason: "Levenshtein dist=\(b.dist) on len=\(tok.count)",
                        accepted: accept
                    )
                    lastCorrections.append(record)
                    if accept {
                        result = result.replacingOccurrences(of: tok, with: b.term)
                        hits.append("~\(tok)→\(b.term)(d=\(b.dist),c=\(String(format: "%.2f", conf)))")
                    } else {
                        Logger.log("Dict", "[Gate-reject] L2: \(tok)→\(b.term) conf=\(String(format: "%.2f", conf))")
                    }
                }
            }
        }

        // Layer 4 (算法 B): 英文短语 token-wise Levenshtein
        // 扫输入里连续 ASCII token 序列（2-4 token 滑窗），跟字典短语桶对齐
        // 每对 token Levenshtein ≤1 + 总和 ≤ 桶 token 数 → 整体替换
        if !englishPhrasesByTokenCount.isEmpty {
            result = applyEnglishPhraseFuzzy(result, hits: &hits)
        }

        // Layer 5 (算法 C): metaphone 英文音相似度
        // 单 ASCII token Levenshtein 抓不到时（拼写差距大但发音近）兜底
        if !metaphoneIndex.isEmpty {
            result = applyMetaphoneFuzzy(result, hits: &hits)
        }

        // Layer 6 (算法 D): 中式拼音 → 英文 canonical 反查
        // 跨字符集纠错：SA 把 "Option" 听成 "又不慎"（pinyin youbushen）→ 反查 Option
        if !cnPinyinToEnglish.isEmpty {
            result = applyCnPinyinToEnglish(result, hits: &hits)
        }

        // Layer 3: 拼音哈希模糊匹配（中文同音字）
        // 输入文本中扫描 2-4 字 CJK 子串 → 算拼音 → 反向索引找正字 → 替换
        // 跳过：子串本身就是字典正字 / 拼音不在索引 / 正字 == 子串
        if !chinesePinyinIndex.isEmpty {
            let chars = Array(result)
            var newOut = ""
            newOut.reserveCapacity(result.count)
            var i = 0
            while i < chars.count {
                var matched = false
                if let scalar = chars[i].unicodeScalars.first, Self.isCJKScalar(scalar) {
                    // 试 4 → 3 → 2 字（长优先）
                    let maxLen = min(4, chars.count - i)
                    for L in stride(from: maxLen, through: 2, by: -1) {
                        let substr = String(chars[i..<i + L])
                        // 必须全是 CJK 字（不夹 ASCII）
                        let allCJK = substr.unicodeScalars.allSatisfy(Self.isCJKScalar)
                        guard allCJK else { continue }
                        // 跳过：子串本身就是字典里的正字
                        if termsSet.contains(substr) { continue }
                        // 查拼音索引
                        guard let key = Self.pinyinKey(substr),
                              let canonical = chinesePinyinIndex[key],
                              canonical != substr else { continue }
                        // L3 pinyin confidence：长度越长越可信（2字 0.65 / 3字 0.78 / 4字 0.88）
                        let conf = 0.5 + Double(L) * 0.1
                        let accept = gateAccept(conf)
                        let record = CorrectionRecord(
                            layer: "L3-pinyin", original: substr, replacement: canonical,
                            confidence: conf,
                            reason: "pinyin=\(key) match, len=\(L)",
                            accepted: accept
                        )
                        lastCorrections.append(record)
                        if !accept {
                            Logger.log("Dict", "[Gate-reject] L3: \(substr)→\(canonical) conf=\(String(format: "%.2f", conf))")
                            continue
                        }
                        // 命中：替换
                        newOut += canonical
                        i += L
                        hits.append("≈\(substr)→\(canonical)(c=\(String(format: "%.2f", conf)))")
                        matched = true
                        break
                    }
                }
                if !matched {
                    newOut.append(chars[i])
                    i += 1
                }
            }
            result = newOut
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        let acceptedCount = lastCorrections.filter { $0.accepted }.count
        let rejectedCount = lastCorrections.count - acceptedCount
        let gateNote = rejectedCount > 0 ? " [gate rejected \(rejectedCount)]" : ""
        if !hits.isEmpty {
            Logger.log("Dict", "correct \(String(format: "%.1fms", elapsedMs)) (\(text.count)c)\(gateNote): \(hits.joined(separator: ", "))")
        } else if elapsedMs > 5 {
            Logger.log("Dict", "correct slow \(String(format: "%.1fms", elapsedMs)) (\(text.count)c, no hits)\(gateNote)")
        }
        return result
    }

    // MARK: - 短语 fuzzy（算法 B）

    /// 在 text 中找连续 ASCII token 序列，按 2-4 token 滑窗匹配字典短语
    /// 每对 token Levenshtein ≤1 + 总和 ≤ 桶 token 数 / 2 + 1 → 替换
    private func applyEnglishPhraseFuzzy(_ text: String, hits: inout [String]) -> String {
        // 1) 用空白分 token，记录每个 token 在原文的 range
        let chars = Array(text)
        struct Tok { let str: String; let start: Int; let end: Int }
        var toks: [Tok] = []
        var i = 0
        while i < chars.count {
            // skip 非 token 字符
            if !chars[i].isASCII || (!chars[i].isLetter && !chars[i].isNumber && chars[i] != "." && chars[i] != "-") {
                i += 1
                continue
            }
            let start = i
            while i < chars.count, chars[i].isASCII, (chars[i].isLetter || chars[i].isNumber || chars[i] == "." || chars[i] == "-") {
                i += 1
            }
            let s = String(chars[start..<i])
            toks.append(Tok(str: s, start: start, end: i))
        }
        guard !toks.isEmpty else { return text }

        // 2) 按 token 数（2..4）尝试匹配；两条路径并行选最优：
        //    a) phrase: bucket[L] 跟 window token-wise 对齐（如 "Even Lop" → "event loop"）
        //    b) joined: window join 成无空格单 token 跟 1-token canonical 算 Lev
        //       （SA 把 1 词拆成 N token 的最大类，"trans former" → "transformer"）
        struct Hit { let start: Int; let end: Int; let replacement: String; let summary: String }
        var winHits: [Hit] = []
        var idx = 0
        while idx < toks.count {
            var matchedAny = false
            // L=2 先（"trans former" → "transformer" d=0 完美匹配应优先于 L=3 模糊匹配）
            for L in [2, 3, 4] where idx + L <= toks.count {
                let window = Array(toks[idx..<idx + L])
                let windowJoined = window.map { $0.str }.joined(separator: " ")
                let windowJoinedNoSpace = window.map { $0.str }.joined()

                // 路径 a：N-token bucket
                var bestA: (canonical: String, dist: Int)?
                if let bucket = englishPhrasesByTokenCount[L],
                   !bucket.contains(where: { $0.canonical == windowJoined }) {
                    let perTokenMaxDist = 1
                    let totalMaxDist = L
                    for ph in bucket {
                        var total = 0
                        var skip = false
                        for k in 0..<L {
                            let d = Self.levenshtein(window[k].str.lowercased(), ph.tokens[k].lowercased())
                            if d > perTokenMaxDist { skip = true; break }
                            total += d
                        }
                        if skip || total > totalMaxDist || total == 0 { continue }
                        if bestA == nil || total < bestA!.dist {
                            bestA = (ph.canonical, total)
                        }
                    }
                }

                // 路径 b：joined-1-token vs ASCII single-token canonicals
                var bestB: (canonical: String, dist: Int)?
                let joinedLen = windowJoinedNoSpace.count
                let joinedLow = windowJoinedNoSpace.lowercased()
                if joinedLen >= 4 {
                    // 阈值跟 L2 看齐：max(1, len/4)，比例式不绝对值；防短词 false positive
                    let maxBDist = max(1, joinedLen / 4)
                    for len in max(2, joinedLen - maxBDist)...(joinedLen + maxBDist) {
                        guard let bucket = asciiSingleTokenByLength[len] else { continue }
                        for canonical in bucket {
                            // 跳过：input 已经是 canonical（with space），无需重写
                            if canonical == windowJoined { continue }
                            // 不跳过 canonical == joinedNoSpace —— 那才是我们要修的（"trans former" → "transformer"）
                            let d = Self.levenshtein(joinedLow, canonical.lowercased())
                            if d > maxBDist { continue }
                            // 但 d=0 且 canonical 已经是 joinedNoSpace 意味着只是丢空格 — 这是我们要修的，保留
                            if bestB == nil || d < bestB!.dist {
                                bestB = (canonical, d)
                            }
                        }
                    }
                }

                // 选最优（dist 更小的；同分时 phrase 优先因为更结构化）
                let chosen: (canonical: String, dist: Int, kind: String)?
                if let a = bestA, let b = bestB {
                    chosen = (a.dist <= b.dist) ? (a.canonical, a.dist, "phrase") : (b.canonical, b.dist, "joined")
                } else if let a = bestA {
                    chosen = (a.canonical, a.dist, "phrase")
                } else if let b = bestB {
                    chosen = (b.canonical, b.dist, "joined")
                } else {
                    chosen = nil
                }

                if let c = chosen {
                    let baseLen: Int = (c.kind == "joined") ? joinedLen : window.reduce(0) { $0 + $1.str.count }
                    let conf = max(0.5, 1.0 - Double(c.dist) / Double(max(1, baseLen)))
                    let accept = gateAccept(conf)
                    let record = CorrectionRecord(
                        layer: "L4-\(c.kind)", original: windowJoined, replacement: c.canonical,
                        confidence: conf,
                        reason: "L4 \(c.kind) Lev d=\(c.dist) on \(L) tokens",
                        accepted: accept
                    )
                    lastCorrections.append(record)
                    if !accept {
                        Logger.log("Dict", "[Gate-reject] L4-\(c.kind): \(windowJoined)→\(c.canonical) conf=\(String(format: "%.2f", conf))")
                        idx += 1
                        matchedAny = true
                        break
                    }
                    let startIdx = window.first!.start
                    let endIdx = window.last!.end
                    winHits.append(Hit(start: startIdx, end: endIdx, replacement: c.canonical, summary: "≈[\(c.kind)]\(windowJoined)→\(c.canonical)(d=\(c.dist),c=\(String(format: "%.2f", conf)))"))
                    idx += L
                    matchedAny = true
                    break
                }
            }
            if !matchedAny { idx += 1 }
        }
        guard !winHits.isEmpty else { return text }

        // 3) 按 start 顺序拼回 result
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = 0
        for h in winHits.sorted(by: { $0.start < $1.start }) {
            if h.start > cursor {
                out += String(chars[cursor..<h.start])
            }
            out += h.replacement
            cursor = h.end
            hits.append(h.summary)
        }
        if cursor < chars.count {
            out += String(chars[cursor..<chars.count])
        }
        return out
    }

    // MARK: - Metaphone（算法 C）

    /// 在 text 中找单 ASCII token，算 metaphone，查反向索引找 canonical 替换
    /// 跳过：token 长度 < 4 / 已经是 dict canonical / metaphone key 不在索引
    private func applyMetaphoneFuzzy(_ text: String, hits: inout [String]) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            // 找连续 ASCII letter token
            if !chars[i].isASCII || !chars[i].isLetter {
                out.append(chars[i])
                i += 1
                continue
            }
            let start = i
            while i < chars.count, chars[i].isASCII, chars[i].isLetter {
                i += 1
            }
            let tok = String(chars[start..<i])
            // 长度 ≥ 4 才查
            guard tok.count >= 4 else {
                out += tok
                continue
            }
            // 已经是 dict canonical / 常见英文 → 不动
            if termsSet.contains(tok)
               || Self.englishStopWords.contains(tok.lowercased())
               || Self.commonEnglishWords.contains(tok.lowercased()) {
                out += tok
                continue
            }
            let key = Self.metaphone(tok)
            if !key.isEmpty, let canonical = metaphoneIndex[key], canonical != tok {
                // L5 metaphone confidence：基础 0.6 + 长 token 加成
                let conf = 0.6 + (tok.count >= 6 ? 0.1 : 0.0) + (canonical.count >= 6 ? 0.1 : 0.0)
                let accept = gateAccept(conf)
                let record = CorrectionRecord(
                    layer: "L5-meta", original: tok, replacement: canonical,
                    confidence: conf,
                    reason: "metaphone=\(key) match",
                    accepted: accept
                )
                lastCorrections.append(record)
                if accept {
                    out += canonical
                    hits.append("♪\(tok)→\(canonical)(meta=\(key),c=\(String(format: "%.2f", conf)))")
                } else {
                    Logger.log("Dict", "[Gate-reject] L5: \(tok)→\(canonical) conf=\(String(format: "%.2f", conf))")
                    out += tok
                }
            } else {
                out += tok
            }
        }
        return out
    }

    /// Metaphone 算法（Lawrence Philips, 1990）— 把英文单词转成"音相似"的 key
    /// 实现：经典规则集，~50 行；同音/近音词产生相同/相似 key（DeepSeek/depsec → "TPSK"）
    static func metaphone(_ str: String) -> String {
        // 1) 大写化 + 只留 ASCII letters
        var s = ""
        for ch in str.uppercased() {
            if ch.isASCII && ch.isLetter { s.append(ch) }
        }
        guard !s.isEmpty else { return "" }
        let chars = Array(s)
        var i = 0
        var result = ""

        // 处理首字符特殊情况
        if chars.count >= 2 {
            let first2 = String(chars[0...1])
            if ["AE", "GN", "KN", "PN", "WR"].contains(first2) {
                i = 1  // 跳过首字符（silent）
            } else if first2 == "WH" {
                i = 1
            } else if chars[0] == "X" {
                result.append("S")
                i = 1
            }
        }

        while i < chars.count {
            let ch = chars[i]
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let next2: Character? = i + 2 < chars.count ? chars[i + 2] : nil

            // 跳过相邻重复字母（C 除外）
            if let p = prev, p == ch, ch != "C" {
                i += 1
                continue
            }

            switch ch {
            case "A", "E", "I", "O", "U":
                if i == 0 { result.append(ch) }
            case "B":
                if !(i == chars.count - 1 && prev == "M") {
                    result.append("B")
                }
            case "C":
                if next == "I" && next2 == "A" {
                    result.append("X")
                } else if next == "H" {
                    result.append(prev == "S" ? "K" : "X")
                    i += 1  // 跳过 H
                } else if let n = next, "EIY".contains(n) {
                    result.append("S")
                } else {
                    result.append("K")
                }
            case "D":
                if next == "G", let n2 = next2, "EIY".contains(n2) {
                    result.append("J")
                    i += 1  // 跳过 G
                } else {
                    result.append("T")
                }
            case "F", "J", "L", "M", "N", "R":
                result.append(ch)
            case "G":
                if next == "H" {
                    if i + 2 >= chars.count || (next2.map { !"AEIOU".contains($0) } ?? true) {
                        // GH 静音
                    } else {
                        result.append("F")
                    }
                    i += 1
                } else if next == "N" && i + 2 >= chars.count {
                    result.append("K")
                } else if let n = next, "EIY".contains(n) {
                    result.append("J")
                } else {
                    result.append("K")
                }
            case "H":
                if let p = prev, "AEIOU".contains(p), let n = next, !"AEIOU".contains(n) {
                    // 跳过
                } else {
                    result.append("H")
                }
            case "K":
                if prev != "C" { result.append("K") }
            case "P":
                if next == "H" {
                    result.append("F")
                    i += 1
                } else {
                    result.append("P")
                }
            case "Q":
                result.append("K")
            case "S":
                if next == "H" {
                    result.append("X")
                    i += 1
                } else if next == "I", let n2 = next2, "AO".contains(n2) {
                    result.append("X")
                } else {
                    result.append("S")
                }
            case "T":
                if next == "H" {
                    result.append("0")
                    i += 1
                } else if next == "I", let n2 = next2, "AO".contains(n2) {
                    result.append("X")
                } else {
                    result.append("T")
                }
            case "V":
                result.append("F")
            case "W", "Y":
                if let n = next, "AEIOU".contains(n) { result.append(ch) }
            case "X":
                result.append("KS")
            case "Z":
                result.append("S")
            default:
                break
            }
            i += 1
        }
        return result
    }

    // MARK: - 算法 D：中式拼音 → 英文 canonical 反查

    /// 扫输入中文 substring（2-4 字）算拼音 → 反向索引找英文 canonical
    /// 跳过：input 子串非全 CJK / 拼音不在反向索引 / canonical 已经在 input 上下文
    private func applyCnPinyinToEnglish(_ text: String, hits: inout [String]) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            var matched = false
            if let scalar = chars[i].unicodeScalars.first, Self.isCJKScalar(scalar) {
                // 长优先：4 → 3 → 2
                let maxLen = min(4, chars.count - i)
                for L in stride(from: maxLen, through: 2, by: -1) {
                    let substr = String(chars[i..<i + L])
                    let allCJK = substr.unicodeScalars.allSatisfy(Self.isCJKScalar)
                    guard allCJK else { continue }
                    guard let pinyin = Self.pinyinKey(substr),
                          let englishCanonical = cnPinyinToEnglish[pinyin] else { continue }

                    // 算法 D confidence：长子串更可信（2 字 0.65 / 3 字 0.78 / 4 字 0.88）
                    let conf = 0.5 + Double(L) * 0.1 - 0.05  // 比 L3 同音字稍低（跨字符集更易歧义）
                    let accept = gateAccept(conf)
                    let record = CorrectionRecord(
                        layer: "L6-cn2en", original: substr, replacement: englishCanonical,
                        confidence: conf,
                        reason: "cn-pinyin=\(pinyin) → en=\(englishCanonical)",
                        accepted: accept
                    )
                    lastCorrections.append(record)
                    if !accept {
                        Logger.log("Dict", "[Gate-reject] L6: \(substr)→\(englishCanonical) conf=\(String(format: "%.2f", conf))")
                        continue
                    }
                    out += englishCanonical
                    i += L
                    hits.append("⇄\(substr)→\(englishCanonical)(c=\(String(format: "%.2f", conf)))")
                    matched = true
                    break
                }
            }
            if !matched {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - 拼音工具（算法 A）

    /// 中文字串 → 不带声调的拼音（"流式" → "liushi"）；非中文返回 nil
    static func pinyinKey(_ str: String) -> String? {
        guard !str.isEmpty else { return nil }
        // 必须含至少一个 CJK 字
        guard str.unicodeScalars.contains(where: isCJKScalar) else { return nil }
        let mutable = NSMutableString(string: str)
        let mutableCF: CFMutableString = mutable
        let r1 = CFStringTransform(mutableCF, nil, kCFStringTransformMandarinLatin, false)
        let r2 = CFStringTransform(mutableCF, nil, kCFStringTransformStripDiacritics, false)
        guard r1 && r2 else { return nil }
        let py = (mutable as String)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isLetter }  // 防 punctuation 串入
        return py.isEmpty ? nil : py
    }

    /// CJK Unified Ideographs 主区段（含扩展）
    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        // 主 CJK + 扩展 A
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
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
        termsSet = []
        correctionTerms = []
        corrections = [:]
        sortedErrorKeys = []
        errKeysByFirstChar = [:]
        asciiCorrectionByLength = [:]
        chinesePinyinIndex = [:]
        englishPhrasesByTokenCount = [:]
        asciiSingleTokenByLength = [:]
        metaphoneIndex = [:]
        cnPinyinToEnglish = [:]
        loadedPath = nil
    }
}
