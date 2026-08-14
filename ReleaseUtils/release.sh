#!/bin/sh

set -eu

if [ -f "release.sh" ]; then 
	cd ..
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <version> (for example: 0.6.0)" >&2
    exit 2
fi

VERSION="${1#v}"
case "$VERSION" in
    ""|*[!0-9.]*)
        echo "Version must contain only digits and periods" >&2
        exit 2
        ;;
esac
OUTPUT_PREFIX="BingWallpaper_${VERSION}"

for REQUIRED_VARIABLE in \
    DEVELOPER_ID_APPLICATION_IDENTITY \
    DEVELOPER_ID_INSTALLER_IDENTITY \
    APPLE_ID \
    APPLE_APP_SPECIFIC_PASSWORD \
    APPLE_TEAM_ID
do
    eval "VARIABLE_VALUE=\${$REQUIRED_VARIABLE:-}"
    if [ -z "$VARIABLE_VALUE" ]; then
        echo "Missing required environment variable: $REQUIRED_VARIABLE" >&2
        exit 2
    fi
done

# Build
xcodebuild clean build \
    -project BingWallpaper.xcodeproj \
    -target BingWallpaper \
    -configuration Release \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    MARKETING_VERSION="$VERSION"

APP_PATH="build/Release/BingWallpaper.app"
ZIP_PATH="${OUTPUT_PREFIX}.zip"
PKG_PATH="${OUTPUT_PREFIX}.pkg"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Signed PKG
pkgbuild --component "$APP_PATH" \
         --scripts ReleaseUtils/ \
         --install-location /Applications \
         --sign "$DEVELOPER_ID_INSTALLER_IDENTITY" \
         "$PKG_PATH"
xcrun notarytool submit "$PKG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
xcrun stapler staple "$PKG_PATH"
xcrun stapler validate "$PKG_PATH"

shasum -a 256 "$PKG_PATH" > "$PKG_PATH.sha256"

echo "Created ${OUTPUT_PREFIX}.zip, ${OUTPUT_PREFIX}.pkg, and ${OUTPUT_PREFIX}.pkg.sha256"
