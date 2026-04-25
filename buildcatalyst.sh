#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Shirox
SCHEME_NAME="Shirox_MacCatalyst"

if [ ! -d "$WORKING_LOCATION/$APPLICATION_NAME.xcworkspace" ]; then
    echo "--- Workspace not found, running pod install ---"
    pod install
fi

if [ ! -d "build" ]; then
    mkdir build
fi

# CocoaPods injects -framework GoogleCast into OTHER_LDFLAGS for all platforms,
# but GoogleCast has no Catalyst slice. Strip it from the xcconfig before linking
# and restore it afterward so iOS builds are unaffected.
XCCONFIG_DIR="$WORKING_LOCATION/Pods/Target Support Files/Pods-Shirox_iOS"
XCCONFIG_RELEASE="$XCCONFIG_DIR/Pods-Shirox_iOS.release.xcconfig"
XCCONFIG_BAK="${XCCONFIG_RELEASE}.catalyst_bak"

if [ -f "$XCCONFIG_RELEASE" ]; then
    cp "$XCCONFIG_RELEASE" "$XCCONFIG_BAK"
    sed -i '' 's/ -framework "GoogleCast"//g; s/ -framework GoogleCast//g' "$XCCONFIG_RELEASE"
fi

restore_xcconfig() {
    if [ -f "$XCCONFIG_BAK" ]; then
        mv "$XCCONFIG_BAK" "$XCCONFIG_RELEASE"
    fi
}
trap restore_xcconfig EXIT

echo "--- Building $APPLICATION_NAME for Mac Catalyst ---"

xcodebuild -workspace "$WORKING_LOCATION/$APPLICATION_NAME.xcworkspace" \
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
hdiutil create \
    -volname "$APPLICATION_NAME" \
    -srcfolder "$DD_APP_PATH" \
    -ov \
    -format UDZO \
    "build/$APPLICATION_NAME-Catalyst.dmg"

echo "--- Success: build/$APPLICATION_NAME-Catalyst.dmg created ---"
