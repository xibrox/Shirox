#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Shirox
SCHEME_NAME="Shirox_tvOS"

PROJECT_PATH="$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj"

if [ ! -d "build" ]; then
   mkdir build
fi

cd build

echo "--- Resolving Swift Package Dependencies ---"

xcodebuild -resolvePackageDependencies \
   -project "$PROJECT_PATH" \
   -scheme "$SCHEME_NAME"

echo "--- Building $APPLICATION_NAME for tvOS ---"

xcodebuild -project "$PROJECT_PATH" \
   -scheme "$SCHEME_NAME" \
   -configuration Release \
   -derivedDataPath "$WORKING_LOCATION/build/DerivedDataTVOS" \
   -destination 'generic/platform=tvOS' \
   -skipPackagePluginValidation \
   clean build \
   CODE_SIGN_IDENTITY="" \
   CODE_SIGNING_REQUIRED=NO \
   CODE_SIGN_ENTITLEMENTS="" \
   CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataTVOS/Build/Products/Release-appletvos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"

if [ ! -d "$DD_APP_PATH" ]; then
    echo "Error: Build failed, .app not found at $DD_APP_PATH"
    exit 1
fi

cp -r "$DD_APP_PATH" "$TARGET_APP"

echo "--- Removing code signature ---"
codesign --remove "$TARGET_APP"

if [ -e "$TARGET_APP/_CodeSignature" ]; then
   rm -rf "$TARGET_APP/_CodeSignature"
fi

if [ -e "$TARGET_APP/embedded.mobileprovision" ]; then
   rm -rf "$TARGET_APP/embedded.mobileprovision"
fi

echo "--- Packaging IPA ---"

mkdir Payload
cp -r "$APPLICATION_NAME.app" "Payload/$APPLICATION_NAME.app"

strip "Payload/$APPLICATION_NAME.app/$APPLICATION_NAME"

zip -vr "$APPLICATION_NAME-tvos.ipa" Payload

rm -rf "$APPLICATION_NAME.app"
rm -rf Payload

echo "--- Success: build/$APPLICATION_NAME-tvos.ipa created ---"