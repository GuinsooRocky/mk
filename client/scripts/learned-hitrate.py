#!/usr/bin/env python3
"""精准命中率测试：换引擎能免掉你多少手动纠错？

数据来源（全是你已有的，不用开口）：
  - learned 字典 = 你亲手纠正过的（错例→标准答案），iCloud 那份
  - voice-history.jsonl = 音频 + SA 当年的输出

逻辑：对每条 learned 对，找出 rawSA 里出现过该「错例」的历史 clip（有音频），
用新引擎重转那段音频，看输出里有没有「标准答案」。命中 = 这条错你以后不用再手动纠。

用 venv 跑：
  ~/.mk/.venv-asr/bin/python client/scripts/learned-hitrate.py --engine sensevoice
  ~/.mk/.venv-asr/bin/python client/scripts/learned-hitrate.py --engine groq
"""
import argparse
import json
import os
import subprocess
import wave
from pathlib import Path

import numpy as np

LEARNED = Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "MK" / "correction-dictionary-learned.txt"
HISTORY = Path.home() / ".mk" / "voice-history.jsonl"
MODEL_DIR = Path.home() / ".mk" / "models" / "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"


def parse_learned():
    pairs = []  # (correct, [wrongs])
    for line in LEARNED.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        correct = parts[0]
        wrongs = []
        for tok in parts[1:]:
            if not tok:
                continue
            wrongs.append(tok.split("#")[0].strip())  # 去掉 #次数
        if correct and wrongs:
            pairs.append((correct, wrongs))
    return pairs


def load_history():
    rows = []
    for line in HISTORY.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        ap = e.get("audioPath")
        if ap and os.path.exists(ap):
            rows.append(e)
    return rows


def build_sensevoice(threads, provider):
    import sherpa_onnx
    rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(MODEL_DIR / "model.int8.onnx"),
        tokens=str(MODEL_DIR / "tokens.txt"),
        language="auto", use_itn=True,
        num_threads=threads, provider=provider,
    )

    def run(path):
        with wave.open(str(path)) as w:
            sr = w.getframerate()
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
        s = rec.create_stream()
        s.accept_waveform(sr, samples)
        rec.decode_stream(s)
        return s.result.text.strip()
    return run


def groq_run(path):
    key = os.environ.get("GROQ_API_KEY", "").strip()
    r = subprocess.run(
        ["curl", "-s", "--max-time", "60", GROQ_URL,
         "-H", f"Authorization: Bearer {key}",
         "-F", "model=whisper-large-v3", "-F", "response_format=json",
         "-F", f"file=@{path}"],
        capture_output=True, text=True,
    )
    try:
        return json.loads(r.stdout).get("text", "").strip()
    except json.JSONDecodeError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=["sensevoice", "groq"], default="sensevoice")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--provider", default="cpu")
    ap.add_argument("--max-per-error", type=int, default=2, help="每个错例最多测几条 clip（控成本/时间）")
    args = ap.parse_args()

    pairs = parse_learned()
    history = load_history()
    engine = build_sensevoice(args.threads, args.provider) if args.engine == "sensevoice" else groq_run

    # 收集待测：每条 (correct, wrong) 找历史里 rawSA 含 wrong 的 clip
    cases = []  # (correct, wrong, audioPath, rawSA)
    seen_audio_for = {}  # correct -> set(audioPath) 去重
    for correct, wrongs in pairs:
        for e in history:
            sa = e.get("rawSA") or ""
            for w in wrongs:
                if len(w) >= 2 and w in sa:
                    bag = seen_audio_for.setdefault(correct, set())
                    if e["audioPath"] in bag:
                        continue
                    if len(bag) >= args.max_per_error:
                        continue
                    bag.add(e["audioPath"])
                    cases.append((correct, w, e["audioPath"], sa))
                    break

    if not cases:
        raise SystemExit("没找到可测的 clip")

    print(f"引擎={args.engine}  待测 {len(cases)} 条（覆盖 {len(seen_audio_for)} 个错例）\n")
    hits = 0
    misses = []
    for i, (correct, wrong, path, sa) in enumerate(cases, 1):
        out = engine(path)
        hit = correct.lower() in out.lower()
        hits += hit
        mark = "✅" if hit else "❌"
        print(f"{mark} [{i}/{len(cases)}] 应得「{correct}」(SA错成「{wrong}」)")
        print(f"     {args.engine}: {out}")
        if not hit:
            misses.append((correct, wrong, out))

    print(f"\n{'='*70}")
    print(f"命中率：{hits}/{len(cases)} = {hits*100//len(cases)}%  → 这些手动纠错有 {hits} 条可以扔了")
    if misses:
        print(f"\n仍未命中（{len(misses)}）：")
        for correct, wrong, out in misses:
            print(f"  「{correct}」 still: {out[:60]}")


if __name__ == "__main__":
    main()
