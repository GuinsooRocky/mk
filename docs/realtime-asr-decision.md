# 实时流式 ASR 提效 & 选型决策

> 当前态决策文档（覆盖更新，不堆历史）。下次纠结「要不要/用哪家实时流式」直接读本文。
> 最后更新：2026-06-10（人在东京 🇯🇵；本日跑了 29-agent 全网调研 + 对抗核查，数字均经官方定价页二次核实）

## ✅ 实际落地（2026-06-10 收工）：免费 hybrid（本地 live + 腾讯一句话）

用户最终立场：**「HUD 有实时预览就够，松手后 cc 出字晚 0.8s 不烦」**。既然不追求砍那 0.8s，就**不需要流式/Soniox**：

```
按住键 ──说话中──→ 松手 ──腾讯一句话 ~0.8s──→ cc 出字
        HUD: 本地 SenseVoice live          HUD: 覆盖成定稿
```

- HUD interim = 本地 SenseVoice live（`live_segment_enabled:true`，免费/离线/全是自己代码）
- 最终注入 = 腾讯一句话识别（`engine:tencent`，5000 条/月免费、**东京可达**）
- 关键：**「5000 条 → 5h」改不了**——5h 是腾讯*实时流式*，东京直连撞 `6001` 跨境墙（见下「已踩死的坑」）；它跟一句话识别是两个产品，不是套餐切换
- 零付费、零新依赖、零跨境风险

**流式（Soniox/腾讯）= 休眠升级档**：只在「想把松手后 0.8s 砍到 ~0.3s」时才需要。代码已就绪（多 provider 架构），config 加 `stream_provider` 即活。详见下「最终决策」与「工程接入」节——内容仍有效，作为升级备查。

---

## （备查）若要砍 0.8s → 上流式：Soniox stt-rt-v4（JP 区）

用户最终目标收敛为：**全球可用 + 快 + 实时展示后刷新**，预算放宽到 ≤¥5/h（很宽）。三点全中的是 **Soniox**：
- **全球可用**：US/EU/JP 三区 sovereign cloud，一个账号全球可用；选 JP 端点东京本地最快、数据留东京（书面 data-residency）
- **快**：东京本地机房 ≈ 同城延迟
- **实时展示后刷新**：原生 token `is_final` 模型——非 final = 实时展示，松手 `finalize` 翻 final = 刷新定稿
- **中英混说全场最强**：自报 WER 6.6%，官方 demo 即「中文夹 deal/deadline」语料形态（=用户痛点）
- 价格 ¥0.86/h（远在 ¥5/h 内）；唯一代价=无免费额度 + 按连接时长计费（PTT 每句一连，~¥5/月@5h，可接受）

**代码已落地（休眠待 key）**：见下「工程接入」。填 `soniox_api_key` 即活。

**落选记录**：阿里大陆站 paraformer 的「每月 10h 循环免费」只对**大陆账号**有效（需中国身份证实名 + 北京端点=又跨境）；用户是国际账号（被定向 ap-southeast-1），国际版 fun-asr ¥2.33/h 且免费额度一次性——综合不如 Soniox。Azure 东京（5h/月免费、Tokyo-local）是 ¥0 备选，但中英混说无公开数据 + 需引 Speech SDK，作为 Soniox 不满意时的回退。

## 问题

push-to-talk 松手后干等 0.6~1.5s 才注入，且随录音时长涨（17s 句 ~1.35s）。根因：现用腾讯「一句话识别」是 one-shot——松手后才上传整段 WAV。流式（边说边传）是唯一结构性解法，可把松手等待压到 ~250~400ms 恒定。

## 已踩死的坑（别再回头试）

- **腾讯大陆站实时 ASR**：境外 IP 直连报 `6001` 跨境拒绝。跨境版 ¥9.94/h 零免费 → 否决
- **腾讯国际站**（tencentcloud.com）：协议与大陆站逐字段同款（零代码迁移）、新加坡集群、确认可用——但 $1.4/h≈**¥10.08/h 零免费**，贵得和跨境版一样 → 仅当「质量必须腾讯同源」时才考虑
- **AWS Transcribe streaming**：名义 ¥10.4/h，但**每请求最低计费 15 秒**——3~10s 短句被放大成实际 ¥15~20/h → 否
- **GCP chirp 系**：¥6.9/h、chirp_3 无亚洲区域、社区有 cmn 流式立刻 CANCELLED 的未解实锤 → 否
- **OpenAI gpt-realtime-whisper**：真流式但 ¥8.08/h（含日本 10% JCT）、无热词、prompt 被禁 → 否
- **AssemblyAI**：流式语言表无中文 → 失格
- **大陆中转 relay**：维护成本 + 绕路延迟 → 用户明确不要

## 候选矩阵（2026-06-10 核实价，$1≈¥7.2）

| 方案 | ¥/h | 免费额度 | 端点/延迟 | 热词 | 中文质量证据 | 风险 |
|---|---|---|---|---|---|---|
| **阿里 paraformer-realtime-v2**（大陆站百炼）⭐主推 | **0.864** | **10h/月循环**（每月1日发，当月有效）| 东京边缘~15ms→北京推理；实测无封锁 | 免费 500 词中英混合 | 老将稳定，但是阿里三候选下限，需实测 | 官方在推 Fun-ASR 接班（未下线）；模型名做成可配置 |
| 阿里 fun-asr-realtime（同账号备选） | 1.188 | 新人一次性 10h/90天 | 同上 | 同上 | 百炼现任主推，更新 | 快照迭代快，锁版本号 |
| **火山 豆包流式 2.0**（大陆站）⭐质量首选 | 1.0 | 20h 试用/半年一次性（控制台手动领） | 境外直连实测可达（401 鉴权层），无书面承诺 | 最全：boosting+强制替换+context | 中文第一梯队（Seed-ASR 系） | 政策无明文承诺境外可用（实测无限制） |
| BytePlus ASR 2.0（火山国际版，新加坡） | 1.08 | 20h 免费 | 新加坡+Akamai 边缘；零跨境概念 | 内联 hotwords ≤5000 词 | 同豆包同源 | 开户 organization 字段对个人的接受度未确认（文档明言不要营业执照） |
| **Soniox stt-rt-v4** ⭐延迟至上 | 0.86 | 无（$200 赠金已于 2025-10 取消，旧文别信） | **东京本地机房** stt-rt.jp.soniox.com | 有 | 中英 code-switch 证据最强（官方 demo 即中英夹杂场景），自报 zh WER 6.6% | 按连接时长计费（PTT 形态 OK，别挂长连）；试用也要充值 |
| Deepgram nova-3 zh ⭐白嫖试验场 | 2.07 | **$200 赠金免信用卡** ≈690h≈2-5 年 | 美国端点 ~150ms RTT | keyterm 对 zh 未验证 | zh 流式 2026-03 才上线，质量零公开数据 | 全靠赠金值得一试，质量自测 |
| Azure Speech（japaneast） | 7.2 | F0 每月 5h 循环（实时可用，并发=1） | **东京区域**，全场物理延迟最低 | Phrase List 运行时热词，免费 | zh-CN 成熟 | 超 5h 后 ¥7.2/h 偏贵 |
| ElevenLabs Scribe v2 Realtime | 2.81（订阅折算） | Free 档 2.5h/月；Starter $6/月含 15h | 美/欧 | keyterms（加价口径不明） | 官方平均 WER 5.8% vs 第三方测 zh 16.82%——证据矛盾 | zh 质量是最大雷，先 $6 实测 |
| 讯飞国际站 ist（新加坡） | 5.76（$160/200h 年包） | 20h/1 年一次性 | 东京→SG ~94ms | 有（英文热词未实证） | 国际版引擎与大陆版差异无评测 | 社区极少，出问题只有工单 |
| 本地升级路线（¥0） | 0 | — | 本地 | Fun-ASR-Nano 原生热词 | Qwen3-ASR-1.7B / Fun-ASR-Nano-2512 离线质量已超 Paraformer-large 与 SenseVoice（sherpa-onnx ≥1.12.x 已支持） | M 芯片 RTF 未实测；只能批式/伪流式，当 final 引擎升级项另立项 |

## 推荐打法（按序试，止于满意）

1. **开阿里云百炼（大陆站，支付宝实名即可）→ paraformer-realtime-v2**
   - ≤10h/月 = **¥0**（循环免费）；30h/月 ≈ **¥17/月**（对照腾讯跨境同量 ¥298）
   - 用免费额度先实测中英夹杂质量（念几句带 git/worktree/Figma 的真实话术）
   - 顺手建 500 词热词表（vocabulary API，免费）——把 OOV 痛点一起解决
   - 质量不满意 → 同账号同协议切 fun-asr-realtime（¥1.188/h）
2. 还不满意 → **火山豆包 2.0**：领 20h 试用实测，¥1.0/h，中文质量天花板
3. 延迟还想压 → **Soniox 东京机房**（¥0.86/h，~¥26/月@30h）
4. 随时可白嫖 → **Deepgram $200 赠金**（免卡）当试验场

## 工程接入（Soniox 已落地，编译/启动通过，休眠待 key）

统一了多 provider 架构，换家不动主流程：

- `Sources/SonioxStreamingEngine.swift`（新）：`protocol StreamingSession`（feed/finish/onInterim/abort）+ `enum StreamingEngine`（按 `stream_provider` 选 provider 的 dispatcher）+ `SonioxStreamingSession`
  - 端点 `wss://stt-rt.jp.soniox.com/transcribe-websocket`；首帧发 JSON 配置（`api_key`/`model:stt-rt-v4`/`audio_format:s16le`/`sample_rate:16000`/`num_channels:1`/`language_hints:[zh,en]`/`enable_endpoint_detection`）；token `is_final` → 非final=preview、final=committed；松手发 `{"type":"finalize"}`+空二进制帧 → 等 `finished:true`
  - 鉴权写首帧 `api_key` 字段，**无签名**（比腾讯 HMAC 省事）
- `Sources/TencentStreamingEngine.swift`：`TencentStreamingSession` 也 conform `StreamingSession`；用量计改名 `StreamUsageMeter.add(provider:seconds:)` 通用化（写 `~/.mk/stream-usage.json`，按 provider+月份记）
- `Sources/VoiceModule.swift`：`streamSession: (any StreamingSession)?`（原 `tencentStream`）；`startRecording` 用 `StreamingEngine.makeSession()`；`stopAndProcess` 流式收尾提到引擎 switch 之前、provider 无关；WS 失败自动回落腾讯一句话识别
- `Sources/VoiceSession.swift`：`onPCM16k` 旁路 hook 不变

### 启用 / 切换（改 config，代码不动；fileWatcher 热重载，不重启）

`~/.mk/config.json` 的 `polish` 段：
- **开 Soniox**：`"stream_provider": "soniox"` + `"soniox_api_key": "..."`（console.soniox.com 建的 **JP 区** Project 长期 key）+ 可选 `"soniox_region": "jp"`
- **关流式（退回一句话识别 + 本地 live）**：删 `stream_provider`
- `"stream_provider": "tencent"` 仍可走腾讯流式（需 `tencent_appid`，但跨境价不值）

## 现状（2026-06-10）

- Soniox 引擎已合入并装机（PID 跑着），**休眠**——config 无 `soniox_api_key` → `makeSession` 返 nil → 走一句话识别 final + 本地 SenseVoice live 浮窗，¥0、行为不变
- 待用户开通 Soniox JP 区拿 key → 填 config 即活
- 月用量计：`~/.mk/stream-usage.json`（`StreamUsageMeter`，按 provider+月份，日志 `StreamUsage`）

## 验证清单（填 key 后说一句）

1. 日志见 `Soniox WS open region=jp` + HUD 说话时实时刷字（token 非final 预览）
2. `voice_total` 松手→注入 ≤400ms（长句尤其）
3. 中英夹杂实测：GS脚本→JS脚本类、git/worktree/skill 专名命中率 vs 腾讯一句话基线
4. Soniox `context` 提示词试投喂专名（治 OOV）
5. `StreamUsage` 日志看本月分钟数累计正常
