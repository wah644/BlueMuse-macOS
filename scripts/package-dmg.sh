#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export BUILD_ARCHS="${BUILD_ARCHS:-universal}"
identity="${SIGNING_IDENTITY:--}"
notarize="${NOTARIZE:-0}"
[[ "$notarize" == 0 || "$notarize" == 1 ]] || { echo 'NOTARIZE must be 0 or 1' >&2; exit 1; }
if [[ "$notarize" == 1 && ( "$identity" == '-' || -z "${NOTARY_PROFILE:-}" ) ]]; then
  echo 'Notarization requires SIGNING_IDENTITY and NOTARY_PROFILE. No credentials are stored by this script.' >&2
  exit 1
fi
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then bash scripts/build-app.sh; fi
app="dist/BlueMuse.app"
[[ -f "$app/Contents/MacOS/BlueMuseMac" ]] || { echo 'Build the app first' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/BlueMuseMac")"
if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then arch_label=universal
elif [[ "$archs" == arm64 ]]; then arch_label=arm64
elif [[ "$archs" == x86_64 ]]; then arch_label=x86_64
else echo "Unexpected executable architectures: $archs" >&2; exit 1; fi
suffix='-unnotarized'
if [[ "$notarize" == 1 ]]; then suffix=''; fi
image="dist/BlueMuse-macOS-$version-$arch_label$suffix.dmg"
staging="$(mktemp -d "${TMPDIR:-/tmp}/bluemuse-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/BlueMuse.app"
ln -s /Applications "$staging/Applications"
license_file=LICENSE
if [[ ! -f "$license_file" ]]; then license_file=../LICENSE; fi
cp "$license_file" "$staging/LICENSE.txt"
cat > "$staging/INSTALL.txt" <<TEXT
BlueMuse for macOS $version

INSTALL
1. Drag BlueMuse.app to the Applications shortcut beside it.
2. Eject this disk image, then open BlueMuse from Applications.
3. Allow Bluetooth permission, power on your Muse, and select your headset.
4. Start Stream publishes the sensor streams; Start MUSE_4CH publishes four EEG channels.

A receiver or classifier subscribes separately. No Python, Xcode, Homebrew or account
is required to run this app. Requires macOS 13 or newer.

DISTRIBUTION STATUS
This image is $([[ "$notarize" == 1 ]] && echo 'submitted for Apple notarization as part of packaging' || echo 'ad-hoc/locally signed and NOT notarized by Apple').
An unnotarized Internet download may be blocked on first launch. Users who trust
this source can follow Apple's per-app approval instructions in Privacy & Security:
https://support.apple.com/en-us/102445
Managed Macs may prohibit that exception. No system-wide security changes are required.

SOURCE AND LICENSE
GPL-3.0. Corresponding source: ${SOURCE_REPOSITORY:-the repository/source distribution accompanying this release}
Original Windows BlueMuse: https://github.com/kowalej/BlueMuse
liblsl has separate licenses in BlueMuse.app/Contents/Resources.
TEXT
/usr/bin/hdiutil create -volname "BlueMuse $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$image"
if [[ "$identity" != '-' ]]; then /usr/bin/codesign --force --timestamp --sign "$identity" "$image"; fi
if [[ "$notarize" == 1 ]]; then
  xcrun notarytool submit "$image" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > dist/notarization-result.json
  python3 -c 'import json; r=json.load(open("dist/notarization-result.json")); assert r["status"] == "Accepted", "Apple did not accept notarization: " + r["status"]'
  xcrun stapler staple "$image"
  xcrun stapler validate "$image"
fi
/usr/bin/hdiutil verify "$image"
base="$(basename "$image")"
(cd dist && /usr/bin/shasum -a 256 "$base" > "$base.sha256")
python3 - "$image" "$version" "$arch_label" "$notarize" "$identity" <<'PY'
import datetime,hashlib,json,os,pathlib,sys
image,version,arch,notarized,identity=sys.argv[1:]
p=pathlib.Path(image)
manifest={'application':'BlueMuse for macOS','version':version,'architecture':arch,'minimum_macos':'13.0','signature':'ad-hoc' if identity=='-' else 'Developer ID','notarized':notarized=='1','sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'source_repository':os.environ.get('SOURCE_REPOSITORY',''),'built_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
p.with_suffix('.dmg.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
printf '%s\n' "$image" > dist/release-artifact.txt
cat > dist/RELEASE-NOTES.md <<TEXT
## BlueMuse for macOS $version

Download **$base**, open it, and drag **BlueMuse.app** into **Applications**.
Requires **macOS 13+**. Architecture: **$arch_label**. No Python or developer tools are required to run it.

**Signing status:** $([[ "$notarize" == 1 ]] && echo 'Developer ID signed and Apple notarized.' || echo 'UNNOTARIZED preview build. An integrity signature is present, but Apple has not notarized the app. Gatekeeper may require manual per-app approval in Privacy & Security. Managed Macs may block installation.')

[Apple first-launch guidance](https://support.apple.com/en-us/102445).
A SHA-256 checksum and distribution-status manifest are attached.

Experimental community macOS adaptation of [kowalej/BlueMuse](https://github.com/kowalej/BlueMuse).
Muse 2 has been physically tested on Apple Silicon. Intel is cross-compiled; execution on Intel and other headset models still needs validation. Athena remains experimental.

Source and GPL-3.0 license are available in this repository's corresponding tag.
TEXT
echo "DMG ready: $PWD/$image"
