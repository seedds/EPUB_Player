#!/bin/bash

set -euo pipefail

# Anchor all paths to the script's directory so running it from elsewhere can't
# `rm -rf` an unrelated build/ or export/ in the current working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

rm -rf "$SCRIPT_DIR/build/DerivedData" "$SCRIPT_DIR/export"
mkdir -p "$SCRIPT_DIR/.build/source-packages" "$SCRIPT_DIR/build" "$SCRIPT_DIR/export/Payload"

xcodebuild \
  -project "$SCRIPT_DIR/EPUB Player.xcodeproj" \
  -scheme "EPUB Player" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$SCRIPT_DIR/build/DerivedData" \
  -clonedSourcePackagesDirPath "$SCRIPT_DIR/.build/source-packages" \
  MARKETING_VERSION="${APP_VERSION:-1.0}" \
  CURRENT_PROJECT_VERSION="${APP_VERSION:-1.0}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

cp -R "$SCRIPT_DIR/build/DerivedData/Build/Products/Release-iphoneos/EPUBPlayer.app" "$SCRIPT_DIR/export/Payload/"
cd "$SCRIPT_DIR/export"
zip -r "EPUBPlayer-${APP_VERSION:-1.0}-unsigned.ipa" Payload
