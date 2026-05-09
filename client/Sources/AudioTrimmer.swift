import AVFoundation
import Foundation

/// 用 AVFoundation 内置裁剪/拼接音频文件。
/// MK --trim <in> <out.m4a> --start <sec> --duration <sec>
/// MK --concat <out.m4a> <in1.m4a> <in2.m4a> ...
enum AudioTrimmer {
    static func run() async {
        let args = CommandLine.arguments

        // concat 模式
        if let idx = args.firstIndex(of: "--concat"), idx + 2 < args.count {
            let outPath = args[idx + 1]
            let inputs = Array(args[(idx + 2)...])
            await concat(inputs: inputs, outPath: outPath)
            return
        }

        guard let idx = args.firstIndex(of: "--trim"),
              idx + 2 < args.count else {
            print("Usage: MK --trim <in> <out.m4a> --start <sec> --duration <sec>")
            print("       MK --concat <out.m4a> <in1.m4a> <in2.m4a> ...")
            return
        }
        let inPath = args[idx + 1]
        let outPath = args[idx + 2]
        let start = Double(parseArg(args, key: "--start") ?? "0") ?? 0
        let duration = Double(parseArg(args, key: "--duration") ?? "60") ?? 60

        let inURL = URL(fileURLWithPath: inPath)
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)

        let asset = AVURLAsset(url: inURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            print("Error: cannot create exporter")
            return
        }
        let cmStart = CMTime(seconds: start, preferredTimescale: 600)
        let cmDur = CMTime(seconds: duration, preferredTimescale: 600)
        exporter.outputURL = outURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(start: cmStart, duration: cmDur)

        do {
            try await exporter.export(to: outURL, as: .m4a)
            print("OK: \(outPath) (\(start)s + \(duration)s)")
        } catch {
            print("Export failed: \(error)")
        }
    }

    private static func parseArg(_ args: [String], key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 将多个音频文件按顺序拼接成一个 .m4a。
    private static func concat(inputs: [String], outPath: String) async {
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("Error: cannot create composition track")
            return
        }

        var insertAt = CMTime.zero
        for path in inputs {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                print("Skip (missing): \(path)")
                continue
            }
            let asset = AVURLAsset(url: url)
            do {
                let assetTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let assetTrack = assetTracks.first else {
                    print("Skip (no audio track): \(path)")
                    continue
                }
                let dur = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: dur)
                try track.insertTimeRange(range, of: assetTrack, at: insertAt)
                insertAt = CMTimeAdd(insertAt, dur)
                print("+ \(path) (\(CMTimeGetSeconds(dur))s) → cumulative \(CMTimeGetSeconds(insertAt))s")
            } catch {
                print("Error inserting \(path): \(error)")
            }
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            print("Error: cannot create exporter")
            return
        }
        exporter.outputURL = outURL
        exporter.outputFileType = .m4a

        do {
            try await exporter.export(to: outURL, as: .m4a)
            print("OK: \(outPath) total \(CMTimeGetSeconds(insertAt))s")
        } catch {
            print("Export failed: \(error)")
        }
    }
}
