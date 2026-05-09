import Foundation

/// 启动时后台跑 scan-codebase.py 自动生成 codebase 字典。
///
/// 配置（`~/.we/config.json` 的 `polish.codebase_scan`）：
/// ```json
/// "codebase_scan": {
///   "enabled": true,
///   "roots": ["~/Desktop/my-code", "~/Desktop/cmm"],
///   "out_path": "~/.we/correction-dictionary-codebase.txt",
///   "script_path": "~/.we/scripts/scan-codebase.py",   // 可选；缺省按几个常见位置找
///   "top": 300,
///   "min_freq": 3
/// }
/// ```
///
/// 缓存：`~/.we/cache/codebase-scan.meta.json` 记录每个 root 上次扫描时的 mtime。
/// 任一 root 的 mtime 变了 → 重扫；全部没变 → 直接跳过。
///
/// 全程异步、失败兜底成 log，不阻塞 UI。
@MainActor
enum CodebaseScanner {
    private static let cacheURL = WEDataDir.url
        .appendingPathComponent("cache")
        .appendingPathComponent("codebase-scan.meta.json")

    /// 启动时调用：按需后台扫码 + 扫完触发字典 reload
    static func scheduleBackgroundScan() {
        let polish = RuntimeConfig.shared.polishConfig
        guard let cfg = polish["codebase_scan"] as? [String: Any],
              (cfg["enabled"] as? Bool) ?? false,
              let rawRoots = cfg["roots"] as? [String], !rawRoots.isEmpty,
              let rawOut = cfg["out_path"] as? String, !rawOut.isEmpty else {
            return
        }

        let roots = rawRoots.map { ($0 as NSString).expandingTildeInPath }
        let outPath = (rawOut as NSString).expandingTildeInPath
        let top = cfg["top"] as? Int ?? 300
        let minFreq = cfg["min_freq"] as? Int ?? 3
        let scriptOverride = cfg["script_path"] as? String

        // mtime 比对：全没变就 skip
        let currentMtimes = collectMtimes(roots: roots)
        if let cached = loadCachedMtimes(), cached == currentMtimes,
           FileManager.default.fileExists(atPath: outPath) {
            Logger.log("Scanner", "Skip scan (no root mtime change)")
            return
        }

        guard let scriptPath = resolveScriptPath(override: scriptOverride) else {
            Logger.log("Scanner", "scan-codebase.py not found (set polish.codebase_scan.script_path)")
            return
        }
        guard let pythonPath = resolvePython() else {
            Logger.log("Scanner", "python3 not found in PATH (skip)")
            return
        }

        Logger.log("Scanner", "Scan started: roots=\(roots.count) out=\(outPath)")
        spawn(
            python: pythonPath,
            script: scriptPath,
            roots: roots,
            outPath: outPath,
            top: top,
            minFreq: minFreq,
            mtimesAtScanStart: currentMtimes
        )
    }

    // MARK: - process spawn

    private static func spawn(
        python: String,
        script: String,
        roots: [String],
        outPath: String,
        top: Int,
        minFreq: Int,
        mtimesAtScanStart: [String: Double]
    ) {
        // 确保 out 目录存在
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            script,
            "--top", String(top),
            "--min-freq", String(minFreq),
            "--out", outPath
        ] + roots

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()  // 丢弃

        let started = CFAbsoluteTimeGetCurrent()
        process.terminationHandler = { proc in
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let firstLine = stderrText
                .components(separatedBy: .newlines)
                .first { !$0.isEmpty } ?? ""

            Task { @MainActor in
                if proc.terminationStatus == 0 {
                    Logger.log("Scanner", "Scan ok in \(String(format: "%.2f", elapsed))s — \(firstLine)")
                    saveCache(mtimes: mtimesAtScanStart)
                    reloadDictionary()
                } else {
                    Logger.log("Scanner", "Scan failed exit=\(proc.terminationStatus): \(stderrText.prefix(200))")
                }
            }
        }

        do {
            try process.run()
        } catch {
            Logger.log("Scanner", "Spawn failed: \(error)")
        }
    }

    private static func reloadDictionary() {
        let polish = RuntimeConfig.shared.polishConfig
        guard (polish["context_dictionary_enabled"] as? Bool) ?? false else { return }
        var paths: [String] = []
        if let p = polish["context_dictionary_path"] as? String, !p.isEmpty { paths.append(p) }
        if let extras = polish["context_dictionary_paths"] as? [String] { paths.append(contentsOf: extras) }
        guard !paths.isEmpty else { return }
        CorrectionDictionary.shared.loadAll(from: paths)
    }

    // MARK: - mtime cache

    /// 取每个 root 自身 mtime + 直接子目录 mtime 的最大值。粗糙但足够：
    /// 子目录新增/删除会改父 mtime；子目录内的文件改动会改该子目录 mtime。
    /// 不递归扫所有文件（那就跟扫码本身一样慢了）。
    private static func collectMtimes(roots: [String]) -> [String: Double] {
        var result: [String: Double] = [:]
        let fm = FileManager.default
        for root in roots {
            guard fm.fileExists(atPath: root) else { continue }
            var maxMtime = mtime(of: root)
            if let children = try? fm.contentsOfDirectory(atPath: root) {
                for child in children where !child.hasPrefix(".") {
                    let p = (root as NSString).appendingPathComponent(child)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                    maxMtime = max(maxMtime, mtime(of: p))
                }
            }
            result[root] = maxMtime
        }
        return result
    }

    private static func mtime(of path: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return 0 }
        return date.timeIntervalSince1970
    }

    private static func loadCachedMtimes() -> [String: Double]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mtimes = json["mtimes"] as? [String: Double] else { return nil }
        return mtimes
    }

    private static func saveCache(mtimes: [String: Double]) {
        let payload: [String: Any] = [
            "mtimes": mtimes,
            "saved_at": Date().timeIntervalSince1970
        ]
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - resolve script / python

    /// 优先级：用户配置 → ~/.we/scripts/ → 当前 cwd 旁边 → 仓库源码（开发时）
    private static func resolveScriptPath(override: String?) -> String? {
        let fm = FileManager.default
        if let o = override {
            let p = (o as NSString).expandingTildeInPath
            if fm.fileExists(atPath: p) { return p }
        }
        let candidates: [String] = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".we/scripts/scan-codebase.py"),
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("client/scripts/scan-codebase.py"),
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("scripts/scan-codebase.py")
        ]
        return candidates.first(where: { fm.fileExists(atPath: $0) })
    }

    /// 用 /usr/bin/env which 找 python3，避免硬编码路径
    private static func resolvePython() -> String? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let fm = FileManager.default
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "python3"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
