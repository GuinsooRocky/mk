#!/bin/bash
# MK release 打包脚本（输出 zip + dmg）
#
# 用法:
#   ./scripts/build-dmg.sh           # 用 Info.plist 里的版本号
#   ./scripts/build-dmg.sh 0.3.5     # 显式覆盖版本号
#
# 输出:
#   .build/MK-v<version>.zip   ← GitHub release 用这个（README 链接对齐）
#   .build/MK-v<version>.dmg   ← 传统 .dmg 安装盘（可选）
#
# 签名策略: ad-hoc 签名（codesign -s -）
# 用户首次安装需要执行 xattr -cr /Applications/MK.app 绕过 Gatekeeper
# 详细安装步骤见 scripts/INSTALL.txt

set -euo pipefail

# 切到 client 目录（脚本可能在任何位置被调用）
cd "$(dirname "$0")/.."

INFO_PLIST="Sources/Info.plist"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/MK.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

# 1) 解析版本号
if [ $# -ge 1 ]; then
    VERSION="$1"
else
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
fi
ZIP_NAME="MK-v${VERSION}.zip"
DMG_NAME="MK-v${VERSION}.dmg"
VOL_NAME="MK ${VERSION}"
STAGING="$BUILD_DIR/dmg-staging"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "=== Building MK ${VERSION} ==="

# 2) Release 构建
echo "[1/6] swift build -c release..."
swift build -c release

# 3) 组装 .app bundle
# 关键：必须把 SwiftPM 产出的 WE_MK.bundle 拷进 Contents/Resources/，
# 否则 DictPackInstaller 找不到 6 个领域字典包（ai/frontend/backend/...）
echo "[2/6] Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_DIR/release/MK" "$APP_MACOS/MK"
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
cp -R "$BUILD_DIR/release/WE_MK.bundle" "$APP_RESOURCES/"
# 关键：拷 sherpa-onnx 运行时 dylib 到 MacOS/（与 Makefile run/install 一致）。
# 二进制 install_name 是 @rpath/...，靠 @executable_path rpath 解析到 MacOS/。
# 漏拷 → 别人机器 `dyld: Library not loaded` 启动即崩（本机有 Vendor 路径察觉不到）。
cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib \
   Vendor/sherpa-onnx/lib/libonnxruntime.1.24.4.dylib \
   "$APP_MACOS/"
# PkgInfo: macOS LaunchServices 用它识别 bundle 类型（type=APPL/creator=????）
# 没有这个文件 LaunchServices 可能不注册 bundle id，导致 TCC 找不到 app，
# 麦克风/语音识别等权限弹窗永远不出现。
printf 'APPL????' > "$APP_CONTENTS/PkgInfo"

# 4) 签名：优先用 "MK Development" 自签证书；缺证书回退 ad-hoc
# 为什么不直接 ad-hoc：ad-hoc 签名的 Designated Requirement 只是 cdhash，
# 每次 rebuild cdhash 变 → TCC 吊销 Accessibility/Mic/Speech 授权，
# 导致开发循环里"重装后热键失效，要重新授权"。
# 自签证书的 DR 含证书指纹（cert fingerprint），跨 build 稳定 → TCC 保留授权。
#
# 注意：不加 --options runtime（hardened runtime）。理由：
#   ad-hoc/自签都无法附带正式 Apple Developer entitlements，
#   hardened runtime 会强制要求 com.apple.security.device.audio-input 等，
#   否则直接拒绝麦克风访问。Info.plist 的 NSMicrophoneUsageDescription
#   在 hardened runtime 下不够用。未来要做 notarization 时配合 entitlements 一起加回。
if security find-certificate -c "MK Development" >/dev/null 2>&1; then
    echo "[3/6] Codesigning (MK Development self-signed cert)..."
    codesign --force --deep --sign "MK Development" "$APP_BUNDLE"
else
    echo "[3/6] Codesigning (ad-hoc fallback — TCC perms will reset each build)..."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE" || {
    echo "ERROR: codesign verification failed"
    exit 1
}

# 5) 打 zip（GitHub release 主用）
echo "[4/6] Creating zip..."
rm -f "$ZIP_PATH"
(cd "$BUILD_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "MK.app" "$ZIP_NAME")

# 6) 准备 DMG staging 目录
echo "[5/6] Staging DMG content..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/MK.app"
ln -s /Applications "$STAGING/Applications"
cp scripts/INSTALL.txt "$STAGING/INSTALL.txt"

# 7) 制作 DMG（UDZO 压缩格式）
echo "[6/6] Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

# 清理 staging
rm -rf "$STAGING"

# 输出
ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo ""
echo "=== Done ==="
echo "  ZIP:     $ZIP_PATH  ($ZIP_SIZE)"
echo "  DMG:     $DMG_PATH  ($DMG_SIZE)"
echo "  Volume:  $VOL_NAME"
echo "  Version: $VERSION"
echo ""
echo "Release: gh release create v${VERSION} $ZIP_PATH -R GuinsooRocky/mk"
echo "Local install: drag MK.app from $APP_BUNDLE to /Applications, then:"
echo "         xattr -cr /Applications/MK.app"
