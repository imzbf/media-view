#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ARCH="universal"
APP_OUTPUT=""
SIGN_IDENTITY="-"
NOTARY_PROFILE=""
APP_VERSION="1.0.0"
BUILD_NUMBER="1"

usage() {
    cat <<'USAGE'
Usage: Scripts/build-universal.sh [options]
  --arch ARCH            universal (default), arm64, or x86_64
  --output PATH          Output .app (default: build/MediaView.app for universal,
                         build/<arch>/MediaView.app for a single architecture)
  --identity IDENTITY    Developer ID Application identity (default: ad-hoc)
  --notary-profile NAME  Submit using a notarytool Keychain profile, then staple
  --version VERSION     CFBundleShortVersionString (default: 1.0.0)
  --build-number NUMBER CFBundleVersion (default: 1)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) BUILD_ARCH="${2:?Missing --arch value}"; shift 2 ;;
        --output) APP_OUTPUT="${2:?Missing --output value}"; shift 2 ;;
        --identity) SIGN_IDENTITY="${2:?Missing --identity value}"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="${2:?Missing --notary-profile value}"; shift 2 ;;
        --version) APP_VERSION="${2:?Missing --version value}"; shift 2 ;;
        --build-number) BUILD_NUMBER="${2:?Missing --build-number value}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || { echo "This build requires macOS." >&2; exit 1; }
case "$BUILD_ARCH" in
    universal) ARCHS=(arm64 x86_64); OUTPUT_DIR="$PROJECT_ROOT/build" ;;
    arm64|x86_64) ARCHS=("$BUILD_ARCH"); OUTPUT_DIR="$PROJECT_ROOT/build/$BUILD_ARCH" ;;
    *) echo "Unsupported architecture: $BUILD_ARCH (expected universal, arm64 or x86_64)." >&2; exit 2 ;;
esac
INFO_PLIST="$PROJECT_ROOT/Packaging/Info.plist"
PRODUCT="$(plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST")"
APP_OUTPUT="${APP_OUTPUT:-$OUTPUT_DIR/$PRODUCT.app}"
[[ "$APP_OUTPUT" == /* ]] || APP_OUTPUT="$PWD/$APP_OUTPUT"
[[ "$APP_OUTPUT" == *.app ]] || { echo "--output must end in .app" >&2; exit 2; }
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Invalid version." >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid build number." >&2; exit 2; }
if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires --identity with a Developer ID Application certificate." >&2
    exit 2
fi
xcrun --sdk macosx --show-sdk-path >/dev/null

# 每次打包都从源图生成，避免更新 icon.png 后仍携带旧图标。
swift "$PROJECT_ROOT/Scripts/generate-icon.swift"

mkdir -p "$PROJECT_ROOT/.build/universal"
PACKAGE_STAGE="$(mktemp -d "$PROJECT_ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
STAGED_APP="$PACKAGE_STAGE/$PRODUCT.app"
EXECUTABLE="$STAGED_APP/Contents/MacOS/$PRODUCT"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

# 每个架构使用独立 scratch path，避免交叉编译时复用错误架构的模块缓存。
BINARIES=()
for architecture in "${ARCHS[@]}"; do
    echo "Building Release for ${architecture}..."
    SCRATCH_PATH="$PROJECT_ROOT/.build/universal/$architecture"
    MACOSX_DEPLOYMENT_TARGET=13.0 swift build --package-path "$PROJECT_ROOT" \
        --scratch-path "$SCRATCH_PATH" --configuration release --arch "$architecture" --product "$PRODUCT"
    BIN_PATH="$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$SCRATCH_PATH" \
        --configuration release --arch "$architecture" --show-bin-path)"
    BINARIES+=("$BIN_PATH/$PRODUCT")
done

if [[ "$BUILD_ARCH" == universal ]]; then
    xcrun lipo -create "${BINARIES[@]}" -output "$EXECUTABLE"
else
    cp "${BINARIES[0]}" "$EXECUTABLE"
fi
chmod 755 "$EXECUTABLE"
cp "$INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/Packaging/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
plutil -lint "$STAGED_APP/Contents/Info.plist"
# 校验完整的架构列表；Universal 2 的两种切片顺序等价，单架构包则不能混入其他切片。
ACTUAL_ARCHS="$(xcrun lipo -archs "$EXECUTABLE")"
echo "Architectures: $ACTUAL_ARCHS"
case "$ACTUAL_ARCHS" in
    'arm64 x86_64'|'x86_64 arm64') DETECTED_ARCH=universal ;;
    *) DETECTED_ARCH="$ACTUAL_ARCHS" ;;
esac
[[ "$DETECTED_ARCH" == "$BUILD_ARCH" ]] || { echo "Expected exactly: ${ARCHS[*]}" >&2; exit 1; }

SIGN_ARGUMENTS=(--app "$STAGED_APP" --identity "$SIGN_IDENTITY")
if [[ -n "$NOTARY_PROFILE" ]]; then SIGN_ARGUMENTS+=(--notary-profile "$NOTARY_PROFILE"); fi
"$PROJECT_ROOT/Scripts/sign-and-notarize.sh" "${SIGN_ARGUMENTS[@]}"

# 仅在构建及签名成功后替换既有产物，并拒绝覆盖无关目录或其他应用。
if [[ -e "$APP_OUTPUT" || -L "$APP_OUTPUT" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_OUTPUT/Contents/Info.plist" 2>/dev/null || true)"
    EXPECTED_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
    [[ "$EXISTING_ID" == "$EXPECTED_ID" && ! -L "$APP_OUTPUT" ]] || {
        echo "Refusing to replace an unrelated app or symlink: $APP_OUTPUT" >&2
        exit 1
    }
    rm -rf "$APP_OUTPUT"
fi
mkdir -p "$(dirname "$APP_OUTPUT")"
mv "$STAGED_APP" "$APP_OUTPUT"
codesign --verify --deep --strict --verbose=2 "$APP_OUTPUT"
if [[ -n "$NOTARY_PROFILE" ]]; then
    ditto -c -k --keepParent "$APP_OUTPUT" "${APP_OUTPUT%.app}.zip"
fi
echo "Built $BUILD_ARCH app: $APP_OUTPUT"
