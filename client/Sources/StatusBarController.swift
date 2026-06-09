import AppKit

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let moduleManager: ModuleManager
    private let config = RuntimeConfig.shared

    private var isRecording = false
    private var remoteStatus: RemoteInbox.Status = .idle

    init(moduleManager: ModuleManager) {
        self.moduleManager = moduleManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateIcon()
        setupMenu()
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        updateIcon()
    }

    func setRemoteStatus(_ status: RemoteInbox.Status) {
        remoteStatus = status
        setupMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let baseFont = NSFont.menuBarFont(ofSize: 0)
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

        button.image = nil
        button.contentTintColor = nil
        button.attributedTitle = NSAttributedString(
            string: "MK",
            attributes: [
                .font: boldFont,
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "MK 语音输入", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // 远程语音（iOS Shortcut HTTP push 时才显示）
        if remoteStatus != .idle {
            let port = RuntimeConfig.shared.remoteConfig["port"] as? Int ?? 9800
            let remoteItem = NSMenuItem(title: "远程语音：\(remoteStatus.rawValue) (:\(port))", action: nil, keyEquivalent: "")
            menu.addItem(remoteItem)
            menu.addItem(NSMenuItem.separator())
        }

        // 实时分段 toggle（SenseVoice VAD：边说边出 + 只 append 准确版；推荐，cc 终端安全）
        let liveEnabled = (RuntimeConfig.shared.polishConfig["live_segment_enabled"] as? Bool) ?? false
        let liveTitle = "实时分段（边说边出，SenseVoice）" + (liveEnabled ? "  ✓" : "")
        let liveItem = NSMenuItem(
            title: liveTitle,
            action: #selector(toggleLiveSegment),
            keyEquivalent: ""
        )
        liveItem.target = self
        menu.addItem(liveItem)

        // 学习模式 toggle（默认开）：注入 30s 内监听用户改字，自动入字典
        let learningEnabled = (RuntimeConfig.shared.polishConfig["learning_enabled"] as? Bool) ?? true
        let learningTitle = "学习模式（注入后 30s 自动学）" + (learningEnabled ? "  ✓" : "")
        let learningItem = NSMenuItem(
            title: learningTitle,
            action: #selector(toggleLearning),
            keyEquivalent: ""
        )
        learningItem.target = self
        menu.addItem(learningItem)

        menu.addItem(NSMenuItem.separator())

        // 识别引擎选择（✓ 标当前；点一下切换并写回 config）
        let currentEngine = (RuntimeConfig.shared.polishConfig["engine"] as? String) ?? "sa"
        let engineHeader = NSMenuItem(title: "识别引擎", action: nil, keyEquivalent: "")
        engineHeader.isEnabled = false
        menu.addItem(engineHeader)
        let engines: [(id: String, label: String)] = [
            ("sensevoice", "本地 SenseVoice（离线 / 私密）"),
            ("tencent", "腾讯云（云端 / 准）"),
            ("groq", "Groq Whisper（云端）")
        ]
        for e in engines {
            let title = "　" + e.label + (currentEngine == e.id ? "  ✓" : "")
            let item = NSMenuItem(title: title, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.id
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // 热键设置
        let hotkeyTitle: String = {
            let cfg = HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig)
            return "设置热键... (\(cfg.displayName))"
        }()
        let hotkeyItem = NSMenuItem(
            title: hotkeyTitle,
            action: #selector(openHotKeySettings),
            keyEquivalent: ""
        )
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openHotKeySettings() {
        HotKeySettingsWindow.shared.show()
    }

    @objc private func toggleLiveSegment() {
        let current = (RuntimeConfig.shared.polishConfig["live_segment_enabled"] as? Bool) ?? false
        let newValue = !current
        RuntimeConfig.shared.setPolishField("live_segment_enabled", value: newValue)
        Logger.log("StatusBar", "LiveSegment toggled to \(newValue)")
        setupMenu()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        RuntimeConfig.shared.setPolishField("engine", value: id)
        Logger.log("StatusBar", "Engine switched to \(id)")
        setupMenu()
    }

    @objc private func toggleLearning() {
        let current = (RuntimeConfig.shared.polishConfig["learning_enabled"] as? Bool) ?? true
        let newValue = !current
        RuntimeConfig.shared.setPolishField("learning_enabled", value: newValue)
        Logger.log("StatusBar", "Learning toggled to \(newValue)")
        setupMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
