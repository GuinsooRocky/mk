#!/usr/bin/env python3
"""量本地 Whisper 在这台 Mac 上的【热延迟】（模型常驻、不含加载）。

回答唯一的问号：松手后整段转一遍要多久，能不能逼近 SA 现在的 ~80ms 体感。
跑 ~/.mk/voice-history.jsonl 里已有录音，按音频时长分布挑样本。

用 venv 跑：
  ~/.mk/.venv-asr/bin/python client/scripts/measure-local-latency.py
  ~/.mk/.venv-asr/bin/python client/scripts/measure-local-latency.py --repo mlx-community/whisper-large-v3-turbo --n 8
"""
import argparse
import json
import time
import wave
from pathlib import Path

HISTORY = Path.home() / ".mk" / "voice-history.jsonl"


def wav_seconds(path):
    try:
        with wave.open(str(path)) as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return 0.0


def pick_samples(n):
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
        if ap and Path(ap).exists():
            by_path[ap] = e
    rows = list(by_path.values())
    for e in rows:
        e["_sec"] = wav_seconds(e["audioPath"])
    rows = [e for e in rows if e["_sec"] > 0.3]
    rows.sort(key=lambda e: e["_sec"])  # 按时长排，覆盖短→长
    if len(rows) <= n:
        return rows
    step = len(rows) / n
    return [rows[int(i * step)] for i in range(n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="mlx-community/whisper-large-v3-turbo")
    ap.add_argument("--n", type=int, default=8)
    args = ap.parse_args()

    import mlx_whisper

    samples = pick_samples(args.n)
    if not samples:
        raise SystemExit("历史库里没有可用录音")

    print(f"模型: {args.repo}")
    print("warm-up（含模型加载，不计入）...")
    t0 = time.time()
    mlx_whisper.transcribe(samples[0]["audioPath"], path_or_hf_repo=args.repo)
    print(f"  首次加载 {int((time.time()-t0)*1000)}ms（之后常驻，下面才是真实热延迟）\n")

    print(f"{'音频秒':>6} {'热推理':>8} {'倍速':>6}  文本对照")
    print("-" * 90)
    rt = []
    for e in samples:
        sec = e["_sec"]
        t1 = time.time()
        out = mlx_whisper.transcribe(e["audioPath"], path_or_hf_repo=args.repo)
        ms = int((time.time() - t1) * 1000)
        speed = sec / (ms / 1000) if ms else 0
        rt.append(ms)
        loc = out["text"].strip()
        sa = (e.get("rawSA") or "").strip()
        print(f"{sec:6.1f} {ms:7d}ms {speed:5.1f}x")
        print(f"        LOC : {loc}")
        print(f"        SA  : {sa}\n")

    rt.sort()
    print("-" * 90)
    print(f"热推理延迟  中位={rt[len(rt)//2]}ms  最快={rt[0]}ms  最慢={rt[-1]}ms")
    print(f"（对照：SA 现在松手后 stop_finalize 中位 ~81ms，但那是边说边出只收尾巴）")


if __name__ == "__main__":
    main()
