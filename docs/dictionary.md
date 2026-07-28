# 字典与纠错（核心 feature 详解）

MK 不上 LLM、不上云做纠错，靠**字典 + 算法层**：拼音哈希 + 短语 Levenshtein + Metaphone 音相似三层模糊匹配，加上**学习模式**自动入库。"流市/流氏/留时" 全自动归"流式"，无需手维护错音变体。

**核心 metric**：不是"第一次说陌生词不出错"（物理上做不到），而是「**第二次说同样词，会对吗**」——像手机输入法学新词。

## 文件位置

```
~/.mk/correction-dictionary.txt          ← 你手维护（137 词起步）
~/.mk/correction-dictionary-codebase.txt ← scan-codebase.py 自动扫生成（300 词）
~/.mk/correction-dictionary-learned.txt  ← MK --learn 每次自动追加（错例反馈）
~/.mk/dictionary-domains/<name>.txt      ← 圈子领域包（按需启用：ai/frontend/backend...）
~/.mk/config.json                        ← polish.dictionary_domains + active_domains
```

## 错例反馈（一行命令）

```bash
MK --learn "depsick" "DeepSeek"   # 错音 → 正字
```

幂等追加到 `~/.mk/correction-dictionary-learned.txt`，立即 reload。下次再出现 `depsick` 自动纠成 `DeepSeek`。

另有**自动学习**：注入后 30s 内你手改了错字，MK 通过 AX 读回目标 app 文本 → 中文分词 → LCS 对比 → 自动入字典（终端类 app 走 cc hook 路径）。

## 手维护字典格式（.txt）

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

## 圈子领域包（按需启用）

```json
"polish": {
  "dictionary_domains": {
    "ai":       "~/.mk/dictionary-domains/ai.txt",
    "frontend": "~/.mk/dictionary-domains/frontend.txt",
    "backend":  "~/.mk/dictionary-domains/backend.txt"
  },
  "active_domains": ["ai"]
}
```

进哪个圈子开哪个，不强求全装。MK 哲学：**「我说什么，它越来越懂」**，不是「它什么都懂」。

## 自动扫 codebase（启动后台跑）

在 `~/.mk/config.json` 的 `polish.codebase_scan` 配上你的代码目录，**MK 启动时后台自动扫**，扫完触发字典 reload，不阻塞菜单栏：

```json
"polish": {
  "codebase_scan": {
    "enabled": true,
    "roots": ["~/Desktop/my-code", "~/Desktop/cmm"],
    "out_path": "~/.mk/correction-dictionary-codebase.txt",
    "top": 300,
    "min_freq": 3
  }
}
```

扫指定根目录的 `.swift / .ts / .tsx / .py / .rs`，正则抓**驼峰 + 全大写缩写**，按频率排序。排除 `node_modules / .git / .build / dist` 等噪音目录。

**增量缓存**：`~/.mk/cache/codebase-scan.meta.json` 记录每个 root 的 mtime；下次启动 mtime 没变就 skip，~13k 文件首扫 ≈ 2.8s。

也可手动跑：

```bash
client/scripts/scan-codebase.py \
  --top 300 --min-freq 3 \
  --out ~/.mk/correction-dictionary-codebase.txt \
  ~/Desktop/my-code ~/Desktop/cmm
```

## 三层纠错

1. **L1 精确替换**（手维护 + C5 自动派生）— **single-pass left-to-right + 长词优先**，已替换部分不会被后续 err 二次触发（防 `bandwidth` 被 `and→AND` 改成 `bANDwidth`）
2. **C5 自动派生**（加载时一次性派生：`SVG` → `SAG / SVJ / SBG / S V G` 等基于字符混淆表；驼峰仅派生拆词；synth 排除英文 stop words）
3. **L2 Levenshtein 模糊兜底**（按长度桶定向 + 内置 ~500 高频英文词白名单，避免 `AI→API` 误纠）

加载时全套 < 50ms；运行时 correct() **< 20ms（实测 277 字符 + 370 errKeys，硬上限 240ms）**。

## 实测延迟数据（contextualStrings）

| contextualStrings 数量 | 转写耗时 |
|---|---|
| 0 (baseline) | 210ms |
| 50 | 80ms |
| 100 / 500 / 1000 / 5000 | 90ms |

Apple 文档建议 ≤100，但**实测 5000 词跟 100 词同延迟**——SA 内部用 O(1)/O(log n) 索引，"100" 是效果建议非性能约束。MK 已放宽上限到 **1000**。

## Gate 阈值调参（高级）

每次字典替换都打 confidence 分（0-1），默认阈值 `0.0` 全接受、只记录 reason 到日志。如果想用阈值过滤低信心替换防过度纠错：

```bash
# 1. 预览升阈值会砍掉哪些纠错（必跑）
.build/debug/MK --eval-gate "我现在测试流市这个词"

# 2. 看输出的 DELTA ANALYSIS，决定能升到哪个阈值
# 3. 如果 0.5 没砍合理纠错，编辑 ~/.mk/config.json
{
  "polish": {
    "gate_threshold": 0.5
  }
}

# 4. 不放心随时回滚（删字段恢复 0.0 默认）
```

**安全纪律**：
- 默认永远 0（不在菜单做 toggle，避免误点）
- 调阈值前必跑 `--eval-gate` 看会砍什么
- 每次录音的 `[Gate-reject]` 日志都能看到被砍的替换；如果发现合理替换被砍，回去调对应 layer 的 confidence 算法，**不要**直接降阈值兜底

## 升级时学习状态保护

`config.json` 里有个 `polish.learning_happened` 开关：

- **未学过（默认 false）**：升级新版 MK 时，6 领域包**自动从 bundle 覆盖到本地最新**——你拿到每次 release 改进的字典
- **学过之后（自动翻 true）**：升级时**保留你本地版本**——你手改过的领域包 / 个人化积累不会被冲掉

第一次成功触发学习模式（自动学到一条错例 OR 手动跑 `MK --learn`）时，flag 自动翻 true，从此你的字典进入"个人化"状态。
