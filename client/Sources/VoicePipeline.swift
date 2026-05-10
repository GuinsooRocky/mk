import Foundation

/// 语音后处理流水线
/// 字典 → 数字 ITN → filler → 标点 → 注入 → 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    /// 应用层纠错管线
    /// 流式路径在 release 时调一次；非流式 process() 内部也调它
    func correctText(_ rawText: String) -> String {
        var text = CorrectionDictionary.shared.correct(rawText)
        if text != rawText {
            Logger.log("Pipeline", "Corrected: \(rawText) → \(text)")
        }

        let polishConf = RuntimeConfig.shared.polishConfig

        if (polishConf["fr6_number_enabled"] as? Bool) ?? true {
            let normalized = NumberNormalizer.apply(text)
            if normalized != text {
                Logger.log("Pipeline", "Number: \(text) → \(normalized)")
                text = normalized
            }
        }

        if (polishConf["fr5_filler_enabled"] as? Bool) ?? true {
            let cleaned = FillerRemover.apply(text)
            if cleaned != text {
                Logger.log("Pipeline", "Filler: \(text) → \(cleaned)")
                text = cleaned
            }
        }

        if (polishConf["fr4_punctuation_enabled"] as? Bool) ?? true {
            let normalized = PunctuationNormalizer.apply(text)
            if normalized != text {
                Logger.log("Pipeline", "Punct: \(text) → \(normalized)")
                text = normalized
            }
        }

        return text
    }

    /// 流式路径：跑完 correctText 后用 streamingInjector 注入 → 这里只落历史
    func saveStreamingResult(
        transcription: TranscriptionResult,
        finalText: String,
        targetApp: AppIdentity?
    ) {
        history.save(
            transcription: transcription,
            l1Text: finalText,
            polishedText: nil,
            finalText: finalText,
            app: targetApp
        )
    }

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?
    ) async {
        let tStart = CFAbsoluteTimeGetCurrent()
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        let l1Text = correctText(rawText)

        let tInject = CFAbsoluteTimeGetCurrent()
        TextInjector.inject(text: l1Text, to: targetApp)
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - tInject) * 1000)

        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: nil,
            finalText: l1Text,
            app: targetApp
        )

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        Logger.log("Pipeline", "Timing: inject=\(injectMs)ms pipeline_total=\(totalMs)ms")
    }
}
