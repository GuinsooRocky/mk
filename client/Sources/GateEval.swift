import AppKit
import Foundation

/// Gate 多阈值预览 CLI
///
/// 用法：`MK --eval-gate "raw input text"`
///
/// 用 5 个阈值跑 correct()，对比哪些 corrections 在哪个阈值被砍掉。
/// **调 polish.gate_threshold 前必跑这个**，看会丢哪些纠错。如果丢的都是合理替换，说明 confidence 算错了，回去调算法不是调阈值。
///
/// 灵感：subagent 论文分析的 "消融式 eval" + "FPR/TPR 双指标"
@MainActor
enum GateEval {
    static func run() async {
        WEDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let idx = args.firstIndex(of: "--eval-gate"), idx + 1 < args.count else {
            print("Usage: MK --eval-gate \"raw input text\"")
            print("Example: MK --eval-gate \"我现在测试流市这个词，使用 Even Lop\"")
            return
        }
        let raw = args[idx + 1]

        // 加载字典
        let polish = RuntimeConfig.shared.polishConfig
        if let cap = polish["dict_max_terms"] as? Int, cap > 0 { CorrectionDictionary.maxHintTerms = cap }
        if let cap = polish["dict_max_correction_terms"] as? Int, cap > 0 { CorrectionDictionary.maxCorrectionTerms = cap }
        let paths = CorrectionDictionary.resolveEnabledPaths(polish: polish)
        guard !paths.isEmpty else {
            print("Error: no dict paths configured")
            return
        }
        CorrectionDictionary.shared.loadAll(from: paths)

        let thresholds: [Double] = [0.0, 0.3, 0.5, 0.7, 0.9]
        var results: [(threshold: Double, output: String, accepted: [String], rejected: [String])] = []

        print("================================================================")
        print("INPUT: \(raw)")
        print("================================================================")

        for t in thresholds {
            CorrectionDictionary.shared.gateThresholdOverride = t
            let output = CorrectionDictionary.shared.correct(raw)
            let records = CorrectionDictionary.shared.lastCorrections
            let accepted = records.filter { $0.accepted }.map { "\($0.layer): \($0.original)→\($0.replacement) c=\(String(format: "%.2f", $0.confidence))" }
            let rejected = records.filter { !$0.accepted }.map { "\($0.layer): \($0.original)→\($0.replacement) c=\(String(format: "%.2f", $0.confidence))" }
            results.append((threshold: t, output: output, accepted: accepted, rejected: rejected))
        }
        CorrectionDictionary.shared.gateThresholdOverride = nil

        // 打印每个阈值的输出
        for r in results {
            print("")
            print("─── threshold=\(String(format: "%.1f", r.threshold)) ───")
            print("OUTPUT: \(r.output)")
            if !r.accepted.isEmpty {
                print("ACCEPTED (\(r.accepted.count)):")
                for a in r.accepted { print("  ✓ \(a)") }
            }
            if !r.rejected.isEmpty {
                print("REJECTED (\(r.rejected.count)):")
                for x in r.rejected { print("  ✗ \(x)") }
            }
        }

        // 增量分析：从 0.0 → 0.3 → 0.5 → 0.7 → 0.9 各砍了什么
        print("")
        print("================================================================")
        print("DELTA ANALYSIS — 升阈值会砍掉哪些纠错")
        print("================================================================")
        for i in 1..<results.count {
            let prev = results[i - 1]
            let curr = results[i]
            let prevAcceptedSet = Set(prev.accepted)
            let currAcceptedSet = Set(curr.accepted)
            let lost = prevAcceptedSet.subtracting(currAcceptedSet)
            print("")
            print("\(String(format: "%.1f", prev.threshold)) → \(String(format: "%.1f", curr.threshold)):")
            if lost.isEmpty {
                print("  无变化（safe to raise to \(String(format: "%.1f", curr.threshold))）")
            } else {
                print("  砍了 \(lost.count) 条:")
                for l in lost.sorted() { print("    \(l)") }
                if curr.output != prev.output {
                    print("  最终文本变了:")
                    print("    \(prev.threshold): \(prev.output)")
                    print("    \(curr.threshold): \(curr.output)")
                }
            }
        }

        print("")
        print("================================================================")
        print("HOW TO USE")
        print("================================================================")
        print("看上面 DELTA — 找到第一个砍掉合理纠错的阈值边界，那是你的上限。")
        print("调阈值：编辑 ~/.we/config.json 加 \"polish\": { \"gate_threshold\": 0.X }")
        print("回滚：删掉 gate_threshold 字段，行为恢复 v0.3 默认（threshold=0）")
    }
}
