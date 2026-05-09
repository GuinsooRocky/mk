# MK — macOS 端侧语音输入

> 按住 `右 Option` 说话，松开 → 文字落到光标位置。**任何 app 都行**，包括 Claude Code 终端。
>
> 端侧 only · 0 联网 · 0 订阅 · 中文为主、英文技术词不被音译。

基于 Apple **SpeechAnalyzer**（macOS 26 新 API）+ 应用层字典纠错。Fork 自 [ambient-voice](https://github.com/Marvinngg/ambient-voice)，重命名 + 重做识别管线。

---

## ⬇️ 直接下载（v0.2.0）

[**📦 MK-v0.2.0.zip（4.1MB）→ 点击下载**](https://github.com/GuinsooRocky/mike/releases/download/v0.2.0/MK-v0.2.0.zip)

> 全部 release 列表：[github.com/GuinsooRocky/mike/releases](https://github.com/GuinsooRocky/mike/releases)

### 首次安装 3 步（自签 Gatekeeper 绕过）

1. **解压** zip → 拖 `MK.app` 到 `/Applications/`
2. **右键** MK.app → **打开** → 弹窗选「**仍要打开**」（自签必须，之后正常双击）
3. 系统设置 → 隐私与安全性 → 授权 **麦克风 / 语音识别 / 辅助功能**

按住 **右 Option** 说话，松开 → 文字落到光标。

> ⚠️ Gatekeeper 提醒：本 .app 是 **MK Development 自签**，不是 Apple Developer ID。Mac 直接双击会被拦——**必须右键 Open** 走人工授权。
> 要彻底解决需要 Apple Developer ID（$99/年），暂未做。

---

## 为什么有这个项目

### 痛点

每天在 Claude Code 终端打字 ~300+ 条消息，手累。市面方案都不行：

| 方案 | 问题 |
|---|---|
| superwhisper | 慢（1–2s）+ 收费 + 识别不准 |
| macOS 自带 Dictation | **三道结构性墙**（见下） |
| 飞书 / 微信内置语音 | 仅自家 app，不能注入到 cc 终端 |
| VoiceInk（4.9k stars） | 底层 whisper.cpp，跟 superwhisper 同类，慢 |

### 为什么自带 Dictation 不行

1. **Claude Code 终端注入失败（决定性）**：cc CLI 基于 Ink/React/Yoga，进入 stdin **raw-mode** 后绕过 `NSTextInputContext / Accessibility insertText`，Dictation 的注入路径被吃掉。同源问题：iTerm2 / kitty / wezterm 全部有官方 issue 记录
2. **中日不能同时启用**：Dictation 一次只能识别一种语言
3. **无自定义词典**：自定义词汇是 Voice Control 独占功能；Dictation 听到 SwiftUI / Tauri / Groq 必音译

### MK 怎么绕开

走 **NSPasteboard 写剪贴板 + CGEvent 模拟 ⌘V** 的**按键事件路径**，不依赖 NSTextInputContext。raw-mode TUI 会正常接收按键 → 文字成功注入 cc 输入框。这是 MK 与 Dictation 的根本架构差异。

---

## 工作原理（一图）

```
按住 右 Option
   ↓
   ├── 锁定当前焦点 app
   ├── 加载字典（用户字典 + codebase 自动扫，启动时预加载）
   ├── 注入字典词到 SpeechAnalyzer.contextualStrings (≤1000)
   └── 开始录音 + SA 端侧实时识别
   ↓
松开 右 Option
   ↓
   原始 ASR 输出
   ↓
   Layer 1: 字典精确替换（C2 反向纠错 + C5 派生）
   ↓
   Layer 2: Levenshtein 模糊兜底（单字符/拆词差异）
   ↓
   FR4 标点 normalizer（中文口语 → 全角标点）
   ↓
   NSPasteboard + ⌘V → 注入光标
```

---

## 系统要求

- macOS 26+（SpeechAnalyzer 需要）
- Apple Silicon（M 系列；Intel 没测）
- 系统设置已下载 zh-Hans / zh-CN 语音模型
- Swift 6.3+（Xcode 26+）

---

## 安装

### 方式 A：下载预编译版（普通用户）

直接看本页顶部 [⬇️ 直接下载](#-直接下载v020) — 解压 + 右键 Open + 授权。

### 方式 B：从源码编译（开发者）

```bash
git clone https://github.com/GuinsooRocky/mike.git
cd mike/client
bash scripts/setup-cert.sh        # 创建自签名 "MK Development" 证书（一次）
swift build
cp .build/debug/MK .build/MK.app/Contents/MacOS/MK
codesign --force --deep --sign "MK Development" .build/MK.app
open .build/MK.app
```

首次启动 macOS 会提示授权：**麦克风 / 语音识别 / Accessibility**——全部允许。

---

## 使用

按住 **右 Option** 说话，松开 → 文字粘贴到当前光标。

录音状态 = macOS 系统橙点（菜单栏右上）。MK 自己不闪烁，菜单栏始终显示粗体 `MK`。

---

## 字典管理（核心 feature）

### 文件位置

```
~/.we/correction-dictionary.txt          ← 你手维护（109 词起步）
~/.we/correction-dictionary-codebase.txt ← scan-codebase.py 自动扫生成（300 词）
~/.we/config.json                        ← 在 polish.context_dictionary_paths 列出
```

### 手维护字典格式（.txt）

```
# 一行一词
SwiftUI
PlusIcon
SVG

# 带「错音 → 正字」映射（| 分隔）
SwiftUI | Swift U I | swit fut UI
PlusIcon | Plus I can | plus I cn
SVG | SAG | SVJ

# # 开头是注释，空行忽略
```

### 自动扫 codebase

```bash
client/scripts/scan-codebase.py \
  --top 300 --min-freq 3 \
  --out ~/.we/correction-dictionary-codebase.txt \
  ~/Desktop/my-code ~/Desktop/cmm
```

扫指定根目录的 `.swift / .ts / .tsx / .py / .rs`，正则抓**驼峰 + 全大写缩写**，按频率排序。
排除 `node_modules / .git / .build / dist` 等噪音目录。

### 三层纠错

1. **C2 精确替换**（手维护的 `|` 错音映射，长词优先）
2. **C5 自动派生**（加载时一次性派生：`SVG` → `SAG / SVJ / SBG / S V G` 等基于字符混淆表）
3. **Levenshtein 模糊兜底**（单字符 / 拆词差异，如 `SVJ→SVG`、`Tlwind→Tailwind`）

加载时全套 < 50ms；运行时 correct() < 1ms。

### 实测延迟数据

| contextualStrings 数量 | 转写耗时 |
|---|---|
| 0 (baseline) | 210ms |
| 50 | 80ms |
| 100 / 500 / 1000 / 5000 | 90ms |

Apple 文档建议 ≤100，但**实测 5000 词跟 100 词同延迟**——SA 内部用 O(1)/O(log n) 索引，"100" 是效果建议非性能约束。MK 已放宽上限到 **1000**。

---

## 配置 `~/.we/config.json`

```json
{
  "server": { "endpoint": "http://localhost:11434", "api": "ollama", "model": "qwen3:0.6b" },
  "polish": {
    "enabled": false,
    "context_dictionary_enabled": true,
    "context_dictionary_path": "~/.we/correction-dictionary.txt",
    "context_dictionary_paths": ["~/.we/correction-dictionary-codebase.txt"],
    "context_ocr_enabled": false,
    "fr4_punctuation_enabled": true
  }
}
```

| 字段 | 说明 |
|---|---|
| `polish.enabled` | LLM 后处理（暂不启用，qwen3:0.6b 效果差） |
| `context_dictionary_enabled` | 字典 hint + 反向纠错 |
| `context_dictionary_path` | 用户主字典 |
| `context_dictionary_paths` | 额外字典数组（codebase 扫生成等） |
| `context_ocr_enabled` | OCR 屏幕术语自动入 hint（需屏幕录制权限，默认关） |
| `fr4_punctuation_enabled` | 中文口语 → 标点（`换行 → \n`、`句号 → 。` 等） |

---

## 已知限制

- **SA zh-CN 模型不出英文候选**：依赖 contextualStrings hint + 应用层后处理，不能从 alternatives 拿英文原文
- **音译解构无法救回**：SA 把 `SwiftUI` 拆成 `swit fut UI` 三个 token 时，Levenshtein 距离都 > 阈值。需要未来 LLM 后处理（C4，已 backlog）
- **不支持 session 内切换 locale**：日语 / 英语为主时不能直接切；要在配置里改默认 locale + 装对应模型
- **不能复刻飞书 ASR 准确率**：飞书是自研模型 + 海量训练数据 + 专门团队，我们是 Apple SA + 应用层补救

---

## Roadmap / Backlog

- [ ] LLM 后处理（C4）— 等找到合适本地模型（不用 qwen3:0.6b）
- [ ] 字典自动生长改进 — scan-codebase.py 启动时后台跑 + 缓存
- [ ] OCR 屏幕术语自动 hint — 需用户授权屏幕录制
- [ ] 日语 ja-JP 支持 — 装系统语言包 + 改 locale 选择逻辑
- [ ] SA hint 1000 上限准确率实测 — 验证大字典下识别质量
- [ ] 用户反馈闭环 — 识别错的让用户改正后入字典

---

## 开发

```bash
cd client
swift build                                          # 编译
cp .build/debug/MK .build/MK.app/Contents/MacOS/MK
codesign --force --deep --sign "MK Development" .build/MK.app
killall MK; open .build/MK.app                       # 重启验证
```

调试日志：`tail -f ~/.we/debug.log`

---

## License

MIT
