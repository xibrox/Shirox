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

# CocoaPods injects -framework GoogleCast and its resources into the build phases,
# but GoogleCast has no Catalyst slice. Strip them from the Pods files before 
# building and restore them afterward so iOS builds are unaffected.
XCCONFIG_DIR="$WORKING_LOCATION/Pods/Target Support Files/Pods-Shirox_iOS"
FILES_TO_PATCH=(
    "Pods-Shirox_iOS.release.xcconfig"
    "Pods-Shirox_iOS.debug.xcconfig"
    "Pods-Shirox_iOS-resources.sh"
    "Pods-Shirox_iOS-resources-Release-input-files.xcfilelist"
    "Pods-Shirox_iOS-resources-Release-output-files.xcfilelist"
    "Pods-Shirox_iOS-resources-Debug-input-files.xcfilelist"
    "Pods-Shirox_iOS-resources-Debug-output-files.xcfilelist"
)

for file in "${FILES_TO_PATCH[@]}"; do
    FILE_PATH="$XCCONFIG_DIR/$file"
    if [ -f "$FILE_PATH" ]; then
        cp "$FILE_PATH" "${FILE_PATH}.catalyst_bak"
        if [[ $file == *.xcconfig ]]; then
            sed -i '' 's/ -framework "GoogleCast"//g; s/ -framework GoogleCast//g' "$FILE_PATH"
        else
            sed -i '' '/GoogleCast/d; /google-cast-sdk/d' "$FILE_PATH"
        fi
    fi
done

restore_pod_files() {
    for file in "${FILES_TO_PATCH[@]}"; do
        FILE_PATH="$XCCONFIG_DIR/$file"
        if [ -f "${FILE_PATH}.catalyst_bak" ]; then
            mv "${FILE_PATH}.catalyst_bak" "$FILE_PATH"
        fi
    done
}
trap restore_pod_files EXIT

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
