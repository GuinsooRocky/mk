import Foundation

/// 启动时把 .app 内 bundle 的字典领域包复制到 ~/.mk/dictionary-domains/
///
/// 行为依赖 `polish.learning_happened` flag（CorrectionCapture / DictionaryLearner 触发翻 true）：
/// - **flag=false（用户未学过）**：bundle 版本始终覆盖到本地（fresh / update 都拿最新）
/// - **flag=true（已学过）**：保留用户本地版本（用户改过的领域包 / 自定义内容不丢）
///
/// 这样：
/// - 真正的 fresh user → 装啥用啥，bundle 演进自动同步
/// - 学过之后的 user → 个人积累被保护，bundle 升级不冲掉
///
/// 在后台 queue 跑（纯文件 I/O，不需要 MainActor）
enum DictPackInstaller {
    /// 6 个预置领域包名（不带 .txt 后缀）
    static let bundledPacks = [
        "ai", "frontend", "backend", "product", "design", "internet-general"
    ]

    /// SwiftPM 自动生成的 `Bundle.module` accessor 在 .app 里失效：
    /// 它用 `Bundle.main.bundleURL.appendingPathComponent("WE_MK.bundle")`，
    /// .app 内会去找 `.app/WE_MK.bundle`（顶级），但 bundle 实际在 `Contents/Resources/`，
    /// 永远找不到 → fatalError。改成显式从两条路径找：
    /// - `.app/Contents/Resources/WE_MK.bundle/<name>.txt`（打包后场景）
    /// - `<binary-dir>/WE_MK.bundle/<name>.txt`（`swift run` / 直跑二进制场景）
    private static func resolveBundleURL(name: String) -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("WE_MK.bundle/\(name).txt"),
            Bundle.main.bundleURL.appendingPathComponent("WE_MK.bundle/\(name).txt"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// 启动时调一次：缺哪个补哪个；学过的不动；没学过可被 bundle 覆盖更新
    /// hasLearned 由 caller 注入（main MainActor 读 RuntimeConfig）
    static func installIfMissing(hasLearned: Bool) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let targetDir = "\(homeDir)/.mk/dictionary-domains"

        if !FileManager.default.fileExists(atPath: targetDir) {
            try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        var installed: [String] = []
        var refreshed: [String] = []
        var skipped: [String] = []

        for name in bundledPacks {
            let targetPath = "\(targetDir)/\(name).txt"
            let exists = FileManager.default.fileExists(atPath: targetPath)

            // 已学过 + 文件存在 → 保护，不动
            if exists && hasLearned {
                skipped.append(name)
                continue
            }

            guard let bundleURL = Self.resolveBundleURL(name: name) else {
                Logger.log("DictPack", "bundle missing: \(name).txt")
                continue
            }

            do {
                if exists {
                    // 没学过 + 文件存在 → 用 bundle 覆盖（fresh user 拿最新）
                    try FileManager.default.removeItem(atPath: targetPath)
                    try FileManager.default.copyItem(at: bundleURL, to: URL(fileURLWithPath: targetPath))
                    refreshed.append(name)
                } else {
                    // 文件不存在 → 首次安装
                    try FileManager.default.copyItem(at: bundleURL, to: URL(fileURLWithPath: targetPath))
                    installed.append(name)
                }
            } catch {
                Logger.log("DictPack", "copy failed \(name): \(error)")
            }
        }

        if !installed.isEmpty {
            Logger.log("DictPack", "installed \(installed.count) bundled packs (fresh): \(installed.joined(separator: ", "))")
        }
        if !refreshed.isEmpty {
            Logger.log("DictPack", "refreshed \(refreshed.count) packs from bundle (user not learned yet): \(refreshed.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            Logger.log("DictPack", "preserved \(skipped.count) user packs (learning_happened=true): \(skipped.joined(separator: ", "))")
        }
    }
}
