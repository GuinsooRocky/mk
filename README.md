# MK

**macOS 语音输入：按住右 Option 说话，松开，文字落到光标处。**

任何 app 都能用——包括 macOS 自带听写进不去的 Claude Code / iTerm2 等终端。

- **免费开源**，默认完全离线（走 macOS 26 自带语音识别），0 订阅 0 上传
- **中文为主、英文技术词不音译**：说「用 SwiftUI 写个组件」，出的就是 `SwiftUI`，不是"斯威夫特 UI"
- **越用越准**：错字手改一次自动进字典，第二次就对
- **快**：松开到出字约 150ms，比 superwhisper 快一个量级

> 给谁用：每天在终端 / 编辑器 / IM 里大量打字，想用嘴替代手的人。
> superwhisper 慢 + 订阅；macOS 自带听写进不了终端、技术词必音译——MK 就是冲这两个痛点做的。

---

## 安装（3 步）

**[📦 下载 MK-v0.4.4.zip](https://github.com/GuinsooRocky/mk/releases/download/v0.4.4/MK-v0.4.4.zip)**

1. 解压，把 `MK.app` 拖进 `/Applications/`
2. **右键** MK.app → **打开** → 选「**仍要打开**」（自签名 app，只有第一次要这样开）
3. 按提示授权 **麦克风 / 语音识别 / 辅助功能**

装完就能用：**按住右 Option 说话，松开出字**。录音中 = 菜单栏右上的系统橙点。

> 要求 macOS 26+（Apple Silicon），系统设置里已下载中文听写模型。
> 想从源码编译 → [docs/development.md](docs/development.md)。全部版本 → [更新日志](docs/CHANGELOG.md)。

---

## 识别引擎：装完即用，想更准再配

出厂默认走 **macOS 系统识别**——零配置、完全离线，装完直接说。

想换挡时，点菜单栏 **MK ▾** 的「识别引擎」一行循环切换：

| 引擎 | 特点 | 需要做什么 |
|---|---|---|
| 系统识别（出厂默认） | 离线、零配置 | 什么都不用 |
| **标准（云端，更准）** | 最准，走腾讯云（有免费额度） | 配一次密钥，约 5 分钟，见下 |
| 离线（本地，隐私） | 离线多语种 zh/en/ja/ko/yue | 下载一次 230MB 模型，见下 |

<a id="cloud-asr"></a>

### 配「标准（云端，更准）」

1. 注册/登录腾讯云，开通 [语音识别 ASR](https://console.cloud.tencent.com/asr)（按量计费，有免费额度）
2. 到 [API 密钥管理](https://console.cloud.tencent.com/cam/capi) → **新建密钥**，复制 **SecretId**（`AKID...` 开头）和 **SecretKey**
3. 菜单栏 **MK ▾ → 云端识别设置** → 把两个值粘进去 → **保存**——保存后自动切到云端引擎，完事

- **AppID** 一栏只有开「实时预览（边说边出）」才需要（在 [账号信息页](https://console.cloud.tencent.com/developer) 顶部），不开可留空
- 密钥只存本机 `~/.mk/config.json`，不经过任何第三方
- 网络异常自动回落本地识别，不会让你空手

### 配「离线（本地，隐私）」

下载一次 SenseVoice 模型（~230MB，不随 app 打包）：

```bash
mkdir -p ~/.mk/models && cd ~/.mk/models
curl -fL -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2
tar -xjf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2 && rm sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2
```

然后菜单栏切到「离线（本地，隐私）」。模型没下好也不会崩——自动回落系统识别。

---

## 越用越准：喂它一次就记住

识别错了？一行命令登记「错音 → 正字」，立即生效：

```bash
/Applications/MK.app/Contents/MacOS/MK --learn "depsick" "DeepSeek"
```

或者什么都不做：注入后你手动改了错字，MK 会自动学（菜单栏「自动学习我的修改」）。

还能后台扫你的代码仓库，把驼峰命名 / 缩写自动喂进识别提示——项目里的术语第一次说就有很高命中率。

字典全套玩法（领域包 / codebase 扫描 / 三层纠错原理）→ [docs/dictionary.md](docs/dictionary.md)

---

## 边界（说清楚不骗人）

- **中文为主 + 英文术语混说**是目标场景；**纯英文段落**识别不行（系统中文模型的物理限制）
- 做一句话级输入，**不做**长录音 / 会议纪要
- 中文同音错（"拍戏/派系"）不在纠错范围
- 完整边界与 roadmap → [docs/roadmap.md](docs/roadmap.md)

## 卸载

```bash
/Applications/MK.app/Contents/MacOS/MK --uninstall   # 清 ~/.mk/ 等全部数据，带确认提示
```

再把 `/Applications/MK.app` 拖进废纸篓即可。

## 更多文档

| 文档 | 内容 |
|---|---|
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | 各版本更新说明 |
| [docs/dictionary.md](docs/dictionary.md) | 字典与纠错：领域包 / 错例反馈 / codebase 扫描 / Gate 调参 |
| [docs/development.md](docs/development.md) | 源码编译 / config.json 全字段 / 工作原理与注入架构 |
| [docs/roadmap.md](docs/roadmap.md) | 已完成 / 下一步 / 已知限制 |

## License

MIT
