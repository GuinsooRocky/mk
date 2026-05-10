import Foundation

/// 启动时把 .app 内 bundle 的字典领域包复制到 ~/.we/dictionary-domains/
/// 仅在用户本地缺该文件时复制，不覆盖用户已修改的版本
/// 在后台 queue 跑（纯文件 I/O，不需要 MainActor）
enum DictPackInstaller {
    /// 6 个预置领域包名（不带 .txt 后缀）
    static let bundledPacks = [
        "ai", "frontend", "backend", "product", "design", "internet-general"
    ]

    /// 启动时调一次：缺哪个补哪个
    static func installIfMissing() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let targetDir = "\(homeDir)/.we/dictionary-domains"

        // 确保目标目录存在
        if !FileManager.default.fileExists(atPath: targetDir) {
            try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        var installed: [String] = []
        var skipped: [String] = []
        for name in bundledPacks {
            let targetPath = "\(targetDir)/\(name).txt"
            if FileManager.default.fileExists(atPath: targetPath) {
                skipped.append(name)
                continue
            }
            // 从 SwiftPM 自动生成的 module bundle 里找 <name>.txt（.process(\"Resources\") 会扁平化）
            guard let bundleURL = Bundle.module.url(
                forResource: name,
                withExtension: "txt"
            ) else {
                Logger.log("DictPack", "bundle missing: \(name).txt")
                continue
            }
            do {
                try FileManager.default.copyItem(
                    at: bundleURL,
                    to: URL(fileURLWithPath: targetPath)
                )
                installed.append(name)
            } catch {
                Logger.log("DictPack", "copy failed \(name): \(error)")
            }
        }

        if !installed.isEmpty {
            Logger.log("DictPack", "installed \(installed.count) bundled packs: \(installed.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            Logger.log("DictPack", "kept user version of \(skipped.count) packs: \(skipped.joined(separator: ", "))")
        }
    }
}
