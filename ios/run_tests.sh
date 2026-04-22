#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Regenerate Xcode project from project.yml
echo "=== Regenerating Xcode project ==="
xcodegen generate

# Determine destination
DESTINATION=""
SCHEME=""
DEVICE_ID=""

if [ "${1:-}" = "device" ]; then
    # Find connected iPhone
    DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -m1 "iPhone" | sed 's/.*(\([A-F0-9-]*\)).*/\1/' || true)
    if [ -z "$DEVICE_ID" ]; then
        echo "No connected iPhone found. Falling back to simulator."
    else
        DESTINATION="id=$DEVICE_ID"
        SCHEME="TranslatorApp"
        echo "=== Running tests on device: $DEVICE_ID ==="
    fi
fi

if [ -z "$DESTINATION" ]; then
    # Find available iOS simulator
    SIMULATOR_ID=$(xcrun simctl list devices available | grep -m1 "iPhone" | sed 's/.*(\([A-F0-9-]*\)).*/\1/' || true)
    if [ -z "$SIMULATOR_ID" ]; then
        echo "ERROR: No available simulator found."
        exit 1
    fi
    DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
    SCHEME="TranslatorApp"
    echo "=== Running tests on simulator: $SIMULATOR_ID ==="
fi

# Run unit tests
echo ""
echo "=== Running unit tests ==="
set +e
xcodebuild test \
    -project TranslatorApp.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing:"TranslatorAppTests" \
    CODE_SIGNING_ALLOWED=NO \
    | xcpretty --color 2>/dev/null || xcodebuild test \
    -project TranslatorApp.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing:"TranslatorAppTests" \
    CODE_SIGNING_ALLOWED=NO

TEST_RESULT=$?
set -e

if [ $TEST_RESULT -eq 0 ]; then
    echo ""
    echo "=== All tests passed! ==="
else
    echo ""
    echo "=== Some tests failed ==="
    exit 1
fi
