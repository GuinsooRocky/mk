import AppKit
import Foundation

/// 语料回归评测 CLI（dict 纠错层 + golden baseline 快照）
///
/// 用法：
///   `MK --eval-corpus`              首跑建基线；之后对比基线，列出变化
///   `MK --eval-corpus --rebaseline` 强制用当前输出覆盖基线
///   `MK --eval-corpus 200`          最多显示 200 条变化（默认 40）
///
/// 只 replay **dict 纠错层** `CorrectionDictionary.correct()`（不含 punct/filler/number——
/// 那几个 normalizer 逻辑会独立演进，混进来全是噪声）。把每条历史 `rawSA` 的纠错输出
/// 跟 `~/.mk/eval-corpus-baseline.json` 里的快照比：
///
/// - **首跑**：无基线 → 写基线、报「established N」。
/// - **后续**：改完纠错逻辑再跑 → 只列出「相对基线变了」的句子（raw / base / now），
///   逐条 review 是改好还是改坏。这样每一步演进的影响都被干净隔离。
///
/// 零新依赖：复用 correct() + JSONLWriter 的数据。
@MainActor
enum CorpusEval {
    private struct Pair: Codable { let raw: String; let out: String }

    static func run() async {
        WEDataDir.ensureExists()
        let args = CommandLine.arguments
        let rebaseline = args.contains("--rebaseline")
        // 扫所有 arg 找首个整数当 maxShow（位置无关，兼容 `--eval-corpus --rebaseline 50`）；钳到 ≥1
        let maxShow = max(1, args.compactMap { Int($0) }.first ?? 40)

        // 1) 加载字典
        let polish = RuntimeConfig.shared.polishConfig
        if let cap = polish["dict_max_terms"] as? Int, cap > 0 { CorrectionDictionary.maxHintTerms = cap }
        if let cap = polish["dict_max_correction_terms"] as? Int, cap > 0 { CorrectionDictionary.maxCorrectionTerms = cap }
        let paths = CorrectionDictionary.resolveEnabledPaths(polish: polish)
        guard !paths.isEmpty else { print("Error: no dict paths configured"); return }
        CorrectionDictionary.shared.loadAll(from: paths)

        // 2) 读 voice-history.jsonl，抽出去重后的 rawSA（保持首次出现顺序）
        let histURL = WEDataDir.url.appendingPathComponent("voice-history.jsonl")
        guard let data = try? Data(contentsOf: histURL),
              let text = String(data: data, encoding: .utf8) else {
            print("Error: 读不到 \(histURL.path)")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var raws: [String] = []
        var seen = Set<String>()
        var decodeFail = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let entry = try? decoder.decode(VoiceHistoryEntry.self, from: Data(trimmed.utf8)) else {
                decodeFail += 1; continue
            }
            if seen.insert(entry.rawSA).inserted { raws.append(entry.rawSA) }
        }

        // 3) 当前 dict 纠错输出
        var current: [String: String] = [:]
        for raw in raws { current[raw] = CorrectionDictionary.shared.correct(raw) }

        // 4) golden baseline
        let baseURL = WEDataDir.url.appendingPathComponent("eval-corpus-baseline.json")
        let baseExists = FileManager.default.fileExists(atPath: baseURL.path)

        print("================================================================")
        print("CORPUS DICT-LAYER EVAL — uniq raw=\(raws.count)  decodeFail=\(decodeFail)")
        print("================================================================")

        if !baseExists || rebaseline {
            let pairs = raws.map { Pair(raw: $0, out: current[$0] ?? $0) }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            if let out = try? enc.encode(pairs) {
                try? out.write(to: baseURL)
                print("baseline \(rebaseline ? "REBASELINED" : "established"): \(pairs.count) 条 → \(baseURL.lastPathComponent)")
                let nonTrivial = pairs.filter { $0.raw != $0.out }.count
                print("其中 \(nonTrivial) 条纠错层有改写。")
            } else {
                print("Error: baseline 写入失败")
            }
            return
        }

        // 5) 对比基线
        guard let bdata = try? Data(contentsOf: baseURL),
              let basePairs = try? JSONDecoder().decode([Pair].self, from: bdata) else {
            print("Error: 读不到/解不开基线，删掉 \(baseURL.path) 重新建")
            return
        }
        var base: [String: String] = [:]
        for p in basePairs { base[p.raw] = p.out }

        var changed: [(raw: String, was: String, now: String)] = []
        var newRaw = 0
        for raw in raws {
            let now = current[raw] ?? raw
            if let was = base[raw] {
                if was != now { changed.append((raw: raw, was: was, now: now)) }
            } else {
                newRaw += 1
            }
        }

        print("baseline=\(basePairs.count)  当前 uniq=\(raws.count)  新增未入基线=\(newRaw)  CHANGED=\(changed.count)")
        print("")
        print("─── CHANGED（相对基线，前 \(maxShow) 条）───")
        if changed.isEmpty {
            print("  无变化 —— 当前纠错逻辑与基线完全一致")
        } else {
            for (i, c) in changed.prefix(maxShow).enumerated() {
                print("[\(i + 1)]")
                print("  raw : \(c.raw)")
                print("  base: \(c.was)")
                print("  now : \(c.now)")
            }
            if changed.count > maxShow {
                print("  … 还有 \(changed.count - maxShow) 条，传 `--eval-corpus \(changed.count)` 看全部")
            }
        }
        print("")
        print("确认这些变化都是改好的 → `MK --eval-corpus --rebaseline` 固化为新基线。")
    }
}
