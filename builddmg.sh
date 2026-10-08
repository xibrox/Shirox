#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Shirox
SCHEME_NAME="Shirox_macOS"

if [ ! -d "build" ]; then
   mkdir build
fi

cd build

# APP_PATH skips the build and packages an app that's already built.
if [ -z "$APP_PATH" ]; then
    echo "--- Resolving Swift Package Dependencies ---"

    xcodebuild -resolvePackageDependencies \
       -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
       -scheme "$SCHEME_NAME"

    echo "--- Building $APPLICATION_NAME for macOS ---"

    xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
       -scheme "$SCHEME_NAME" \
       -configuration Release \
       -derivedDataPath "$WORKING_LOCATION/build/DerivedDataMac" \
       -destination 'generic/platform=macOS' \
       -skipPackagePluginValidation \
       clean build \
       CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

    APP_PATH="$WORKING_LOCATION/build/DerivedDataMac/Build/Products/Release/$APPLICATION_NAME.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Build failed, .app not found at $APP_PATH"
    exit 1
fi

echo "--- Signing (ad hoc) ---"

# Unsigned, a downloaded app on Apple silicon is reported as damaged and won't open at all.
# Signed ad hoc, it opens after the usual right-click › Open (or `xattr -cr`).
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "--- Packaging DMG ---"

DMG_FINAL="$WORKING_LOCATION/build/${APPLICATION_NAME}-macOS.dmg"

if ! command -v create-dmg &> /dev/null; then
    echo "--- Installing create-dmg ---"
    brew install create-dmg
fi

rm -f "$DMG_FINAL"

create-dmg \
    --volname "$APPLICATION_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "${APPLICATION_NAME}.app" 150 180 \
    --hide-extension "${APPLICATION_NAME}.app" \
    --app-drop-link 430 180 \
    "$DMG_FINAL" \
    "$APP_PATH"

echo "--- Success: build/$APPLICATION_NAME-macOS.dmg created ---"
