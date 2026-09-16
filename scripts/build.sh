#!/bin/bash
# 构建 DSH Desktop macOS 应用（无完整 Xcode 环境）
#
# 本机 CLT 处于半更新状态（编译器 swiftlang-6.0.3.1.10 与 SDK 1.5 混装，
# 且 /Library/Developer/CommandLineTools/usr/include/swift/ 同时存在
# module.modulemap 与 bridging.modulemap 导致 SwiftBridging 重复定义）。
# 解决办法：用 Swift 的 -vfsoverlay 把多余的 module.modulemap 映射为空文件。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DSH Desktop"
APP="$ROOT/build/$APP_NAME.app"
BIN="$ROOT/.build/DSHDesktop"

# --- 工具链修复：生成 vfsoverlay -------------------------------------------
CLT_ROOT="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
FIX_DIR="$ROOT/.build/toolchain-fix"
mkdir -p "$FIX_DIR"
: > "$FIX_DIR/empty.modulemap"
cat > "$FIX_DIR/overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": "true",
  "roots": [
    {
      "type": "file",
      "name": "$CLT_ROOT/usr/include/swift/module.modulemap",
      "external-contents": "$FIX_DIR/empty.modulemap"
    }
  ]
}
EOF

export TMPDIR="$FIX_DIR/tmp"
export CLANG_MODULE_CACHE_PATH="$FIX_DIR/clang-modcache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

echo "==> [1/4] swiftc (release)"
rm -f "$BIN"
swiftc -O \
  -target arm64-apple-macosx13.0 \
  -vfsoverlay "$FIX_DIR/overlay.yaml" \
  "$ROOT"/Sources/DSHDesktop/*.swift \
  -o "$BIN"

echo "==> [2/4] assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DSHDesktop"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"

echo "==> [3/4] generate icon (官方鲸鱼 logo)"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# 直接以矢量 SVG 为源交给 make-icon（NSImage 原生支持 SVG，无损放大到 1024，
# 避免旧 50px PNG 源放大 20 倍导致的模糊）
WHALE_SRC="$ROOT/Resources/whale.svg"
swift -vfsoverlay "$FIX_DIR/overlay.yaml" "$ROOT/scripts/make-icon.swift" \
  "$WHALE_SRC" "$ICONSET" "$ROOT/.build/whale-icon.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# 菜单栏模板图标 + 官方 SVG + 源文件（运行时可用）
cp "$ROOT/.build/whale-icon.png" "$APP/Contents/Resources/whale-icon.png"
cp "$ROOT/Resources/whale.svg" "$APP/Contents/Resources/whale.svg"
# Overlay 资源（desktop-layout 等）
mkdir -p "$APP/Contents/Resources/overlays"
cp "$ROOT"/Resources/overlays/*.js "$APP/Contents/Resources/overlays/"

echo "==> [4/4] codesign（稳定化 ad-hoc）"
# 显式指定基于 identifier 的 Designated Requirement：身份不再随每次编译的
# cdhash 漂移，TCC 授权（辅助功能等）跨构建/跨版本持续有效。
# 代价：校验从“精确到字节”放宽为“精确到标识符”（自用与信任链可控场景可接受）。
# 迁移提示：换用此签名后的第一次升级需重置一次旧绑定：
#   tccutil reset Accessibility com.deepseek-ai.dsh-desktop
# 然后在系统设置重新勾选，此后永久稳定。
codesign --force --deep -s - \
  --requirements '=designated => identifier "com.deepseek-ai.dsh-desktop"' \
  "$APP"

echo ""
echo "==> done:"
echo "    $APP"
