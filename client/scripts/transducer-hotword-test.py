#!/usr/bin/env python3
"""自测：流式 transducer + 热词，能把你的专名在源头钉回多少？

同一批"含专名"的历史录音，跑两遍：不开热词 vs 开热词（热词表 = 你的 learned 专名）。
直接看热词偏置的增量——这是 SenseVoice/字典都做不到的"源头钉名字"。

用 venv 跑：
  ~/.mk/.venv-asr/bin/python client/scripts/transducer-hotword-test.py
  ~/.mk/.venv-asr/bin/python client/scripts/transducer-hotword-test.py --score 3.0
"""
import argparse
import json
import os
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

LEARNED = Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "MK" / "correction-dictionary-learned.txt"
HISTORY = Path.home() / ".mk" / "voice-history.jsonl"
MODEL_DIR = Path.home() / ".mk" / "models" / "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
HOTWORDS_FILE = Path.home() / ".mk" / "models" / "hotwords.txt"


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


def read_wav(path):
    with wave.open(str(path)) as w:
        sr = w.getframerate()
        samples = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    return sr, samples


def build(score, hotwords_file=None):
    kw = dict(
        tokens=str(MODEL_DIR / "tokens.txt"),
        encoder=str(MODEL_DIR / "encoder-epoch-99-avg-1.onnx"),
        decoder=str(MODEL_DIR / "decoder-epoch-99-avg-1.onnx"),
        joiner=str(MODEL_DIR / "joiner-epoch-99-avg-1.onnx"),
        num_threads=4,
        decoding_method="modified_beam_search",
    )
    if hotwords_file:
        kw.update(
            hotwords_file=str(hotwords_file),
            hotwords_score=score,
            modeling_unit="cjkchar+bpe",
            bpe_vocab=str(MODEL_DIR / "bpe.vocab"),
        )
    return sherpa_onnx.OnlineRecognizer.from_transducer(**kw)


def transcribe(rec, path):
    sr, samples = read_wav(path)
    s = rec.create_stream()
    s.accept_waveform(sr, samples)
    tail = np.zeros(int(sr * 0.5), dtype=np.float32)
    s.accept_waveform(sr, tail)
    s.input_finished()
    while rec.is_ready(s):
        rec.decode_stream(s)
    return rec.get_result(s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--score", type=float, default=2.5)
    ap.add_argument("--per", type=int, default=3)
    args = ap.parse_args()

    pairs = parse_learned()
    # 热词表 = 所有 learned 正字（你的专名）
    HOTWORDS_FILE.write_text("\n".join(pairs.keys()) + "\n", encoding="utf-8")
    print(f"热词表 {len(pairs)} 条 → {HOTWORDS_FILE}")

    base = build(args.score, hotwords_file=None)
    hot = build(args.score, hotwords_file=HOTWORDS_FILE)

    history = load_history()
    hits_base = hits_hot = total = 0
    for correct, wrongs in pairs.items():
        clips, seen = [], set()
        for e in history:
            sa = e.get("rawSA") or ""
            if any(len(w) >= 2 and w in sa for w in wrongs) and e["audioPath"] not in seen:
                seen.add(e["audioPath"])
                clips.append(e["audioPath"])
            if len(clips) >= args.per:
                break
        if not clips:
            continue
        print(f"\n━━━ 「{correct}」 ━━━")
        for p in clips:
            b = transcribe(base, p)
            h = transcribe(hot, p)
            hb = correct.lower() in b.lower()
            hh = correct.lower() in h.lower()
            total += 1
            hits_base += hb
            hits_hot += hh
            print(f"  无热词 {'✅' if hb else '  '}: {b}")
            print(f"  开热词 {'✅' if hh else '  '}: {h}")

    print(f"\n{'='*60}")
    print(f"命中：无热词 {hits_base}/{total}  →  开热词 {hits_hot}/{total}")


if __name__ == "__main__":
    main()
