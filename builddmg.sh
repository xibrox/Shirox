#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Shirox
SCHEME_NAME="Shirox_macOS"

if [ ! -d "$WORKING_LOCATION/$APPLICATION_NAME.xcworkspace" ]; then
   echo "--- Workspace not found, running pod install ---"
   pod install
fi

if [ ! -d "build" ]; then
   mkdir build
fi

cd build

echo "--- Building $APPLICATION_NAME for macOS ---"

xcodebuild -workspace "$WORKING_LOCATION/$APPLICATION_NAME.xcworkspace" \
   -scheme "$SCHEME_NAME" \
   -configuration Release \
   -derivedDataPath "$WORKING_LOCATION/build/DerivedDataMac" \
   -destination 'generic/platform=macOS' \
   -skipPackagePluginValidation \
   clean build \
   CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataMac/Build/Products/Release/$APPLICATION_NAME.app"

if [ ! -d "$DD_APP_PATH" ]; then
    echo "Error: Build failed, .app not found at $DD_APP_PATH"
    exit 1
fi

echo "--- Packaging DMG ---"

DMG_STAGING="$WORKING_LOCATION/build/dmg-staging"
DMG_TEMP="$WORKING_LOCATION/build/${APPLICATION_NAME}-temp.dmg"
DMG_FINAL="$WORKING_LOCATION/build/${APPLICATION_NAME}.dmg"

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$DD_APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APPLICATION_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDRW \
    "$DMG_TEMP"

MOUNT_DIR=$(hdiutil attach "$DMG_TEMP" -readwrite -nobrowse | awk 'END {print $NF}')

osascript << APPLESCRIPT
tell application "Finder"
    tell disk "$APPLICATION_NAME"
        open
        delay 2
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 420}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        delay 1
        set position of item "${APPLICATION_NAME}.app" of container window to {125, 180}
        set position of item "Applications" of container window to {375, 180}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"

hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_FINAL" -ov
rm -f "$DMG_TEMP"
rm -rf "$DMG_STAGING"

echo "--- Success: build/$APPLICATION_NAME.dmg created ---"
