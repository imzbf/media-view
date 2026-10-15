#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_OUTPUT="$PROJECT_ROOT/build/ImageView.app"
SIGN_IDENTITY="-"
NOTARY_PROFILE=""
APP_VERSION="1.0.0"
BUILD_NUMBER="1"

usage() {
    cat <<'USAGE'
Usage: Scripts/build-universal.sh [options]
  --output PATH          Output .app (default: build/ImageView.app)
  --identity IDENTITY    Developer ID Application identity (default: ad-hoc)
  --notary-profile NAME  Submit using a notarytool Keychain profile, then staple
  --version VERSION     CFBundleShortVersionString (default: 1.0.0)
  --build-number NUMBER CFBundleVersion (default: 1)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
STAGED_APP="$PACKAGE_STAGE/ImageView.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

# 每个架构使用独立 scratch path，避免交叉编译时复用错误架构的模块缓存。
BINARIES=()
for architecture in arm64 x86_64; do
    echo "Building Release for ${architecture}..."
    SCRATCH_PATH="$PROJECT_ROOT/.build/universal/$architecture"
    MACOSX_DEPLOYMENT_TARGET=13.0 swift build --package-path "$PROJECT_ROOT" \
        --scratch-path "$SCRATCH_PATH" --configuration release --arch "$architecture"
    BIN_PATH="$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$SCRATCH_PATH" \
        --configuration release --arch "$architecture" --show-bin-path)"
    BINARIES+=("$BIN_PATH/ImageView")
done

xcrun lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/ImageView"
chmod 755 "$STAGED_APP/Contents/MacOS/ImageView"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/Packaging/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
plutil -lint "$STAGED_APP/Contents/Info.plist"
ARCHITECTURES="$(xcrun lipo -archs "$STAGED_APP/Contents/MacOS/ImageView")"
echo "Architectures: $ARCHITECTURES"
[[ "$ARCHITECTURES" == "x86_64 arm64" || "$ARCHITECTURES" == "arm64 x86_64" ]] || {
    echo "Expected exactly arm64 and x86_64 slices." >&2
    exit 1
}

SIGN_ARGUMENTS=(--app "$STAGED_APP" --identity "$SIGN_IDENTITY")
if [[ -n "$NOTARY_PROFILE" ]]; then SIGN_ARGUMENTS+=(--notary-profile "$NOTARY_PROFILE"); fi
"$PROJECT_ROOT/Scripts/sign-and-notarize.sh" "${SIGN_ARGUMENTS[@]}"

# 仅在构建及签名成功后替换既有产物，并拒绝覆盖无关目录或其他应用。
if [[ -e "$APP_OUTPUT" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_OUTPUT/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$EXISTING_ID" == com.imzbf.ImageView && ! -L "$APP_OUTPUT" ]] || {
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
echo "Built Universal 2 app: $APP_OUTPUT"
