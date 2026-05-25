# ASR 纠错系统 — 论文调研 + 已做/未做（current state）

> 单文件当前态，过期即改、不累积 session recap。最后更新：2026-05-26。
> 入口代码：`client/Sources/CorrectionDictionary.swift`（`correct()` 多层流水线 L1→L2→L4→L5→L6→L3）。
> 评测：`MK --eval-corpus`。

## 一、背景问题（两类）

1. **同音词**：Scala vs skill、买点 vs 埋点。无上下文的静态字符串/音码替换天生分不开。
2. **过度纠正 (over-correction)**：短 token 被模糊层撞改成另一个真词。语料里实测到灾难性的：
   `Gate→CUDA`、`AGG→AGI`（项目名被毁）、`MD→AMD`、`CJK→CJS`、`GPT→GIT`、`MVP→MCP`、`Video→Vite`、`PR→PPR`、`OC→OCR`。

## 二、论文调研（SOTA 天花板）

- **别塌成 1-best，在 N-best/lattice + 声学上纠错**：Listen Again [2405.10025]；lattice-attention [2111.10157]；多模 rescoring [2409.16654]
- **音素匹配 + 同音词判别**：PMF-CEC [2506.11064]（phoneme fusion + error-specific selective decoding）；PAC [2509.12647]（发音判别式 RL + 扰动负样本，EN −30.2% / ZH −53.8% WER）
- **检测优先 + 选择性解码（防过纠）**：PMF-CEC / ED-CEC
- **个人词库 = 检索增强 + bonus-then-revoke 偏置**：BR-ASR [2505.19179]；trie [2509.09196]
- **结论**：同音词只能靠上下文（LLM / RL）根治，纯字符串/音码不可解。

目标架构（天花板）：`SenseVoice → N-best+lattice+音素 → 发音感知上下文纠错器(小LLM；条件=N-best·音素·前后文·检索词库) → 检测→只重生成可疑 span → 同音词靠上下文判（模型用本人历史+硬负样本训）`。
硬卡点：① SenseVoice 是 NAR，N-best/lattice 弱；② 同音词 RL 单用户数据不足 + 本地训练重；③ push-to-talk 延迟预算。

## 三、5 步计划 + 进度

- [x] **Step 0 learned 回扫修复** — `correct()` 末尾补一趟 L1（`applyExactCorrections(pass:"L1-final")`），收掉模糊层造出、却命中 learned 的词（`sscale --L5--> Scala --L1final--> skill`）。验证：`--test-dict-correct` + 1254 条语料。
- [x] **Step 1 评测 harness** — `MK --eval-corpus [--rebaseline] [N]`，只 replay dict 层、对 golden baseline 做回归 diff。基线：`~/.mk/eval-corpus-baseline.json`。
- [x] **Step A（替代 Step 2+3）过度纠正修复** — 保护词表 `~/.mk/protected-terms.txt` + white-5「已是字典正字就不模糊纠错」。消灭 27 条灾难，零误伤 / 零下载 / 零延时。保留了 `gat→GIT` 这类该纠的短词。
- [ ] ~~**Step 2 Apple↔SenseVoice 置信度对齐**~~ — **放弃**。数据显示过纠主因是短 token 碰撞，便宜法(A)已解；侵入式（改 `correct()` 签名 + 跨引擎对齐）边际收益低、对齐可靠性存疑（Apple 与 SenseVoice 是两份不同假设）。
- [ ] **Step 4 音素检索 (CMUdict G2P)** — **暂缓**。主攻召回，但语料显示问题是「过纠」非「欠纠」；是 5 步里唯一要下载（3MB CMUdict）；且治不了同音词。等出现「该纠没纠」的证据再做。
- [ ] **Step 5 上下文 LLM 判别（同音词根治）** — **未做**。需装 ollama + qwen3:0.6b（当前**未安装**，config 里只是占位、`serverConfig` 无代码调用）。有 bundle(~GB) + 延迟成本。

## 四、本次新增的文件 / 工具

- `~/.mk/protected-terms.txt` — 用户保护词，一行一词、大小写不敏感、`#` 注释。已纳入 loadAll 的 mtime 监视，**改完下次录音即生效**。
- `MK --eval-corpus` — 回归评测；任何纠错改动前后必跑，CHANGED 列表逐条 review。
- `~/.mk/eval-corpus-baseline.json` — golden 快照（`--rebaseline` 固化新基线）。
- `client/Sources/CorpusEval.swift` — 上述 CLI 实现。

## 五、已知限制（诚实）

- eval harness 用 `finalText` 当伪 ground-truth（非干净真值），只作回归/横比，不作绝对质量评分。
- 真·无上下文同音词，任何非 Step 5 方案都赢不了。
- white-5 的 `termsSet` 检查大小写敏感（保护词 white-4 不敏感）—— 覆盖窄一点，非 bug。
- `Mamory→Mimir`、`Creat→CRUD` 等长词 metaphone 误配，A 的保护词/white-5 不一定覆盖；按需加保护词。

## 六、验证状态（诚实）

- **做了**：编译通过；行为验证（Scala case + 1341 条语料回归，改动逐条 review 无误伤 + `gat→git` 保留 spot-test）；diff 自审；**bug-hunter agent 独立复审**。
- **没做**：单元测试；adversary/judge 全流程（bug-hunter 后我直接兼任裁判逐条复现验证）。
- **状态**：以上改动**均未 commit、未 `make install`**。你日常用的 v0.3.9 仍**不含**这些修复。

### bug-hunter 复审（2026-05-26）— 6 findings，5 修 1 误报

| # | 严重度 | 问题 | 处理 |
|---|---|---|---|
| 1 | High | L1-final 破坏 OLD「L1↔L2 互消」平衡，`vLLM→LLM`（vLLM 既是术语又是 learned 错音键，同 Scala/skill 矛盾类） | 修：L1 尊重保护词；`vllm` 入保护表、`br` 移出（它是 learned `BR→PR` 错音键） |
| 2 | Medium | 保护词漏 L4 短语层，`js oc`→`JSON` | 修：L4 窗口含保护词 token 即跳过 |
| 3 | Medium | synth 错音键吞同名真术语，`CSR`→`SSR` | 修：建表期 synth 变体若本身是术语则不生成（连带治好 `skill→SKILL`/`git→GIT` 强制大写） |
| 4 | Low | 重定向下 print 丢失 | **误报**：复现失败，疑为 bug-hunter 自身漏 `DYLD_LIBRARY_PATH` 致崩溃无输出 |
| 5 | Low | `--eval-corpus --rebaseline 50` 吞掉 50 | 修：扫所有 arg 取首个整数、钳 ≥1 |
| 6 | Low | `loadProtectedTerms` 不剥 BOM，BOM 文件首词失效 | 修：读入剥 `﻿` |
