# 从源码编译 / 开发

## 环境要求

- macOS 26+（SpeechAnalyzer 需要）
- Apple Silicon（M 系列；Intel 没测）
- Swift 6.3+（Xcode 26+）
- 系统设置已下载 zh-Hans / zh-CN 语音模型

## 首次编译

```bash
git clone https://github.com/GuinsooRocky/mk.git
cd mk/client
bash scripts/setup-cert.sh        # 创建自签名 "MK Development" 证书（一次）
swift build
cp .build/debug/MK .build/MK.app/Contents/MacOS/MK
codesign --force --deep --sign "MK Development" .build/MK.app
open .build/MK.app
```

首次启动 macOS 会提示授权：**麦克风 / 语音识别 / 辅助功能**——全部允许。

自签证书优先于 ad-hoc：rebuild 不丢 TCC 授权，不用每次重授权。

## 日常开发循环

```bash
cd client
swift build
cp .build/debug/MK .build/MK.app/Contents/MacOS/MK
codesign --force --deep --sign "MK Development" .build/MK.app
killall MK; open .build/MK.app                       # 重启验证
```

调试日志：`tail -f ~/.mk/debug.log`

改纠错逻辑前后必跑 `MK --eval-corpus` 做回归（见 `docs/correction-roadmap.md`）。

## SenseVoice 模型（源码用户）

```bash
bash client/scripts/download-model.sh   # 拉 ~230MB 模型到 ~/.mk/models/
```

## config.json 完整字段

```json
{
  "server": { "endpoint": "http://localhost:11434", "api": "ollama", "model": "qwen3:0.6b" },
  "polish": {
    "enabled": false,
    "engine": "sa",
    "live_segment_enabled": true,
    "context_dictionary_enabled": true,
    "context_dictionary_path": "~/.mk/correction-dictionary.txt",
    "context_dictionary_paths": ["~/.mk/correction-dictionary-codebase.txt"],
    "context_ocr_enabled": false,
    "fr4_punctuation_enabled": true
  }
}
```

| 字段 | 说明 |
|---|---|
| `polish.enabled` | LLM 后处理（暂不启用，qwen3:0.6b 效果差） |
| `engine` | 最终识别引擎：`sa`(Apple，出厂默认) / `sensevoice`(本地多语种离线) / `tencent`(腾讯一句话，需 `tencent_secret_id`+`tencent_secret_key`) / `groq` |
| `live_segment_enabled` | 说话时本地 SenseVoice VAD 边说边出，实时刷浮窗 HUD（仅预览，不影响最终注入） |
| `stream_provider` | 实时流式 provider（**可选**，砍松手后等待）：`soniox`(需 `soniox_api_key`+`soniox_region`) / `tencent`(需 `tencent_appid`，境外有跨境限制)。**不设=不走流式**，用一句话识别。见 `docs/realtime-asr-decision.md` |
| `context_dictionary_enabled` | 字典 hint + 反向纠错 |
| `context_dictionary_path` | 用户主字典 |
| `context_dictionary_paths` | 额外字典数组（codebase 扫生成等） |
| `context_ocr_enabled` | OCR 屏幕术语自动入 hint（需屏幕录制权限，默认关） |
| `codebase_scan` | 启动时后台扫码 → 自动生成字典；详见 `docs/dictionary.md` |
| `fr4_punctuation_enabled` | 中文口语 → 标点（`换行 → \n`、`句号 → 。` 等） |

> 菜单栏切引擎只在「云端 / 本地」两档间循环；要切回出厂默认的系统识别，手改 `engine` 为 `"sa"`。

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

### 为什么 macOS 自带 Dictation 进不了 Claude Code 终端

1. **注入路径被吃掉（决定性）**：cc CLI 基于 Ink/React/Yoga，进入 stdin **raw-mode** 后绕过 `NSTextInputContext / Accessibility insertText`，Dictation 的注入路径失效。同源问题：iTerm2 / kitty / wezterm 全部有官方 issue 记录
2. **中日不能同时启用**：Dictation 一次只能识别一种语言
3. **无自定义词典**：自定义词汇是 Voice Control 独占功能；Dictation 听到 SwiftUI / Tauri / Groq 必音译

MK 走 **NSPasteboard 写剪贴板 + CGEvent 模拟 ⌘V** 的**按键事件路径**，不依赖 NSTextInputContext。raw-mode TUI 会正常接收按键 → 文字成功注入 cc 输入框。这是 MK 与 Dictation 的根本架构差异。
