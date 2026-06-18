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

        // 实时预览 toggle（SenseVoice VAD：边说边出 + 只 append 准确版；推荐，cc 终端安全）
        // 勾选用原生 state（✓ 落最左勾选槽、自动对齐），不再把 "  ✓" 拼进标题
        let liveEnabled = (RuntimeConfig.shared.polishConfig["live_segment_enabled"] as? Bool) ?? false
        let liveItem = NSMenuItem(
            title: "实时预览（边说边出）",
            action: #selector(toggleLiveSegment),
            keyEquivalent: ""
        )
        liveItem.target = self
        liveItem.state = liveEnabled ? .on : .off
        menu.addItem(liveItem)

        // 学习模式 toggle（默认开）：注入 30s 内监听用户改字，自动入字典
        let learningEnabled = (RuntimeConfig.shared.polishConfig["learning_enabled"] as? Bool) ?? true
        let learningItem = NSMenuItem(
            title: "自动学习我的修改",
            action: #selector(toggleLearning),
            keyEquivalent: ""
        )
        learningItem.target = self
        learningItem.state = learningEnabled ? .on : .off
        menu.addItem(learningItem)

        menu.addItem(NSMenuItem.separator())

        // 识别引擎：单行循环切换。用自绘视图而非标准菜单项——标准项点了会收起菜单；
        // 自绘视图自己吃鼠标事件，点一下循环切换、菜单保持打开，可连点切到想要的引擎。
        let engineView = EngineCycleItemView(title: engineItemTitle())
        engineView.onClick = { [weak self, weak engineView] in
            guard let self else { return }
            self.cycleEngine()
            engineView?.setTitle(self.engineItemTitle())
        }
        let engineItem = NSMenuItem()
        engineItem.view = engineView
        menu.addItem(engineItem)

        // 云端识别设置（腾讯云密钥）
        let cloudItem = NSMenuItem(
            title: "云端识别设置",
            action: #selector(openCloudSettings),
            keyEquivalent: ""
        )
        cloudItem.target = self
        menu.addItem(cloudItem)

        menu.addItem(NSMenuItem.separator())

        // 热键设置
        let hotkeyTitle: String = {
            let cfg = HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig)
            return "设置热键 (\(cfg.displayName))"
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

    @objc private func openCloudSettings() {
        CloudASRSettingsWindow.shared.show()
    }

    /// 引擎循环列表（Groq 是开发期对比引擎，仅配了 key 才纳入循环）。
    /// 单行显示当前引擎、循环切换的下一项，都依据它，避免两处各写一份漂移。
    private func engineCycle() -> [(id: String, label: String)] {
        var list: [(id: String, label: String)] = [
            ("tencent", "标准（云端，更准）"),
            ("sensevoice", "离线（本地，隐私）")
        ]
        let groqKey = ((config.polishConfig["groq_api_key"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !groqKey.isEmpty {
            list.append(("groq", "Groq Whisper（对比测试）"))
        }
        return list
    }

    /// 引擎单行项的标题（含当前引擎名 + 未配置云端时的 ⚠️）。显示和点击后就地刷新共用。
    private func engineItemTitle() -> String {
        let currentEngine = (config.polishConfig["engine"] as? String) ?? "sa"
        let tencentConfigured = !((config.polishConfig["tencent_secret_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cycle = engineCycle()
        let curLabel = cycle.first { $0.id == currentEngine }?.label ?? cycle[0].label
        let warn = (currentEngine == "tencent" && !tencentConfigured) ? "  ⚠️未配置" : ""
        return "识别引擎：\(curLabel)\(warn)   ⟳"
    }

    /// 切到下一个引擎并写回 config。不调 setupMenu——菜单保持打开，由调用方就地刷新标题。
    private func cycleEngine() {
        let cur = (config.polishConfig["engine"] as? String) ?? "sa"
        let cycle = engineCycle()
        // 当前不在列表（如默认 sa）→ firstIndex 为 nil，next 落到第一项
        let idx = cycle.firstIndex { $0.id == cur }
        let next = cycle[((idx ?? -1) + 1) % cycle.count].id
        config.setPolishField("engine", value: next)
        Logger.log("StatusBar", "Engine cycled \(cur) -> \(next)")
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

/// 识别引擎单行项的自绘视图：点击循环切换但**不收起菜单**（标准菜单项点了会 dismiss）。
/// 自己处理鼠标进入/离开高亮 + mouseUp 触发回调，菜单因此保持打开，可连点。
@MainActor
final class EngineCycleItemView: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField
    private var hovered = false

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        label.font = NSFont.menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            // leading 20 ≈ 标准菜单项让出勾选槽后的文字起点，跟上面两行对齐
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setTitle(_ t: String) {
        label.stringValue = t
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
            label.textColor = .selectedMenuItemTextColor
        } else {
            label.textColor = .labelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}
