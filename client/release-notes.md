# MK v0.3.0 — 算法三剑客 + 学习模式 + 流式注入 + 大瘦身

> 个人语音输入 macOS 工具，端侧 only · 0 联网 · 0 订阅。按住右 Option 说话 → 文字落到光标。

## 核心更新

### 算法 A/B/C — 字典模糊匹配三剑客

不再靠手工堆错音变体。三层算法自动覆盖：

| 算法 | 解决什么 | 例子 |
|---|---|---|
| **A · 拼音哈希** | 中文同音字 | 流市/流氏/流逝/留时/柳市 → 全归"流式" |
| **B · 短语 token Levenshtein** | 英文短语错音 | "Even Lop" → "event loop" |
| **C · Metaphone 音相似** | 英文单词错音 | "depsec" → "DeepSeek" |

dict 里只放正字一条，其他变体由算法自动覆盖。

### 学习模式（默认开）

注入 30s 内 hook Accessibility API 读目标 app 文本 → 中文分词 → LCS 对齐 → 抽 (raw, corrected) pair → 自动入字典。下次说同样的词不再错。

支持 Notes / Safari / 有道云笔记 等支持 AX 的 app。cc 终端 raw mode 受限。

### 分块流式注入（菜单 toggle，默认关，仅 Notes/文档类）

主动每 2s 重启 SA + 原子切换音频流 → 长句说话期间陆续看到文字（飞书风格）。松手时用 WAV 整段重处理拿干净 ground truth + 算法纠错一次性大刷新。

cc 终端 raw mode backspace 不可靠，建议关；Notes/文档类可用。

### 落字延迟 700ms → 150ms

砍掉 `session.stop()` 里写死的 500ms 兜底 sleep，换成 `await resultTask.value` 精确等 SA result drain。**§2.3 ≤220ms 红线达成**。

### 包体 13MB → 1.7MB

删除 ambient-voice fork 来的会议模式（含 FluidAudio 30MB 模型权重）+ Ollama LLM 客户端 + 一堆 dev-only CLI 测试。**§2.3 ≤5MB 红线超额达成**。

## 其他改动

- **Gate V0**：每次替换记录 confidence + reason；默认阈值 0（不改行为，下版可调起来过滤低信心替换）
- **句号过频降级**：「。」紧跟 CJK 字 → 自动改「，」（SA 中文模型每停顿都加假句号的副作用）
- **2-rep 口吃压缩**：FillerRemover 压"直接直接/其实其实"等 2 次重复
- **⌘V throttle**：1s 内 ≥20 次 paste 自动跳过（防 chunk bug 灌爆 iTerm）
- **dict mtime 缓存**：每次录音前文件没变直接 skip（省 ~10ms）

## 字典

字典扩到 ~970 词条：
- 16 个 流式 同音字变体（之后 算法 A 上线后可不用手维护）
- 27 个高频技术同音字（异步/缓存/索引/部署/调试 等）
- 27 个 JS 生态词（Node.js / event loop / TypeScript / async / Promise / React 等）
- 14 个键盘按键名（Option/Cmd/Shift/Control/Tab/Delete 等）
- 之前已有的 Pi-zero / DeepSeek / AppLovin 等

## 菜单瘦身

只剩 4 项（之前 11 项）：

```
MK 语音输入
─────
流式注入（实验，仅 Notes/文档类）
学习模式（注入后 30s 自动学）  ✓
─────
设置热键... (Right Option)
─────
退出
```

删掉了：会议菜单 / 服务器状态 / 模型 / 检查连接 / 编辑配置 / 数据目录 / 查看日志（这些都用不上 + 本来就没几个人会点）。

## 系统要求

- macOS 26+（SpeechAnalyzer 需要）
- Apple Silicon
- 系统设置已下载 zh-Hans / zh-CN 语音模型

## 安装

下载 `MK-v0.3.0.zip` → 解压 → 拖 `MK.app` 到 `/Applications/` → 右键打开（自签必须）→ 授权麦克风 / 语音识别 / 辅助功能。

## 升级注意

从 v0.2.0 升级：dict / config 文件位置不变，直接覆盖 .app 即可。Accessibility 权限可能需要重新授权一次（每次自签 cert 变化都会触发）。

## 已知限制

- cc 终端 raw mode 下流式注入的 backspace 不可靠（推荐关流式）
- 学习模式在 cc 终端读不到完整文本（cc 输入框累积历史 49K+ 字，超出 800 字窗口）
- SA zh-CN 模型不在说话过程中 emit volatile / final 段（结构性物理墙；流式靠主动重启 SA 补足）

## 下一步

- 算法 D：拼音 → 英文反向查表（"youbushen" → Option，跨字符集纠错）
- Gate V1：把 confidence 阈值开到 0.5+，开始过滤低信心替换
- 学习模式三元组：(before, after, kept) 类 DPO 对比信号
- Apple Developer ID 签名（$99/年免每次右键 Open）

---

> 完整开发记录见 `docs/sessions/2026-05-09-recap.md` / `2026-05-09-evening.md` / `2026-05-10-recap.md`
