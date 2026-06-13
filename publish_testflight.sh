#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/EPUB Player.xcodeproj"
SCHEME_NAME="EPUB Player"
APP_NAME="EPUB Player"
ARCHIVE_PRODUCT_NAME="EPUBPlayer"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_VERSION="${1:-}"
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

PBXPROJ_PATH="$PROJECT_PATH/project.pbxproj"

if [ ! -f "$PBXPROJ_PATH" ]; then
  printf 'Missing project file: %s\n' "$PBXPROJ_PATH" >&2
  exit 1
fi

# A supplied version must be MAJOR.MINOR.PATCH before it reaches xcodebuild
# and project.pbxproj.
if [ -n "$APP_VERSION" ] && ! printf '%s' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf 'Invalid version "%s". Expected MAJOR.MINOR.PATCH, e.g. ./publish_testflight.sh 2.0.0\n' "$APP_VERSION" >&2
  exit 1
fi

# The app target uses a three-component version (e.g. 1.0.5); the test target
# uses "1.0". Match only the three-component value to avoid touching the test
# target.
CURRENT_VERSION="$(grep -Eo 'MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+;' "$PBXPROJ_PATH" | head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -z "$CURRENT_VERSION" ]; then
  printf 'Could not read a MAJOR.MINOR.PATCH MARKETING_VERSION from %s\n' "$PBXPROJ_PATH" >&2
  exit 1
fi

# Resolve the marketing version: a supplied argument wins; otherwise the
# current patch component is incremented.
if [ -n "$APP_VERSION" ]; then
  TARGET_VERSION="$APP_VERSION"
  printf 'Using version from argument: %s\n' "$TARGET_VERSION"
else
  MAJOR="${CURRENT_VERSION%%.*}"
  REST="${CURRENT_VERSION#*.}"
  MINOR="${REST%%.*}"
  PATCH="${REST#*.}"
  TARGET_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
  printf 'Auto-bumped marketing version: %s -> %s\n' "$CURRENT_VERSION" "$TARGET_VERSION"
fi

# Persist the resolved version to the app target's three-component
# MARKETING_VERSION lines; the test target's "1.0" stays untouched.
if [ "$TARGET_VERSION" != "$CURRENT_VERSION" ]; then
  TMP_PBXPROJ="$(mktemp)"
  sed "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $TARGET_VERSION;/g" "$PBXPROJ_PATH" > "$TMP_PBXPROJ"
  mv "$TMP_PBXPROJ" "$PBXPROJ_PATH"
  printf 'Updated project.pbxproj marketing version to %s\n' "$TARGET_VERSION"
fi

APP_VERSION="$TARGET_VERSION"

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
