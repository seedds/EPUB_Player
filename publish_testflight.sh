#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/EPUB Player.xcodeproj"
SCHEME_NAME="EPUB Player"
APP_NAME="EPUB Player"
ARCHIVE_PRODUCT_NAME="EPUBPlayer"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_VERSION="${APP_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
TEAM_ID="${TEAM_ID:-9LK4YZ82JR}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$SCRIPT_DIR/build/testflight/$BUILD_NUMBER}"
ARCHIVE_PATH="$ARTIFACT_ROOT/$ARCHIVE_PRODUCT_NAME.xcarchive"
EXPORT_PATH="$ARTIFACT_ROOT/export"
EXPORT_OPTIONS_PLIST="$ARTIFACT_ROOT/ExportOptions.plist"
SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -d "$DEVELOPER_DIR" ]; then
  printf 'Missing Xcode developer directory: %s\n' "$DEVELOPER_DIR" >&2
  exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
  printf 'Missing project: %s\n' "$PROJECT_PATH" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_ROOT" "$EXPORT_PATH"

cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>upload</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

printf 'Archiving %s\n' "$APP_NAME"
printf 'Version: %s\n' "${APP_VERSION:-project default}"
printf 'Build: %s\n' "$BUILD_NUMBER"
printf 'Artifacts: %s\n' "$ARTIFACT_ROOT"

archive_command=(
  xcodebuild
  -project "$PROJECT_PATH"
  -scheme "$SCHEME_NAME"
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  -allowProvisioningUpdates
  archive
)

if [ -n "$APP_VERSION" ]; then
  archive_command+=(MARKETING_VERSION="$APP_VERSION")
fi

DEVELOPER_DIR="$DEVELOPER_DIR" "${archive_command[@]}"

printf 'Uploading archive to App Store Connect\n'

# Force Apple's rsync during IPA packaging. Homebrew rsync breaks Xcode exportArchive.
PATH="$SYSTEM_TOOL_PATH:$PATH" DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

printf 'Upload finished\n'
printf 'Archive: %s\n' "$ARCHIVE_PATH"
printf 'Export: %s\n' "$EXPORT_PATH"
