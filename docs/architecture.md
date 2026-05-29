# MK 技术架构（当前态）

> 单文件当前态，过期即改、不堆历史 recap。
> MK = macOS 菜单栏语音输入工具（push-to-talk 听写），主要给 Claude Code / 终端做中文+英文术语语音输入。
> 客户端 Swift 6 / macOS 26；服务端 Python（蒸馏/微调，离线、与客户端解耦）。

## 一句话数据流

```
按住右 Option → AVCaptureSession 采音 → SpeechAnalyzer 实时转写 + 落 WAV
   松手 → 选定引擎重转（SA / SenseVoice / Groq）→ L1 纠错管线 → 注入输入框 → 30s 学习回扫
```

不再有：会议模式 / 说话人分离（FluidAudio）/ 端侧 LLM 润色（PolishClient·ModelServer）——
这些早期 "WE" 时代的能力已全部移除，MK 专注听写。延迟红线见 `PRD.md §2.3`（松手→落字 ≤220ms，端侧 LLM 后处理永久砍）。

## 听写主流程（Dictation）

### 触发与状态机
- `GlobalHotKey`（CGEventTap，纯 C 回调，绕开 macOS 26 的 `NSEvent.addGlobalMonitor` Bus error）监听右 Option。
- `ModuleManager` 路由热键事件到 `VoiceModule`（状态机：idle → recording → processing → idle）。
- `AmbientController`（CoreAudio HAL VAD 免按手）默认关；开启后复用同一录音管线。

### 录音与实时转写（VoiceSession）
1. `AVCaptureSession` + `AVCaptureAudioDataOutput` 采音（兼容蓝牙——`AVAudioEngine.installTap` 在蓝牙设备上不触发回调）。
2. `SpeechAnalyzer`（WWDC 2025，端侧）流式转写，`reportingOptions: [.volatileResults, .alternativeTranscriptions]`，词级置信度 + 时间戳。模型 `processLifetime` 常驻，热键间不卸载。
3. `AudioCaptureDelegate` 把每个 `CMSampleBuffer` 转 16kHz Int16 mono，喂给 SA 的 `AsyncStream`，同时手动写 WAV（绕开 `AVAudioFile` 内部 AudioConverter 的 abort 崩溃）。
4. `ContextEnhancer` 把纠错字典术语 +（可选）屏幕 OCR 关键词作为 `contextualStrings` 注入 SA，偏置专名识别（实测 ≤1000 项不影响延迟）。

### 松手处理（VoiceModule.stopAndProcess）
1. `session.stop()` → SA finalize（5s 超时兜底）→ 拿 SA 全文 `result.fullText` + WAV 路径。
2. **引擎切换**（`config.polish.engine`，SA 全程跑保底，引擎失败永远回落 SA，不让用户空手）：
   - `sensevoice`：`SenseVoiceEngine` 本地 sherpa-onnx 原生离线转写（**选定方向**）。
   - `groq`：`GroqEngine` 云端 Whisper。
   - `sa` / 未设：直接用 SA 全文。
3. **L1 纠错管线**（`VoicePipeline.correctText`，全程 <50ms，无 LLM）：
   `CorrectionDictionary.correct`（多层 L1→L2→L4→L5→L6→L3，含保护词 / learned / 领域字典 / codebase 扫词）
   → `NumberNormalizer`（中文数字 ITN）→ `FillerRemover`（去口头禅）→ `PunctuationNormalizer`（口语词转标点 + 智能括号配对 + 句号降级 + 砍松手尾句号）。
4. **注入**（`TextInjector`）：默认剪贴板 + `Cmd+V` 单次注入，0.5s 后恢复剪贴板；实验性流式 diff 注入（菜单可开，默认关，cc 终端 backspace 不可靠）。
5. **学习回扫**（`CorrectionCapture`）：注入后开 30s 窗口，靠 Accessibility API 读回聚焦控件文本，对比 injected 抽取用户改动 → `CorrectionStore`（喂回 L1 字典 + 蒸馏训练数据）。cc 终端 raw mode 读不到时走 cc-hook pending-learn-prompt 旁路。
6. **历史落盘**（`VoiceHistory`）：每次会话 → `~/.mk/voice-history.jsonl`（SA 原文 / L1 文本 / 终文 / 词级信息 / 音频路径），蒸馏管线主输入。

### SenseVoice 引擎（本地离线，sherpa-onnx 原生）
- 无 Python、无后台进程；模型 `~/.mk/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/model.int8.onnx` 常驻内存，加载与推理在专用串行队列，不阻塞主线程。
- **松手后整段转写**；SenseVoice 是 NAR 离线模型，整段塞超长音频会延迟暴涨且中段塌掉（只剩头尾）。
- **长音频 VAD 切段**（>10s 才触发，短句保持原整段解码）：silero VAD（`~/.mk/models/silero_vad.onnx`）按自然停顿 + 10s 强切上限切成短段，逐段解码再拼接，每段都留在模型舒适区。VAD 模型缺失则优雅回落整段解码。
- 模型不随 release 打包（保持 .app 小巧，约 28MB dylib）；首次用本地引擎前跑 `scripts/download-model.sh`（下 SenseVoice ASR + silero VAD）。

### 远程接收（RemoteInbox）
- `NWListener`（Network.framework，零第三方依赖）监听 HTTP，接收 Windows 侧 Tailscale 发来的 WAV：`POST /transcribe` → 临时文件 → SpeechAnalyzer 文件输入 → `VoicePipeline` → `TextInjector`。
- 默认关；`remote.auth_token` 为空拒绝启动（无鉴权监听口=安全风险）。

## 音频管线要点
- **AVCaptureSession 而非 AVAudioEngine**：后者 `installTap` 在蓝牙（HFP/SCO 或非标采样率）上回调不触发、无报错。
- **格式转换**：采集格式 ≠ SA 格式时惰性建 `AVAudioConverter`（block 版 `convert(to:error:)`，支持采样率转换）。
- **手动 WAV 写入**：44 字节占位 header → 追加 PCM → 收尾回填 RIFF/data size；绕开 `AVAudioFile` 的 AudioConverter abort。
- **CGEventTap 全局热键**：回调在 `CFRunLoop` 上下文（Swift runtime 不认作 MainActor），所有 `@MainActor` 代码经 `DispatchQueue.main.async` 桥接。

## 关键组件

| 源文件 | 角色 |
|---|---|
| `WEApp.swift` | 入口 `AppDelegate`；菜单栏 app + 多个 CLI 模式（`--eval-corpus` / `--eval-gate` / `--sense-voice-test` / `--learn` / `--test-pipeline` / `--test-dict-correct` / `--test-codebase-scan` / `--trim`·`--concat` / `--uninstall`） |
| `WEModule.swift` / `ModuleManager.swift` | 输入模块协议（`onHotKeyDown/Up`）+ 热键路由 |
| `VoiceModule.swift` | 听写状态机；松手后编排 引擎切换 → L1 → 注入 |
| `VoiceSession.swift` | AVCaptureSession 采音 + SpeechAnalyzer 流式转写 + 手动 WAV；含实验性 chunk 流式 + WAV 整段重处理 |
| `SenseVoiceEngine.swift` | sherpa-onnx 原生 SenseVoice 离线引擎 + silero VAD 长句切段 |
| `GroqEngine.swift` | Groq 云端 Whisper 引擎 |
| `SherpaOnnx.swift` | sherpa-onnx C API 的 Swift 绑定（vendored 样板，含 OfflineRecognizer / VAD） |
| `GlobalHotKey.swift` | CGEventTap 全局热键（右 Option toggle + Enter 检测） |
| `HotKeyConfig.swift` / `HotKeySettingsWindow.swift` / `HotKeyConflictChecker.swift` | 热键自定义 + 冲突检测 |
| `AmbientController.swift` | CoreAudio HAL VAD 免按手（默认关） |
| `ContextEnhancer.swift` | 组装 SA `contextualStrings`（字典术语 + 可选 OCR） |
| `ScreenContextProvider.swift` | ScreenCaptureKit 截窗 + Vision OCR 提关键词 |
| `CorrectionDictionary.swift` | 多层纠错字典（保护词 / learned / 领域 / codebase），见 `correction-roadmap.md` |
| `CorrectionCapture.swift` / `DictionaryLearner.swift` | 注入后 AX 回扫学用户改动 → 入字典 |
| `NumberNormalizer.swift` / `FillerRemover.swift` / `PunctuationNormalizer.swift` | L1 数字 ITN / 去口头禅 / 标点 |
| `TextInjector.swift` | 剪贴板 + `Cmd+V` 注入（单次 / 实验流式） |
| `StreamingInjector.swift` | 实验性流式 diff 注入（默认关） |
| `RemoteInbox.swift` | Tailscale 远程 WAV 接收 → SA → 注入 |
| `RuntimeConfig.swift` | `~/.mk/config.json` 加载 + 文件监视热更新 |
| `VoiceHistory.swift` / `JSONLWriter.swift` | 会话历史落盘（蒸馏输入） |
| `CorpusEval.swift` / `GateEval.swift` | `--eval-corpus` / `--eval-gate` 回归评测 |
| `CodebaseScanner.swift` | 扫本地代码库自动提术语进字典 |
| `StatusBarController.swift` / `PermissionManager.swift` / `AppIdentity.swift` / `Logger.swift` / `WEDataDir.swift` / `Uninstaller.swift` | 菜单栏 UI / 权限 / 前台 app 识别 / 日志 / `~/.mk` 目录 / 卸载 |

## 服务端（蒸馏 + 微调，离线、与客户端解耦）

| 文件 | 角色 |
|---|---|
| `gen_distill_gemini.py` | Gemini 2.5 Flash 纠正 SA 输出，生成蒸馏对 |
| `gen_training_data.py` / `merge_pairs.py` | 组装训练数据（人工纠正优先级最高） |
| `train_qlora.py` | QLoRA 微调 Qwen3-0.6B |
| `eval_model.py` | 评测：fix rate / break rate / identity rate / CER |
| `eval/` | 评测脚本 + 历史 benchmark 结果转储（多为 "WE" 会议模式时代产物，可清理） |

数据闭环：客户端 `voice-history.jsonl` + 人工 `corrections.jsonl` → 蒸馏对 → 训练数据 → QLoRA → 评测。
