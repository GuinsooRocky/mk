# Roadmap / Backlog

## 已完成（v0.3–v0.4）

**算法 / 字典**
- [x] **算法 A 拼音哈希** — CFStringTransform 把字典中文 term 转拼音建反向索引；同音字（流市/流氏/留时...）自动归正字
- [x] **算法 B 短语 Levenshtein** — 多 token 英文短语错音（Even Lop → event loop）
- [x] **算法 C Metaphone** — 英文单词音相似度（depsec → DeepSeek）
- [x] **Gate V0** — 每次替换记 confidence + reason；下版可调阈值过滤低信心
- [x] 字典自动生长（启动后台 scan + mtime 缓存）+ 错例反馈 CLI + 圈子领域包
- [x] L1 single-pass + word boundary + L2 内置 ~500 高频词白名单 + synth 排除 stop words

**学习 / 注入**
- [x] **学习模式 V1** — 注入 30s 内 hook AX 读目标 app 文本 → 中文分词 → LCS → 自动入字典
- [x] **转写浮窗 HUD** — 说话时实时刷字；注入成功即 0.15s 收起，定稿只落目标 app 不回显；目标 app 只收最终文本一次（终端 PTY 不可回改，故实时体验全在 MK 自己的浮窗里）
- [x] **⌘V throttle** — 1s ≥20 次 paste 自动跳过，防 chunk bug 灌爆 iTerm
- [x] **句号过频降级** — 「。」+ CJK → 「，」，治 SA 假句号
- [x] **2-rep 口吃压缩** — "直接直接/其实其实" 自动压一次

**多引擎 / 实时流式**
- [x] **可切识别引擎** — `sa` / `sensevoice`(本地离线多语种) / `tencent`(一句话识别) / `groq`，菜单栏切换
- [x] **本地 live 预览** — SenseVoice + silero VAD 边说边出，刷浮窗 HUD（默认 hybrid：本地 live 预览 + 云一句话定稿）
- [x] **实时流式 provider 架构**（可选）— `StreamingSession` 协议 + Soniox/腾讯实时引擎，边录边传把松手后等待从 ~0.8s 砍到 ~0.3s；config `stream_provider` 一键开关，详见 `docs/realtime-asr-decision.md`

**性能 / 包体**
- [x] **落字延迟 700ms → 150ms** — 砍 stop() 里 500ms 兜底 sleep，换 await drain
- [x] **包体 13MB → 1.7MB** — 删会议/LLM/FluidAudio/dev CLI

## 下一步

- [ ] **算法 D 拼音→英文反查** — youbushen → Option 跨字符集纠错
- [ ] **Gate V1 调起阈值** — confidence < 0.5 过滤低信心替换
- [ ] **学习模式三元组** — (before, after, kept) 类 DPO 对比信号
- [ ] **预制领域包**：科技 / 前端 / 后端 / AI / 产品 / PM / 设计 / 投资 等 starter pack
- [ ] **首启引导问卷**：「你做什么？」→ 自动启用对应圈子
- [ ] **错例反馈 GUI**：菜单栏「最近学了 N 个词」review 面板
- [ ] **iCloud sync learned 字典**：多设备共用
- [ ] **Apple Developer ID 签名**：$99/年，免每次右键 Open

## 仍 backlog

- [ ] LLM 后处理 — 等找到合适端侧本地模型（MK 哲学：尽量不上 LLM）
- [ ] OCR 屏幕术语自动 hint — 需用户授权屏幕录制
- [ ] 日语 ja-JP 支持
- [ ] 真英文段落识别 — SA zh-CN 模型对纯英文段落输出乱码（不在 MK 目标场景）

## 已知限制 / 适用边界

**MK 目标场景**：「中文为主 + 偶尔英文术语」（如 `用 SwiftUI 写 PlusIcon`、`DeepSeek 论文里的 sparse attention`）。

**不在能力范围**：
- **真英文段落**：SA zh-CN 对纯英文采访输出乱码（"Weally trinomaket super easy..."），字典救不了。如需要全英场景，将来切 en-US locale
- **中文同音错**："拍戏" vs "派系" — 字典只管反向英文纠错，不管中文
- **SA zh-CN 模型不出英文候选**：依赖 contextualStrings hint + 应用层后处理，不能从 alternatives 拿英文原文
- **音译解构难救回**：SA 把 `SwiftUI` 拆成 `swit fut UI` 三个 token 时，需要 manual `|` 登记（用 `MK --learn`）
- **不支持 session 内切换 locale**：日 / 英为主时要在配置里改默认 locale + 装对应模型
- **不能复刻飞书 ASR 准确率**：飞书是自研大模型 + 海量训练 + LLM 后处理；MK 是 Apple SA + 应用层字典 + 端侧零依赖

**核心判断**：MK 不上 LLM（纠错层）、默认不上云。能解的是「我说什么，它越来越懂」（学习 organic）；不解的是「全世界词汇都识别」（飞书路线）。
