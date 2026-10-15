#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BIN_DIRECTORY="$(dirname "$(xcrun --find swiftc)")"
TEST_PLUGIN_DIRECTORY="$SWIFT_BIN_DIRECTORY/../lib/swift/host/plugins/testing"
TEST_ARGUMENTS=(--package-path "$PROJECT_ROOT" --disable-xctest)

# 部分新版 CLT 已附带 Testing.framework，但 SwiftPM 尚未自动加入其宏目录。
# 只为测试补充现有工具链路径，不在 Package.swift 硬编码本机路径。
if [[ -d "$TEST_PLUGIN_DIRECTORY" ]]; then
    TEST_ARGUMENTS+=(-Xswiftc -plugin-path -Xswiftc "$TEST_PLUGIN_DIRECTORY")
fi
exec swift test "${TEST_ARGUMENTS[@]}" "$@"
