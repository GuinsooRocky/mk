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

        // 流式注入 toggle（实验，默认关）；对钩放在标题后面（不用 state）
        let streamingEnabled = (RuntimeConfig.shared.polishConfig["streaming_enabled"] as? Bool) ?? false
        let streamingTitle = "流式注入（实验，仅 Notes/文档类）" + (streamingEnabled ? "  ✓" : "")
        let streamingItem = NSMenuItem(
            title: streamingTitle,
            action: #selector(toggleStreaming),
            keyEquivalent: ""
        )
        streamingItem.target = self
        menu.addItem(streamingItem)

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

    @objc private func toggleStreaming() {
        let current = (RuntimeConfig.shared.polishConfig["streaming_enabled"] as? Bool) ?? false
        let newValue = !current
        RuntimeConfig.shared.setPolishField("streaming_enabled", value: newValue)
        Logger.log("StatusBar", "Streaming toggled to \(newValue)")
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
