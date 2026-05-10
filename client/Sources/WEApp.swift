import AppKit
import SwiftUI

@main
struct WEApp {
    static func main() {
        // Gate 多阈值预览：MK --eval-gate "raw input"
        if CommandLine.arguments.contains("--eval-gate") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await GateEval.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // 音频裁剪/拼接：MK --trim ... 或 MK --concat ...
        if CommandLine.arguments.contains("--trim") || CommandLine.arguments.contains("--concat") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await AudioTrimmer.run()
                app.terminate(nil)
            }
            app.run()
            return
        }

        // 错例反馈学习：MK --learn "错音" "正字"
        // 追加到 ~/.we/correction-dictionary-learned.txt + reload；幂等（同条不重复）
        if let idx = CommandLine.arguments.firstIndex(of: "--learn"),
           idx + 2 < CommandLine.arguments.count {
            let wrong = CommandLine.arguments[idx + 1]
            let correct = CommandLine.arguments[idx + 2]
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                WEDataDir.ensureExists()
                let result = DictionaryLearner.learn(wrong: wrong, correct: correct)
                print(result)
                app.terminate(nil)
            }
            app.run()
            return
        }

        // 完整 pipeline 自检：MK --test-pipeline "raw text"
        // dict.correct → FillerRemover → PunctuationNormalizer，逐步打印
        if let idx = CommandLine.arguments.firstIndex(of: "--test-pipeline"),
           idx + 1 < CommandLine.arguments.count {
            let raw = CommandLine.arguments[idx + 1]
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                WEDataDir.ensureExists()
                let polish = RuntimeConfig.shared.polishConfig
                if let cap = polish["dict_max_terms"] as? Int, cap > 0 { CorrectionDictionary.maxHintTerms = cap }
                if let cap = polish["dict_max_correction_terms"] as? Int, cap > 0 { CorrectionDictionary.maxCorrectionTerms = cap }
                let paths = CorrectionDictionary.resolveEnabledPaths(polish: polish)
                if !paths.isEmpty { CorrectionDictionary.shared.loadAll(from: paths) }

                print("---")
                print("RAW:    \(raw)")
                let s1 = CorrectionDictionary.shared.correct(raw)
                print("DICT:   \(s1)")
                let s2 = NumberNormalizer.apply(s1)
                print("NUMBER: \(s2)")
                let s3 = FillerRemover.apply(s2)
                print("FILLER: \(s3)")
                let s4 = PunctuationNormalizer.apply(s3)
                print("PUNCT:  \(s4)")
                print("---")
                app.terminate(nil)
            }
            app.run()
            return
        }

        // 字典纠错自检：MK --test-dict-correct "raw text"
        // 把字典加载好后跑 correct() 打印 in/out（验证 Levenshtein + corrections 桥接）
        if let idx = CommandLine.arguments.firstIndex(of: "--test-dict-correct"),
           idx + 1 < CommandLine.arguments.count {
            let raw = CommandLine.arguments[idx + 1]
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                WEDataDir.ensureExists()
                let polish = RuntimeConfig.shared.polishConfig
                if let cap = polish["dict_max_terms"] as? Int, cap > 0 { CorrectionDictionary.maxHintTerms = cap }
                if let cap = polish["dict_max_correction_terms"] as? Int, cap > 0 { CorrectionDictionary.maxCorrectionTerms = cap }
                let paths = CorrectionDictionary.resolveEnabledPaths(polish: polish)
                if !paths.isEmpty { CorrectionDictionary.shared.loadAll(from: paths) }
                let result = CorrectionDictionary.shared.correct(raw)
                print("---")
                print("IN:  \(raw)")
                print("OUT: \(result)")
                print("---")
                app.terminate(nil)
            }
            app.run()
            return
        }

        // codebase 扫码自检：MK --test-codebase-scan
        // 直接跑 scheduleBackgroundScan() + 等扫完，不起 menubar/hotkey
        if CommandLine.arguments.contains("--test-codebase-scan") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task {
                await MainActor.run {
                    WEDataDir.ensureExists()
                    _ = RuntimeConfig.shared
                    CodebaseScanner.scheduleBackgroundScan()
                }
                // python 扫几秒～几十秒；给最多 90s
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                app.terminate(nil)
            }
            app.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // 菜单栏应用，不显示 Dock 图标
        app.run()
    }
}


/// CLI 参数解析（自检 / 评估 CLI 共用）
enum CLIUtils {
    static func parseArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private let moduleManager = ModuleManager()
    private let config = RuntimeConfig.shared
    private let remoteInbox = RemoteInbox()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化数据目录
        WEDataDir.ensureExists()

        // 检查权限
        // 屏幕录制权限只在 polish.context_ocr_enabled=true 时才主动申请，
        // 否则不弹框（避免用户没开 OCR 时启动就被打扰）
        let axOK = PermissionManager.checkAccessibility()
        let ocrEnabled = (config.polishConfig["context_ocr_enabled"] as? Bool) ?? false
        let screenOK = ocrEnabled ? PermissionManager.checkScreenCapture() : false
        Logger.log("WE", "Accessibility: \(axOK), Screen capture: \(screenOK) (ocr=\(ocrEnabled))")

        // 预加载字典（避免首次按热键 50-100ms 延迟 + 立即可见 multi-path 日志）
        let polish = config.polishConfig
        // 从配置注入字典硬上限（防膨胀）；缺省走默认 800/300
        if let cap = polish["dict_max_terms"] as? Int, cap > 0 {
            CorrectionDictionary.maxHintTerms = cap
        }
        if let cap = polish["dict_max_correction_terms"] as? Int, cap > 0 {
            CorrectionDictionary.maxCorrectionTerms = cap
        }
        if (polish["context_dictionary_enabled"] as? Bool) ?? false {
            let paths = CorrectionDictionary.resolveEnabledPaths(polish: polish)
            if !paths.isEmpty {
                CorrectionDictionary.shared.loadAll(from: paths)
            }
        }

        // 后台扫码：mtime 变了才跑，跑完自动 reload 字典
        CodebaseScanner.scheduleBackgroundScan()

        // 初始化菜单栏
        statusBar = StatusBarController(moduleManager: moduleManager)

        // 注册语音模块
        let voiceModule = VoiceModule()
        voiceModule.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusBar?.setRecording(state == .recording)
        }
        moduleManager.register(voiceModule)

        // 注册全局热键
        GlobalHotKey.shared.onPress = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyDown()
        }
        GlobalHotKey.shared.onRelease = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyUp()
        }
        GlobalHotKey.shared.start()

        // 启动远程语音接收
        let remoteConfig = config.remoteConfig
        if remoteConfig["enabled"] as? Bool == true {
            let port = remoteConfig["port"] as? Int ?? 9800
            let token = remoteConfig["auth_token"] as? String ?? ""
            remoteInbox.onStatusChange = { [weak self] status in
                self?.statusBar?.setRemoteStatus(status)
            }
            remoteInbox.start(port: UInt16(port), authToken: token)
            Logger.log("WE", "Remote inbox: ON (:\(port))")
        }

        // G1 ambient 模式（config 控制开关）
        if config.ambientEnabled {
            let ambient = AmbientController.shared
            ambient.onSpeechStart = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .idle else { return }
                vm.onHotKeyDown()  // 复用热键流程：开始录音
            }
            ambient.onSpeechEnd = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .recording else { return }
                vm.onHotKeyDown()  // 复用热键流程：停止并处理
            }
            ambient.start()
            Logger.log("WE", "Ambient mode: ON")
        }

        Logger.log("WE", "App launched, modules: \(moduleManager.moduleNames)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.stop()
        AmbientController.shared.stop()
        remoteInbox.stop()
        Logger.log("WE", "App terminated")
    }
}
