#!/bin/bash
# 下载 SenseVoice 本地离线 ASR 模型到 ~/.mk/models/
#
# engine=sensevoice 需要这个模型（多语种 zh/en/ja/ko/yue，~230MB）。
# 模型不随 release 打包（保持 .app 小巧）；首次用本地引擎前跑一次本脚本即可。
#
# 用法: ./scripts/download-model.sh

set -euo pipefail

MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODELS_DIR="$HOME/.mk/models"
MODEL_DIR="$MODELS_DIR/$MODEL_NAME"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"

# 已装则跳过（幂等）
if [ -f "$MODEL_DIR/model.int8.onnx" ] && [ -f "$MODEL_DIR/tokens.txt" ]; then
    echo "✅ 模型已存在: $MODEL_DIR"
    echo "   如需重装，先删除该目录再重跑。"
    exit 0
fi

echo "=== 下载 SenseVoice 模型 (~230MB) ==="
echo "    来源: $URL"
mkdir -p "$MODELS_DIR"

TARBALL="$MODELS_DIR/${MODEL_NAME}.tar.bz2"
# -f：HTTP 错误返回非 0；-L：跟随 GitHub release 重定向；-C -：断点续传
curl -fL -C - -o "$TARBALL" "$URL"

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
