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
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$DD_APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APPLICATION_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$APPLICATION_NAME.dmg"

rm -rf "$DMG_STAGING"

echo "--- Success: build/$APPLICATION_NAME.dmg created ---"
