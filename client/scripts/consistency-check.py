#!/usr/bin/env python3
"""自测：SenseVoice 对同一个专名的音译稳不稳定？

稳定 → 事后字典记一次就能全捞回（不会"学得很死"）。
不稳 → 每次错法不同，字典照样追不上。

对每个 learned 专名，找出历史里 SA 错过它的【所有】clip（不限条数），
用 SenseVoice 重转，把每条输出列在一起，肉眼就能看出"它每次是不是错成同一样"。
"""
import json
import os
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

LEARNED = Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "MK" / "correction-dictionary-learned.txt"
HISTORY = Path.home() / ".mk" / "voice-history.jsonl"
MODEL_DIR = Path.home() / ".mk" / "models" / "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"

# 只看"私有专名"那类（最关心能不能捞回的）
FOCUS = ["worktree", "session", "Harness", "harness", "Hermes", "Vercel",
         "Kubernetes", "主 agent", "OpenClaw", "Codex", "useState", "PRD"]


def parse_learned():
    pairs = {}
    for line in LEARNED.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        correct = parts[0]
        wrongs = [t.split("#")[0].strip() for t in parts[1:] if t.strip()]
        if correct and wrongs:
            pairs[correct] = wrongs
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
        if e.get("audioPath") and os.path.exists(e["audioPath"]):
            rows.append(e)
    return rows


def main():
    rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(MODEL_DIR / "model.int8.onnx"),
        tokens=str(MODEL_DIR / "tokens.txt"),
        language="auto", use_itn=True, num_threads=4,
    )

    def transcribe(path):
        with wave.open(str(path)) as w:
            sr = w.getframerate()
            samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
        s = rec.create_stream()
        s.accept_waveform(sr, samples)
        rec.decode_stream(s)
        return s.result.text.strip()

    pairs = parse_learned()
    history = load_history()

    for correct in FOCUS:
        if correct not in pairs:
            continue
        wrongs = pairs[correct]
        clips = []
        seen = set()
        for e in history:
            sa = e.get("rawSA") or ""
            if any(len(w) >= 2 and w in sa for w in wrongs):
                if e["audioPath"] not in seen:
                    seen.add(e["audioPath"])
                    clips.append(e)
        if not clips:
            continue
        print(f"\n━━━ 「{correct}」 在 {len(clips)} 条录音里出现过 ━━━")
        for e in clips[:6]:
            out = transcribe(e["audioPath"])
            hit = "✅" if correct.lower() in out.lower() else "  "
            print(f"  {hit} {out}")


if __name__ == "__main__":
    main()
