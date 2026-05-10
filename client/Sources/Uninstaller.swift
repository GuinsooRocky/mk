import AppKit
import Foundation

/// MK 完全卸载 CLI
///
/// 用法：`MK --uninstall`（带提示）/ `MK --uninstall --yes`（不问直接删）
///
/// 删的内容：
/// - `~/.we/`（学习记录 / 字典 / 配置 / 录音 / 调试日志）
/// - `~/Library/Mobile Documents/com~apple~CloudDocs/MK/`（iCloud Drive 同步的 learned）
/// - `~/Library/Caches/com.lengmo.mk/`（系统给 .app 的运行时缓存）
/// - `~/Library/HTTPStorages/com.lengmo.mk/`
///
/// 不删（用户自己拖到废纸篓）：
/// - `/Applications/MK.app`
@MainActor
enum Uninstaller {
    static func run() async {
        let args = CommandLine.arguments
        let autoYes = args.contains("--yes") || args.contains("-y")

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let targets: [(String, String)] = [
            ("~/.we/",                                              "\(homeDir)/.we"),
            ("~/Library/Mobile Documents/com~apple~CloudDocs/MK/",  "\(homeDir)/Library/Mobile Documents/com~apple~CloudDocs/MK"),
            ("~/Library/Caches/com.lengmo.mk/",                     "\(homeDir)/Library/Caches/com.lengmo.mk"),
            ("~/Library/HTTPStorages/com.lengmo.mk/",               "\(homeDir)/Library/HTTPStorages/com.lengmo.mk")
        ]

        // 体检
        var totalSize: UInt64 = 0
        var existing: [(String, String, UInt64)] = []
        for (display, path) in targets {
            if FileManager.default.fileExists(atPath: path) {
                let size = directorySize(path: path)
                totalSize += size
                existing.append((display, path, size))
            }
        }

        if existing.isEmpty {
            print("MK 数据已经清空，无需卸载。")
            return
        }

        print("即将清除以下 MK 数据：")
        for (display, _, size) in existing {
            print("  \(display)  (\(humanReadable(size)))")
        }
        print("")
        print("总计: \(humanReadable(totalSize))")
        print("")
        print("【保留】 /Applications/MK.app — 自己拖到废纸篓")
        print("")

        if !autoYes {
            print("确认清除？这是不可逆的（学过的错例 / 配置 / 录音都没了）。输入 yes 继续：", terminator: " ")
            guard let response = readLine(), response.lowercased() == "yes" else {
                print("取消。")
                return
            }
        }

        // 执行
        for (display, path, _) in existing {
            do {
                try FileManager.default.removeItem(atPath: path)
                print("  ✓ 已删 \(display)")
            } catch {
                print("  ✗ 删失败 \(display): \(error)")
            }
        }
        print("")
        print("MK 数据已清空。还需要把 /Applications/MK.app 拖到废纸篓完成卸载。")
    }

    nonisolated private static func directorySize(path: String) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var size: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let full = "\(path)/\(file)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               let s = attrs[.size] as? UInt64 {
                size += s
            }
        }
        return size
    }

    nonisolated private static func humanReadable(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}
