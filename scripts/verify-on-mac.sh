#!/bin/bash
# Builds locally on a Mac. Does not install, sign, publish, or delete app data.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Mensur requires macOS and full Xcode for Apple SDK builds. Run this on your Mac."
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Install full Xcode, open it once, and complete its setup."
  echo "Select Xcode in Xcode > Settings > Locations > Command Line Tools."
  exit 1
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || \
   ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  echo "Install Xcode's iOS platform support in Settings > Components (Platforms in some versions)."
  exit 1
fi
run_dir="build-logs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$run_dir"
trap 'echo "Verification stopped. Review the failing command and logs in $run_dir." >&2' ERR
{
  date -u
  sw_vers
  xcode-select -p
  xcodebuild -version
  xcrun swift --version
  xcodebuild -showsdks
} 2>&1 | tee "$run_dir/environment.log"
echo "1/3: Running core geometry and export tests"
xcrun --sdk macosx swift test 2>&1 | tee "$run_dir/core-tests.log"
echo "2/3: Building the iOS Simulator app (unsigned)"
xcodebuild -project Mensur.xcodeproj -scheme Mensur -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-ios -resultBundlePath "$run_dir/simulator.xcresult" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$run_dir/simulator-build.log"
echo "3/3: Building the iPhone app (unsigned; installation uses Xcode signing)"
xcodebuild -project Mensur.xcodeproj -scheme Mensur -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build-device -resultBundlePath "$run_dir/device.xcresult" \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$run_dir/device-build.log"
echo "PASS: core tests and both unsigned builds. Logs: $run_dir"
echo "Next: open Mensur.xcodeproj, set your signing team, and run on your LiDAR iPhone."
echo "Scanning, exports, and accuracy still require the checks in docs/DEVICE_TESTS.md."
