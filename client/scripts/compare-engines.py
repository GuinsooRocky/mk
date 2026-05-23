#!/usr/bin/env python3
"""三引擎离线对比：Apple SpeechAnalyzer(历史已存) vs Groq Whisper vs 本地 Whisper(可选)。

不用开口。跑 ~/.mk/voice-history.jsonl 里已有的真实录音：
  - SA 列   : 直接读历史 rawSA（零成本，已存）
  - Groq 列 : 把对应 wav POST 给 Groq（需 GROQ_API_KEY 在 env）
  - 本地列  : mlx-whisper turbo 跑同一段 wav（--local 开启，需 pip install mlx-whisper）

用法:
  ./compare-engines.py                    # SA vs Groq，最近 15 段
  ./compare-engines.py --limit 30
  ./compare-engines.py --local            # 再加本地 mlx-whisper turbo 列
  ./compare-engines.py --groq-model whisper-large-v3-turbo
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HISTORY = Path.home() / ".mk" / "voice-history.jsonl"
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
LOCAL_REPO = "mlx-community/whisper-large-v3-turbo"


def load_entries(limit):
    if not HISTORY.exists():
        sys.exit(f"找不到历史库 {HISTORY}")
    by_path = {}
    for line in HISTORY.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        ap = e.get("audioPath")
        if not ap or not Path(ap).exists():
            continue
        by_path[ap] = e  # 同一 wav 取最后一条
    uniq = list(by_path.values())
    return uniq[-limit:]


def groq(wav, model, key):
    r = subprocess.run(
        ["curl", "-s", "--max-time", "60", GROQ_URL,
         "-H", f"Authorization: Bearer {key}",
         "-F", f"model={model}", "-F", "response_format=json",
         "-F", f"file=@{wav}"],
        capture_output=True, text=True,
    )
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError:
        return f"<groq 无响应: {r.stdout[:120]}>"
    if "text" in d:
        return d["text"].strip()
    return f"<groq 错误: {d}>"


_LOCAL_MOD = None


def local_whisper(wav):
    global _LOCAL_MOD
    if _LOCAL_MOD is None:
        try:
            import mlx_whisper  # noqa
            _LOCAL_MOD = mlx_whisper
        except ImportError:
            sys.exit("本地列需要: pip install mlx-whisper（首次会自动下 ~1.5G 模型）")
    out = _LOCAL_MOD.transcribe(str(wav), path_or_hf_repo=LOCAL_REPO)
    return out["text"].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=15)
    ap.add_argument("--local", action="store_true")
    ap.add_argument("--groq-model", default="whisper-large-v3")
    args = ap.parse_args()

    key = os.environ.get("GROQ_API_KEY", "").strip()
    if not key:
        sys.exit("GROQ_API_KEY 不在环境里（这脚本在你 shell 跑，应该能读到）")

    entries = load_entries(args.limit)
    if not entries:
        sys.exit("历史库里没有 audioPath 仍存在的录音")

    out_path = Path.home() / ".mk" / f"engine-compare-{time.strftime('%Y%m%d-%H%M%S')}.md"
    lines = [f"# 三引擎对比 {time.strftime('%Y-%m-%d %H:%M')}  ·  {len(entries)} 段录音",
             f"groq={args.groq_model}  local={'on('+LOCAL_REPO+')' if args.local else 'off'}\n"]

    for i, e in enumerate(entries, 1):
        wav = e["audioPath"]
        name = Path(wav).name
        sa = (e.get("rawSA") or "").strip()
        final = (e.get("finalText") or "").strip()

        t0 = time.time()
        grq = groq(wav, args.groq_model, key)
        grq_ms = int((time.time() - t0) * 1000)

        loc = ""
        if args.local:
            t1 = time.time()
            loc = local_whisper(wav)
            loc_ms = int((time.time() - t1) * 1000)

        print(f"\n[{i}/{len(entries)}] {name}")
        print(f"  SA  : {sa}")
        print(f"  GRQ : {grq}   ({grq_ms}ms)")
        if args.local:
            print(f"  LOC : {loc}   ({loc_ms}ms)")

        lines.append(f"## {i}. {name}")
        lines.append(f"- **SA** ：{sa}")
        lines.append(f"- **GRQ**：{grq}")
        if args.local:
            lines.append(f"- **LOC**：{loc}")
        lines.append(f"- _你当前实拿(过完字典)_：{final}\n")

    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n报告已写: {out_path}")


if __name__ == "__main__":
    main()
