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

# Build
xcodebuild clean build \
    -project BingWallpaper.xcodeproj \
    -target BingWallpaper \
    -configuration Release \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$VERSION"

# ZIP
cd ./build/Release/
zip -r "../../${OUTPUT_PREFIX}.zip" ./BingWallpaper.app
cd ../../

# PKG
cd ./build/Release/
pkgbuild --component BingWallpaper.app \
         --scripts ../../ReleaseUtils/ \
         --install-location /Applications \
         "../../${OUTPUT_PREFIX}.pkg"
cd ../../

shasum -a 256 "${OUTPUT_PREFIX}.pkg" > "${OUTPUT_PREFIX}.pkg.sha256"

echo "Created ${OUTPUT_PREFIX}.zip, ${OUTPUT_PREFIX}.pkg, and ${OUTPUT_PREFIX}.pkg.sha256"
