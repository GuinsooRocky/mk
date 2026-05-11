# MK — macOS 语音输入 PRD

> 版本 v0.1 · 起草日期 2026-05-08 · 状态 草稿（待 grill）

---

## 1. 背景

### 1.1 用户痛点
日常和 Claude Code 对话量大（昨天一天 ~355 条手打消息），手打慢且累。市面方案不满足：

| 现状 | 问题 |
|---|---|
| superwhisper（已删） | 本地 Whisper 慢（1-2 秒）、识别不准、付费 |
| macOS 自带 Dictation | 三道结构性墙（详见 §1.3），不可用 |
| 飞书 / 微信 / Telegram 内置语音输入 | 仅限自家 app，无法用在 Claude Code 终端输入框 |

### 1.2 关键观察
- macOS 26 起苹果发布 **SpeechAnalyzer** 新 API，比 SFSpeechRecognizer 更快更准（端侧 only）
- 用户机器 = macOS 26.4.1 + M5，**端侧推理性能溢出**
- 已有同类开源方案 [Marvinngg/ambient-voice](https://github.com/Marvinngg/ambient-voice)（116 stars）方向一致
- 已有同类大型方案 [VoiceInk](https://github.com/Beingpax/VoiceInk)（4.9k stars）但底层是 whisper.cpp，与用户已验证慢的 superwhisper 同一类，不优选

### 1.3 为什么不用 macOS 自带 Dictation（项目存在性论证）

机器现状探查 + 文档调研结论：自带 Dictation **结构上无法满足**核心场景，三道墙任一即否决：

1. **Claude Code 终端注入失败（决定性）**：cc CLI 基于 Ink/React/Yoga，进入 stdin **raw-mode** 后绕过 macOS 文本输入服务（NSTextInputContext / Accessibility insertText），Dictation 的注入路径被吃掉。同源问题：iTerm2、kitty、wezterm 全部有官方 issue 记录。Terminal.app 也只在非 raw-mode 下生效。
2. **中日不能同启**：Dictation 一次会话只能识别一种语言，要切换得手动点麦克风旁的语言图标。本机当前只下载了 `en-US` + `zh-CN`，**`ja-JP` 未安装**。
3. **无自定义词典**：自定义词汇是 Voice Control 独占功能，Dictation 没有。SwiftUI / SpeechAnalyzer / Tauri / Groq 这些技术词在中文模型下必被音译。

**MK 自写路径不撞墙的原因**：MK 用 NSPasteboard 写剪贴板 + CGEvent 模拟 ⌘V 按键，**走按键事件路径**而非 NSTextInputContext，raw-mode TUI 会正常接收按键 → 能成功注入 cc 输入框。这是 MK 与 Dictation 的根本架构差异，也是项目存在的核心理由。

---

## 2. 目标

### 2.1 核心目标
让用户在 **Claude Code 对话框**（以及任何 macOS 文本输入框）里通过**按住快捷键说话**完成输入，松开自动粘贴到光标位置。

### 2.2 成功度量
- **延迟**：从松开快捷键到文字落入输入框 ≤ **220ms**（详见 §2.3）
- **替代率**：上线 2 周后，与 cc 对话中**语音输入消息占比 > 60%**
- **用户主观**：识别准确度高于 superwhisper 体感（基线已删，对比靠记忆）
- **额外成本 = 0**：不订阅、不付费 API

### 2.3 三大硬约束（2026-05-09 加）

不是"达成更好"，是**项目存在的资格线**——任何违反的方案 P0 修 / P0 拒。

| # | 约束 | 指标 | 现状 |
|---|---|---|---|
| 1 | **低延迟** | 松开快捷键 → 落字 ≤ **220ms**（端到端 P95） | 字典 + ITN + filler + punct 全管线 < 50ms（pipeline 内）；SA 转写 80–90ms |
| 2 | **高性能** | 常驻内存 < 100MB · 二进制 ≤ 5MB（当前 **4.1MB**）· CPU 空闲 < 1% · 做到极致瘦身（无冗余依赖、无端侧 LLM） | 4.1MB zip 已达标；synth 字典 1071 → 296（-72%）已落地 |
| 3 | **高精度** | 字典域内召回率 ≥ **80%**（错例反馈闭环后）· 新错例 **3 次内**永久纠正 | mixed-corpus 实测 30% → 80%（learn 6 个错例后）|

**红线含义**：
- 延迟红线：用户明确「**240ms 是底线**」，220ms 是再收紧 20ms 的工作目标。任何端侧 LLM 后处理（qwen3:0.6b ~1s+）天然不可行，所以 C4 永久砍。
- 性能红线：「**世界词汇是无底洞，要节约不损耗**」——字典/synth/correction 都配硬上限（terms 800 / corrections 300）。
- 精度红线：MK 哲学「**我说什么，它越来越懂**」≠「它什么都懂」——飞书路线（自研大模型 + LLM 兜底）不在 MK 能力范围，但**第二次说同样词必对**是底线。

---

## 3. 用户画像

- 单一用户：本人
- 主力语言：**中文 + 日语**，英语一般
- 高频术语：技术词汇（Tauri / Groq / SwiftUI / SpeechAnalyzer / cc / PRD 等中英混杂）
- 设备：macOS 26.4.1 + Apple M5，常驻一台 Mac [TBD-2: 是否需要二三台？]

---

## 4. 核心场景

### S1（最高频）：cc 终端语音输入
1. 用户在 Claude Code 终端 prompt 框聚焦
2. 按住快捷键 → 状态栏图标变红开始录音
3. 说一段话："帮我用 SwiftUI 改下登录页的标题颜色为蓝色"
4. 松开 → 文字 ~300ms 内自动出现在 cc 输入框
5. 用户回车发送

### S2：跨 app 通用语音输入
- 浏览器地址栏、Slack、Notion、Markdown 编辑器等任何文本框，行为同 S1

### ~~S3~~（推迟到 Phase 2）
~~语音指令 → 标点 / 编辑~~
- **决议 2026-05-08**：MVP 不做任何符号转换 / 编辑指令。识别引擎出什么文本就注入什么文本，标点 / 删除让用户在 cc 输入框里手动改。
- 推迟理由：YAGNI。先验证核心管线（识别 + 注入）能不能跑通，符号转换是优化项不是阻断项。

### S4：中日英混杂
- 说"用 React 写个 component" → 完美保留 React / component 原文
- 说"今日は雨です。明天我去 GitHub 看 issue" → 中日英三语正确切换

### 反向场景（明确不做）
- ❌ 长录音（> 1 分钟）：不做会议转写
- ❌ 实时翻译：不做
- ❌ 跨设备同步：不做
- ❌ 命令式语音控制（"打开 Safari"）：不做

---

## 5. 功能需求

### FR1 全局快捷键
- 默认绑定：[TBD-4，候选：右 Option / Fn 双击 / Cmd+`]
- 按住录音、松开停止
- 可在偏好设置改

### FR2 流式语音识别
- 引擎：Apple **SpeechAnalyzer**（端侧）
- 默认 locale：`zh-CN`
- 中日英混杂：通过 `contextualStrings` 喂技术词典 [TBD-5：是否需要双 recognizer 并行？]
- 说话过程中实时显示部分结果（在悬浮窗或菜单栏 popover）

### FR3 自动注入
- 松开快捷键 → 取最终结果 → 写入 NSPasteboard → 模拟 ⌘V
- 注入位置 = 当前焦点光标处
- 不破坏用户原有剪贴板内容（注入后恢复）[TBD-6]

### ~~FR4~~ 后处理（**整个推迟到 Phase 2**）
- **决议 2026-05-08**：MVP 不做任何后处理。规则 + LLM 全部砍掉。
- Phase 2 再决定是否做（届时根据 MVP 实际使用痛点反推需求）。

### FR5 状态栏控件
- 菜单栏图标：🎤（待录音） / 🔴（录音中） / ⚪（处理中）
- 右键菜单：偏好设置、查看历史、退出

### FR6 历史记录（可选）
- 最近 N 条转写文本，方便复用
- 本地 SQLite，不上传 [TBD-8：要不要做？]

---

## 6. 非功能需求

| 维度 | 指标 |
|---|---|
| 延迟 | 松开快捷键到落字 **≤ 220ms（P95）**——硬约束，详见 §2.3 |
| 内存常驻 | < 100MB |
| CPU 空闲 | < 1% |
| 二进制大小 | **≤ 5MB**（当前 4.1MB，不含模型）——硬约束，详见 §2.3 |
| 字典召回率 | 域内 ≥ 80%（错例反馈闭环后）——硬约束，详见 §2.3 |
| 首次启动 | 首次需下载 SpeechAnalyzer 模型（苹果系统），用户感知一次 |
| 隐私 | 端侧 only，不联网（C4 LLM 后处理永久砍——见 §2.3 延迟红线） |
| 离线可用 | ✅ |
| 成本 | $0 |

---

## 7. 技术方案

### 7.1 已决策
| 决策 | 选项 | 理由 |
|---|---|---|
| 平台 | macOS 26+ | 用户机器 |
| 语言 | Swift | AppKit / Speech framework / 系统 API 全套 |
| 引擎 | SpeechAnalyzer | 比 SFSpeechRecognizer 新一代，端侧更快 |
| 后处理 | 规则优先，LLM 二期 | YAGNI |
| 模式 | 端侧 only | 用户态度："质量不好就不会用"，端侧足够 |
| 架构 | 菜单栏 NSStatusItem app | 不要 Tauri / Electron |

### 7.2 实施路径 [已决 2026-05-08：路径 B 实测通过]

**fork [Marvinngg/ambient-voice](https://github.com/Marvinngg/ambient-voice)** 加特化需求，**改名 MK**（com.lengmo.mk）。

#### M0 体检结果（2026-05-08）

| 红线 | 状态 | 说明 |
|---|---|---|
| **B1** 构建成功 | ✅ | Swift 6.3 严格并发触发 16 个错误，patch 2 处后通过：(1) Package.swift 加 `.swiftLanguageMode(.v5)` (2) `MeetingSession.swift:585` 加 `await` |
| **B2** 三个授权 | ✅ | 麦克风 / 语音识别 / Accessibility 全给到（Accessibility 不弹窗须手动去系统设置勾，已验证） |
| **B3** cc 输入框注入 | ✅ | 按住右 Option 说中文 → 松开 → 文字成功落入 cc 输入框，不乱位、不丢失 |
| **B4** 中文识别 | ✅ 体感通过 | 用户主观"很好成功了"（未做 5/5 量化测试） |
| **B7** 代码可读 | ✅ | VoicePipeline 60 行 / TextInjector 43 行 / 主流程一目了然 |

**加分项**：B5（中英混杂）/ B6（日语 ja-JP）/ B8（延迟）均**未量化测试**，留作 M1 日常使用反推。

#### M0 副产物决议
- **改名**：WE → MK（菜单栏显示 / Bundle ID com.lengmo.mk / 数据目录暂保留 ~/.we/ 不动）
- **裁剪推迟**：25 个不需要的文件（会议 / 远程 / distillation）暂不删，等使用中真碍事再裁
- **签名**：ad-hoc 签名跑通，Apple Developer 自签证书暂不做（每次 rebuild 要重授权，对体检阶段够用）
- **关闭 polish**：~/.we/config.json 写 polish.enabled=false（避免 Ollama 健康检查 spam 日志）

### 7.3 范围外
- ❌ Linux / Windows
- ❌ iOS 端
- ❌ 多用户 / 云同步

---

## 8. 待解决问题（TBD 集中）

| ID | 问题 |
|---|---|
| ~~TBD-1~~ | **[已决 2026-05-08]** Dictation 三道结构性墙不可用：(1) Claude Code Ink raw-mode 终端注入失败 (2) 中日不能同启 (3) 无自定义词典让技术词被音译。详见 §1.3。MK 走 NSPasteboard + CGEvent 路径绕开 raw-mode 墙。 |
| TBD-2 | 是否需要支持多台 Mac？同步怎么做？|
| ~~TBD-3~~ | **[已决 2026-05-08：推迟]** MVP 不做任何符号 / 编辑规则，原样注入识别结果。Phase 2 再视使用痛点决定。|
| TBD-4 | 全局快捷键默认绑哪个？|
| TBD-5 | 中英双 recognizer 并行 vs 单 recognizer + contextualStrings 哪个体验好？|
| TBD-6 | 注入后是否恢复原剪贴板？|
| ~~TBD-7~~ | **[已决 2026-05-08：推迟]** FR4 整个推迟，TBD-7 自动关闭。|
| TBD-8 | 历史记录功能要不要做？|
| ~~TBD-9~~ | **[已决 2026-05-08]** 路径 B（fork ambient-voice）。子前提见 §7.2 TBD-B1~B4。 |

---

## 9. 里程碑（暂定路径 B 或 C）

- ~~M0~~ **[完成 2026-05-08]** 体检通过，路径 B 确认，改名 MK
- **M1 MVP（进行中）**：在 cc 终端日常用 1 周，记录痛点（识别准确度 / 中英混杂 / 日语 / 延迟 / 注入异常等）
- **Phase 2（按 M1 痛点反推）**：FR4 后处理 / FR6 历史记录 / 裁剪不需要的文件 / 自签名证书避免重授权等
- **每个里程碑验收**：手测 cc 对话框场景，能正常出字 + 不串扰其他 app

---

> **下一步**：用 `/grill-with-prd` 拿这份 PRD 反过来拷问当前方案，重点是 §8 的 9 个 TBD。
