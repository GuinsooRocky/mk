import AppKit
import SwiftUI

/// 云端识别（腾讯云 ASR）密钥配置窗口。
///
/// 菜单栏产品惯例：下拉菜单项不能塞可编辑文本框，密钥这种长串只能开独立设置窗输入。
/// 复用 HotKeySettingsWindow 的 NSWindow + NSHostingView(SwiftUI) 混合栈。
/// 密钥落到 ~/.mk/config.json 的 polish 段（tencent_secret_id / tencent_secret_key / tencent_appid），
/// 与 TencentEngine / TencentStreamingEngine 读的 key 一致。
@MainActor
final class CloudASRSettingsWindow {
    static let shared = CloudASRSettingsWindow()

    /// 「如何获取密钥?」跳转的图文说明（README 锚点）
    static let helpURL = URL(string: "https://github.com/GuinsooRocky/mk#cloud-asr")!

    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let p = RuntimeConfig.shared.polishConfig
        let viewModel = CloudASRSettingsViewModel(
            secretId: (p["tencent_secret_id"] as? String) ?? "",
            secretKey: (p["tencent_secret_key"] as? String) ?? "",
            appId: (p["tencent_appid"] as? String) ?? ""
        )
        viewModel.onSave = { [weak self] id, key, appid in
            let cfg = RuntimeConfig.shared
            cfg.setPolishField("tencent_secret_id", value: id)
            cfg.setPolishField("tencent_secret_key", value: key)
            cfg.setPolishField("tencent_appid", value: appid)
            // 用户专程来配云端密钥，填齐即自动切到云端引擎——否则 engine 仍是默认值，
            // 配了也不生效会让人困惑。清空密钥时不动引擎选择。
            if !id.isEmpty && !key.isEmpty {
                cfg.setPolishField("engine", value: "tencent")
            }
            Logger.log("CloudASR", "Saved Tencent credentials (appid=\(appid.isEmpty ? "none" : "set"))")
            self?.close()
        }
        viewModel.onCancel = { [weak self] in
            self?.close()
        }
        viewModel.onHelp = {
            NSWorkspace.shared.open(CloudASRSettingsWindow.helpURL)
        }

        let host = NSHostingView(rootView: CloudASRSettingsContentView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 300)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "云端识别设置（腾讯云）"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class CloudASRSettingsViewModel {
    var secretId: String
    var secretKey: String
    var appId: String
    var revealKey: Bool = false

    var onSave: ((String, String, String) -> Void)?
    var onCancel: (() -> Void)?
    var onHelp: (() -> Void)?

    init(secretId: String, secretKey: String, appId: String) {
        self.secretId = secretId
        self.secretKey = secretKey
        self.appId = appId
    }

    /// SecretId / SecretKey 是一句话识别的最低要求；AppID 仅实时流式需要，可空。
    var saveDisabled: Bool {
        secretId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func save() {
        let id = secretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appid = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(id, key, appid)
    }

    func cancel() { onCancel?() }
    func help() { onHelp?() }
}

// MARK: - SwiftUI 视图

struct CloudASRSettingsContentView: View {
    @Bindable var viewModel: CloudASRSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("腾讯云语音识别密钥")
                .font(.headline)

            field(label: "SecretId") {
                TextField("AKID...", text: $viewModel.secretId)
                    .textFieldStyle(.roundedBorder)
            }

            field(label: "SecretKey") {
                HStack(spacing: 6) {
                    if viewModel.revealKey {
                        TextField("", text: $viewModel.secretKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("", text: $viewModel.secretKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        viewModel.revealKey.toggle()
                    } label: {
                        Image(systemName: viewModel.revealKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(viewModel.revealKey ? "隐藏" : "显示")
                }
            }

            field(label: "AppID") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("1300000000", text: $viewModel.appId)
                        .textFieldStyle(.roundedBorder)
                    Text("仅「实时预览（边说边出）」需要；只用一句话识别可留空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Button("如何获取密钥? ↗") { viewModel.help() }
                    .buttonStyle(.link)
                Spacer()
                Button("取消") { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { viewModel.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.saveDisabled)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .frame(width: 72, alignment: .trailing)
                .padding(.top, 3)
            content()
        }
    }
}
