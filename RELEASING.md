# Downloadable macOS releases

The project can produce a self-contained, drag-to-Applications DMG. Users do not
need Python, Xcode, Homebrew or an Apple Developer account to install the app.

The current package is **unnotarized** and uses an ad-hoc integrity signature.
This is not a Developer ID identity and is not Apple's approval of the software.
Gatekeeper may block an Internet download on first launch. A user who trusts the
release may be able to approve the individual app through Privacy & Security,
following https://support.apple.com/en-us/102445. Managed Macs may prohibit this.
The installer does not disable security checks or remove quarantine attributes.

## Build a DMG locally

```sh
VERSION=1.0.0 bash scripts/package-dmg.sh
```

The default is a universal app containing both `arm64` and `x86_64` executable
slices. A normal `scripts/build-app.sh` invocation still makes a native development
build; `BUILD_ARCHS=arm64` or `BUILD_ARCHS=x86_64` can explicitly choose one architecture.
Cross-compiling Intel code does not establish that the app has been runtime-tested
on an Intel Mac. macOS 13+ is required.

Generated files in `dist/`:

- `BlueMuse-macOS-<version>-universal-unnotarized.dmg` — actual app download.
- The same filename plus `.sha256` — download integrity checksum.
- The same filename plus `.json` — version, architecture and signing/notarization status.
- `RELEASE-NOTES.md` — copyable GitHub release notes.
- `BlueMuse.app` — the built application bundle.

Open the DMG, drag BlueMuse.app to Applications, eject the image and open the app
from Applications. The image also includes the project license and install notes.
The app bundle contains both BlueMuse and liblsl notices.

To verify a downloaded image, keep its checksum file beside it and run:

```sh
shasum -a 256 -c BlueMuse-macOS-1.0.0-universal-unnotarized.dmg.sha256
```

A matching checksum verifies bytes against the published checksum, not developer
identity or malware safety. The manifest explicitly reports `notarized: false`.

## Put the download in GitHub Releases

1. Push this project folder to your own GitHub repository. The existing `.gitignore`
   excludes `dist/`, build caches, recordings and private configuration.
2. Make sure GitHub Actions is enabled.
3. Commit the release source and push a numeric version tag, for example:

```sh
git tag v1.0.0
git push origin v1.0.0
```

4. The `Build downloadable macOS release` workflow runs the tests, builds the
   universal DMG, and creates a **draft prerelease** with the DMG, checksum and
   manifest attached. It uses the repository's automatically supplied GitHub token.
5. Go to **Releases**, review the draft and its signing-status note, then publish it.

Existing releases are not overwritten. For a new build, make a new version tag;
if deliberately retrying a failed draft, review and remove that draft first.
GitHub's automatic Source code ZIP/TAR downloads are source archives, not the app.

No Terminal is required for the manual upload path: in GitHub, choose Releases →
Draft a new release, select/create the source tag, and attach
all three generated DMG/checksum/manifest files. Copy `dist/RELEASE-NOTES.md` into
the description. Publish the corresponding source tag with the binary so users
can obtain the GPL-3.0 source. Keep an unnotarized download clearly labelled.

## Future Developer ID signing and notarization

Making a DMG itself does not require Apple's developer program. The normal Apple
Developer ID / notarization distribution path requires an appropriate Developer ID
Application certificate and access to Apple's notarization service:
https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

The local scripts support this path if you obtain those prerequisites later:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-keychain-profile' \
NOTARIZE=1 VERSION=1.0.0 bash scripts/package-dmg.sh
```

Provision the certificate and notarization profile separately using Apple's tools.
The scripts do not collect or store passwords, private keys or Apple account details.
They sign the nested framework and app with hardened runtime and a secure timestamp,
sign the DMG, submit it using `notarytool`, require an Accepted result, and staple
and validate the ticket. Only then is the manifest marked notarized. This path is
implemented but has not been exercised here because no Developer ID certificate
is installed. The default GitHub workflow produces unnotarized drafts; it does not
implicitly gain access to a developer account or signing keys.

Test public downloads on a separate Mac, ideally through the actual browser download
and quarantine/Gatekeeper path. Local signing verification alone is not a successful
first-launch test on another person's machine.
