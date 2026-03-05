#!/bin/bash

#shamelessly copied from https://github.com/cranci1/Sora/blob/dev/ipabuild.sh with minor changes

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Shirox
SCHEME_NAME="Shirox_iOS"

if [ ! -d "build" ]; then
   mkdir build
fi

cd build

echo "--- Building $APPLICATION_NAME for iOS ---"

xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
   -scheme "$SCHEME_NAME" \
   -configuration Release \
   -derivedDataPath "$WORKING_LOCATION/build/DerivedDataApp" \
   -destination 'generic/platform=iOS' \
   -skipPackagePluginValidation \
   clean build \
   CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataApp/Build/Products/Release-iphoneos/$APPLICATION_NAME.app"
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
zip -vr "$APPLICATION_NAME.ipa" Payload

rm -rf "$APPLICATION_NAME.app"
rm -rf Payload

echo "--- Success: build/$APPLICATION_NAME.ipa created ---"
