#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
architecture="${BUILD_ARCHS:-native}"
identity="${SIGNING_IDENTITY:--}"
if [[ "$identity" != '-' && "$identity" != 'Developer ID Application:'* ]]; then echo 'Use a Developer ID Application identity, or - for ad-hoc signing' >&2; exit 1; fi
version="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
version="${version#v}"
build_number="${BUILD_NUMBER:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be a numeric version such as 1.0.0' >&2; exit 1; }
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric' >&2; exit 1; }
framework="Vendor/lsl.framework"
[[ -f "$framework/lsl" ]] || { echo 'Missing Vendor/lsl.framework; see Vendor/NOTICE.md' >&2; exit 1; }
args=(-c "$configuration" --product BlueMuseMac)
case "$architecture" in
  native) ;;
  universal) args+=(--arch arm64 --arch x86_64) ;;
  arm64|x86_64) args+=(--arch "$architecture") ;;
  *) echo 'BUILD_ARCHS must be native, universal, arm64 or x86_64' >&2; exit 1 ;;
esac
swift build "${args[@]}"
bin_dir="$(swift build "${args[@]}" --show-bin-path)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/bluemuse-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/BlueMuse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources" dist
cp "$bin_dir/BlueMuseMac" "$app/Contents/MacOS/BlueMuseMac"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
/usr/bin/ditto "$framework" "$app/Contents/Frameworks/lsl.framework"
license_file="LICENSE"
if [[ ! -f "$license_file" ]]; then license_file="../LICENSE"; fi
cp "$license_file" "$app/Contents/Resources/BlueMuse-LICENSE.txt"
cp Vendor/LICENSE-liblsl.txt "$app/Contents/Resources/LSL-LICENSE.txt"
cp Vendor/NOTICE.md "$app/Contents/Resources/LSL-NOTICE.md"
if [[ -f UPSTREAM.md ]]; then cp UPSTREAM.md "$app/Contents/Resources/UPSTREAM.md"; fi
if [[ ! -f Resources/AppIcon.icns ]]; then
  mkdir -p Resources
  swift scripts/make-icon.swift "$staging/AppIcon.iconset"
  /usr/bin/iconutil -c icns "$staging/AppIcon.iconset" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
{
  echo "BlueMuse for macOS $version — derived from kowalej/BlueMuse."
  echo 'License: GPL-3.0. Corresponding source is in this release’s repository tag.'
  echo "Source repository: ${SOURCE_REPOSITORY:-See the repository distributing this release or the source folder supplied with this build.}"
  echo 'Original Windows project: https://github.com/kowalej/BlueMuse'
} > "$app/Contents/Resources/SOURCE.txt"
if [[ "$identity" == '-' ]]; then
  /usr/bin/codesign --force --sign - "$app/Contents/Frameworks/lsl.framework"
  /usr/bin/codesign --force --sign - "$app"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Frameworks/lsl.framework"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
if [[ "$architecture" == universal ]]; then
  /usr/bin/lipo "$app/Contents/MacOS/BlueMuseMac" -verify_arch arm64
  /usr/bin/lipo "$app/Contents/MacOS/BlueMuseMac" -verify_arch x86_64
fi
# dist/BlueMuse.app is generated build output, never a source or installed copy.
if [[ -e dist/BlueMuse.app ]]; then rm -rf dist/BlueMuse.app; fi
/usr/bin/ditto "$app" dist/BlueMuse.app
echo "Built: $PWD/dist/BlueMuse.app"
