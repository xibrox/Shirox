#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Shirox
SCHEME_NAME="Shirox_MacCatalyst"

if [ ! -d "build" ]; then
   mkdir build
fi

cd build

echo "--- Resolving Swift Package Dependencies ---"

xcodebuild -resolvePackageDependencies \
   -project "$PROJECT_PATH" \
   -scheme "$SCHEME_NAME"

echo "--- Building $APPLICATION_NAME for Mac Catalyst ---"

xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedDataCatalyst" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -skipPackagePluginValidation \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataCatalyst/Build/Products/Release-maccatalyst/$APPLICATION_NAME.app"

if [ ! -d "$DD_APP_PATH" ]; then
    echo "Error: Build failed, .app not found at $DD_APP_PATH"
    exit 1
fi

echo "--- Packaging DMG ---"

DMG_FINAL="$WORKING_LOCATION/build/${APPLICATION_NAME}-Catalyst.dmg"

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
    "$DD_APP_PATH"

echo "--- Success: build/$APPLICATION_NAME-Catalyst.dmg created ---"
