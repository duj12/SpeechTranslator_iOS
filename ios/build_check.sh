#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== Regenerating Xcode project ==="
xcodegen generate

echo "=== Building for iOS (no code signing) ==="
set +e
xcodebuild build \
    -project TranslatorApp.xcodeproj \
    -scheme TranslatorApp \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    | tail -20

BUILD_RESULT=${PIPESTATUS[0]}
set -e

if [ $BUILD_RESULT -eq 0 ]; then
    echo ""
    echo "=== Build succeeded! ==="
else
    echo ""
    echo "=== Build failed ==="
    exit 1
fi
