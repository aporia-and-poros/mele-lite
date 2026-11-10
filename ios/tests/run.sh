#!/bin/sh
# App 里不依赖界面的小零件，在 Mac 上直接编出来跑（App 没有单元测试工程）。用法：ios/tests/run.sh
set -e
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -swift-version 5 App/SendLine.swift tests/SendLineTests.swift -o "$out/send-line"
"$out/send-line"
