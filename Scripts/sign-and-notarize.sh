#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/build/ImageView.app"
SIGN_IDENTITY="-"
NOTARY_PROFILE=""

usage() {
    cat <<'USAGE'
Usage: Scripts/sign-and-notarize.sh [options]
  --app PATH             Existing ImageView.app
  --identity IDENTITY    Developer ID Application identity (default: ad-hoc)
  --notary-profile NAME  notarytool Keychain profile; enables submit and staple
Credentials are read from Keychain, never from source files or command-line passwords.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="${2:?Missing --app value}"; shift 2 ;;
        --identity) SIGN_IDENTITY="${2:?Missing --identity value}"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="${2:?Missing --notary-profile value}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ "$APP_PATH" == /* ]] || APP_PATH="$PWD/$APP_PATH"
[[ -f "$APP_PATH/Contents/MacOS/ImageView" ]] || { echo "Missing app executable: $APP_PATH" >&2; exit 1; }
if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires a Developer ID Application certificate." >&2
    exit 2
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$APP_PATH"
else
    # Hardened Runtime 和可信时间戳是 Developer ID 公证的前提。
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
    mkdir -p "$PROJECT_ROOT/.build"
    NOTARY_STAGE="$(mktemp -d "$PROJECT_ROOT/.build/notarization.XXXXXX")"
    trap 'rm -rf "$NOTARY_STAGE"' EXIT
    ditto -c -k --keepParent "$APP_PATH" "$NOTARY_STAGE/ImageView.zip"
    if ! xcrun notarytool submit "$NOTARY_STAGE/ImageView.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_STAGE/result.json"; then
        cat "$NOTARY_STAGE/result.json" >&2
        exit 1
    fi
    NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_STAGE/result.json")"
    if [[ "$NOTARY_STATUS" != Accepted ]]; then
        cat "$NOTARY_STAGE/result.json" >&2
        echo "Notarization did not succeed. Use notarytool log with the returned submission ID." >&2
        exit 1
    fi
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi
