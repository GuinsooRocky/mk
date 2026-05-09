import Foundation

/// 语音后处理流水线
/// L2: PolishClient 语义润色（可关闭）
/// 注入 → 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?
    ) async {
        let tStart = CFAbsoluteTimeGetCurrent()
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        // L1: 信任 Apple 官方排序；额外做字典反向纠错（音译→正字，如 SAG→SVG）
        // 字典已加载（VoiceModule 在 startRecording 时调过 ContextEnhancer.enhance）
        var l1Text = CorrectionDictionary.shared.correct(rawText)
        if l1Text != rawText {
            Logger.log("Pipeline", "Corrected: \(rawText) → \(l1Text)")
        }

        // FR6：中文数字 → 阿拉伯（轻量 ITN）— 在 filler 之前，避免压缩"三三三"等
        let polishConf = RuntimeConfig.shared.polishConfig
        if (polishConf["fr6_number_enabled"] as? Bool) ?? true {
            let normalized = NumberNormalizer.apply(l1Text)
            if normalized != l1Text {
                Logger.log("Pipeline", "Number: \(l1Text) → \(normalized)")
                l1Text = normalized
            }
        }

        // FR5：口语 filler / 重复词清洗（在标点之前，否则标点出现后 \1 backref 不连续）
        if (polishConf["fr5_filler_enabled"] as? Bool) ?? true {
            let cleaned = FillerRemover.apply(l1Text)
            if cleaned != l1Text {
                Logger.log("Pipeline", "Filler: \(l1Text) → \(cleaned)")
                l1Text = cleaned
            }
        }

        // FR4 v0.1：中文口语 → 标点符号（仅独立 token，避免误伤）
        if (polishConf["fr4_punctuation_enabled"] as? Bool) ?? true {
            let normalized = PunctuationNormalizer.apply(l1Text)
            if normalized != l1Text {
                Logger.log("Pipeline", "Punct: \(l1Text) → \(normalized)")
                l1Text = normalized
            }
        }

        // L2: 模型润色（polish.enabled = false 时跳过）
        let finalText: String
        let polished: String?
        var l2ElapsedMs = 0
        if RuntimeConfig.shared.polishConfig["enabled"] as? Bool == true {
            let tL2 = CFAbsoluteTimeGetCurrent()
            polished = await PolishClient.shared.polish(
                text: l1Text,
                words: transcription.words,
                app: targetApp
            )
            l2ElapsedMs = Int((CFAbsoluteTimeGetCurrent() - tL2) * 1000)

            // 无条件记录 L2 真实行为：nil / identity / 真改
            let kind: String
            if polished == nil { kind = "nil" }
            else if polished == l1Text { kind = "identity" }
            else { kind = "changed" }
            Logger.log("Pipeline", "L2: elapsedMs=\(l2ElapsedMs) kind=\(kind) output=\(polished ?? "<nil>")")

            finalText = polished ?? l1Text
        } else {
            polished = nil
            finalText = l1Text
            Logger.log("Pipeline", "L2: skipped (polish.enabled=false)")
        }

        // 注入到焦点应用
        let tInject = CFAbsoluteTimeGetCurrent()
        TextInjector.inject(text: finalText, to: targetApp)
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - tInject) * 1000)

        // 历史落盘（始终写入，蒸馏需要）
        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: polished,
            finalText: finalText,
            app: targetApp
        )

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        Logger.log("Pipeline", "Timing: l2=\(l2ElapsedMs)ms inject=\(injectMs)ms pipeline_total=\(totalMs)ms")
    }
}
