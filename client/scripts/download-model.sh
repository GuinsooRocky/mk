#!/bin/bash
# 下载本地引擎所需模型到 ~/.mk/models/
#
# - SenseVoice ASR（多语种 zh/en/ja/ko/yue，~230MB）：engine=sensevoice 的转写模型
# - silero VAD（~2MB）：长句切段用。没有它，>10s 的长音频会退回整段解码
#   （延迟暴涨 + 中段易丢，只剩头尾）。强烈建议一起装。
#
# 模型不随 release 打包（保持 .app 小巧）；首次用本地引擎前跑一次本脚本即可。
#
# 用法: ./scripts/download-model.sh

set -euo pipefail

MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODELS_DIR="$HOME/.mk/models"
MODEL_DIR="$MODELS_DIR/$MODEL_NAME"
ASR_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
VAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
VAD_MODEL="$MODELS_DIR/silero_vad.onnx"

mkdir -p "$MODELS_DIR"

# === 1) silero VAD（独立、幂等、小）=================================
if [ -f "$VAD_MODEL" ]; then
    echo "✅ silero VAD 已存在: $VAD_MODEL"
else
    echo "=== 下载 silero VAD (~2MB) ==="
    echo "    来源: $VAD_URL"
    # -f：HTTP 错误返回非 0；-L：跟随重定向；写到 .tmp 再原子改名，避免半截文件
    curl -fL -o "$VAD_MODEL.tmp" "$VAD_URL"
    mv "$VAD_MODEL.tmp" "$VAD_MODEL"
    echo "✅ silero_vad.onnx"
fi

# === 2) SenseVoice ASR（大）=======================================
if [ -f "$MODEL_DIR/model.int8.onnx" ] && [ -f "$MODEL_DIR/tokens.txt" ]; then
    echo "✅ SenseVoice 模型已存在: $MODEL_DIR"
    echo ""
    echo "全部就绪。在 ~/.mk/config.json 设 polish.engine = \"sensevoice\" 启用本地引擎。"
    exit 0
fi

echo "=== 下载 SenseVoice 模型 (~230MB) ==="
echo "    来源: $ASR_URL"

TARBALL="$MODELS_DIR/${MODEL_NAME}.tar.bz2"
# -f：HTTP 错误返回非 0；-L：跟随 GitHub release 重定向；-C -：断点续传
curl -fL -C - -o "$TARBALL" "$ASR_URL"

echo "=== 解压到 $MODELS_DIR ==="
tar -xjf "$TARBALL" -C "$MODELS_DIR"
rm -f "$TARBALL"

# 校验（SenseVoiceEngine 只需 model.int8.onnx + tokens.txt）
if [ -f "$MODEL_DIR/model.int8.onnx" ] && [ -f "$MODEL_DIR/tokens.txt" ]; then
    SIZE=$(du -sh "$MODEL_DIR" | awk '{print $1}')
    echo ""
    echo "✅ 完成: $MODEL_DIR ($SIZE)"
    echo "   在 ~/.mk/config.json 设 polish.engine = \"sensevoice\" 启用本地引擎。"
else
    echo "❌ 解压后未找到 model.int8.onnx / tokens.txt，请检查下载是否完整。" >&2
    exit 1
fi
