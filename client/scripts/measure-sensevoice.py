#!/usr/bin/env python3
"""量 SenseVoice-Small（sherpa-onnx）在这台 M5 上的【热延迟】+ 中英准确率。

跑 ~/.mk/voice-history.jsonl 已有录音，按音频时长分布挑样本。
对照同一批 clip 的 SA 原始输出，看 SenseVoice 是不是又快又准。

用 venv 跑：
  ~/.mk/.venv-asr/bin/python client/scripts/measure-sensevoice.py
  ~/.mk/.venv-asr/bin/python client/scripts/measure-sensevoice.py --provider coreml --threads 4
"""
import argparse
import json
import time
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

HISTORY = Path.home() / ".mk" / "voice-history.jsonl"
MODEL_DIR = Path.home() / ".mk" / "models" / "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"


def read_wav(path):
    with wave.open(str(path)) as w:
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return sr, samples, n / float(sr)


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
        try:
            _, _, sec = read_wav(e["audioPath"])
        except Exception:
            sec = 0
        e["_sec"] = sec
    rows = [e for e in rows if e["_sec"] > 0.3]
    rows.sort(key=lambda e: e["_sec"])
    if len(rows) <= n:
        return rows
    step = len(rows) / n
    return [rows[int(i * step)] for i in range(n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--provider", default="cpu", choices=["cpu", "coreml"])
    args = ap.parse_args()

    model = MODEL_DIR / "model.int8.onnx"
    tokens = MODEL_DIR / "tokens.txt"
    if not model.exists():
        raise SystemExit(f"模型没找到: {model}")

    rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(model), tokens=str(tokens),
        language="auto", use_itn=True,
        num_threads=args.threads, provider=args.provider,
    )

    def transcribe(path):
        sr, samples, _ = read_wav(path)
        s = rec.create_stream()
        s.accept_waveform(sr, samples)
        rec.decode_stream(s)
        return s.result.text.strip()

    samples = pick_samples(args.n)
    if not samples:
        raise SystemExit("历史库里没有可用录音")

    print(f"SenseVoice int8 · provider={args.provider} · threads={args.threads}")
    print("warm-up...")
    transcribe(samples[0]["audioPath"])

    print(f"\n{'音频秒':>6} {'热推理':>8} {'倍速':>6}  文本对照")
    print("-" * 90)
    rt = []
    for e in samples:
        sec = e["_sec"]
        t1 = time.time()
        loc = transcribe(e["audioPath"])
        ms = int((time.time() - t1) * 1000)
        speed = sec / (ms / 1000) if ms else 0
        rt.append(ms)
        sa = (e.get("rawSA") or "").strip()
        print(f"{sec:6.1f} {ms:7d}ms {speed:5.1f}x")
        print(f"        SV : {loc}")
        print(f"        SA : {sa}\n")

    rt.sort()
    print("-" * 90)
    print(f"热推理延迟  中位={rt[len(rt)//2]}ms  最快={rt[0]}ms  最慢={rt[-1]}ms")
    print("（SA 现在松手后 stop_finalize 中位 ~81ms，但那是边说边出只收尾巴）")


if __name__ == "__main__":
    main()
