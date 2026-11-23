#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH=""
VERSION=""
BUILD_NUMBER=1

usage() {
    echo 'Usage: Scripts/build-dmg.sh --arch arm64|x86_64 --version X.Y.Z [--build-number N]'
    echo 'The build number defaults to 1.'
}

fail() { echo "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:?Missing --arch value}"; shift 2 ;;
        --version) VERSION="${2:?Missing --version value}"; shift 2 ;;
        --build-number) BUILD_NUMBER="${2:?Missing --build-number value}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || fail 'Expected --arch arm64 or x86_64.'
component='(0|[1-9][0-9]*)'
version_pattern="^${component}\.${component}\.${component}$"
[[ "$VERSION" =~ $version_pattern ]] || fail 'Expected a stable --version X.Y.Z.'
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail 'Expected a positive integer --build-number.'
[[ "$(uname -s)" == Darwin ]] || fail 'Building a DMG requires macOS.'

OUTPUT_DIR="$PROJECT_ROOT/build/release"
NAME="MediaView-$VERSION-$ARCH.dmg"
mkdir -p "$OUTPUT_DIR"
[[ ! -d "$OUTPUT_DIR/$NAME" ]] || fail "Destination is a directory: $OUTPUT_DIR/$NAME"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.dmg.XXXXXX")"
MOUNT="$WORK_DIR/mount"
cleanup() {
    # 直接比较设备号：即使在 attach 返回前收到中断，也不能在已挂载的目录上递归删除。
    if [[ -d "$MOUNT" && "$(stat -f %d "$MOUNT")" != "$(stat -f %d "$WORK_DIR")" ]]; then
        hdiutil detach "$MOUNT" || hdiutil detach -force "$MOUNT" || { echo "Could not unmount $MOUNT" >&2; return 1; }
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORK_DIR/payload" "$MOUNT"
"$PROJECT_ROOT/Scripts/build-universal.sh" --arch "$ARCH" --version "$VERSION" \
    --build-number "$BUILD_NUMBER" --identity - --output "$WORK_DIR/payload/MediaView.app"
ln -s /Applications "$WORK_DIR/payload/Applications"
hdiutil create -srcfolder "$WORK_DIR/payload" -volname MediaView -fs HFS+ -format UDZO "$WORK_DIR/$NAME"

# 校验下载者实际挂载的镜像，而不是源 .app；全部通过才替换上一次构建的 DMG。
hdiutil verify "$WORK_DIR/$NAME"
hdiutil attach -readonly -nobrowse -noautoopen -mount required -mountpoint "$MOUNT" "$WORK_DIR/$NAME"
APP="$MOUNT/MediaView.app"
PLIST="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")" == "$VERSION" ]] || fail 'DMG version mismatch.'
[[ "$(plutil -extract CFBundleVersion raw -o - "$PLIST")" == "$BUILD_NUMBER" ]] || fail 'DMG build number mismatch.'
[[ "$(xcrun lipo -archs "$APP/Contents/MacOS/MediaView")" == "$ARCH" ]] || fail 'DMG architecture mismatch.'
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]] || fail 'Incorrect Applications link in DMG.'
codesign --verify --deep --strict --verbose=2 "$APP"
signature="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -Fxq 'Signature=adhoc' <<< "$signature" || fail 'Expected an ad-hoc app signature.'
hdiutil detach "$MOUNT"
mv -f "$WORK_DIR/$NAME" "$OUTPUT_DIR/$NAME"
echo "Verified DMG: $OUTPUT_DIR/$NAME"
