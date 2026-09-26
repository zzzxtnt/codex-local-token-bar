# Release checklist

This checklist is for maintainers publishing a downloadable macOS app. Ordinary
users should follow [INSTALL.md](INSTALL.md).

## Release requirements

- A clean checkout of the release commit
- A version tag such as `v0.1.0`
- Xcode and the Swift toolchain used by the project
- A valid `Developer ID Application` certificate in the signing Keychain
- Apple notarization credentials configured for `notarytool`
- A universal app containing both `arm64` and `x86_64`

Never commit certificate files, private keys, Apple credentials, Keychain
profiles, notarization logs that contain account information, or exported
environment files.

## Before packaging

1. Update the app version/build number, `CHANGELOG.md`, and user-facing docs.
2. Run the tests:

   ```sh
   swift test --disable-sandbox
   ```

3. Commit the tested changes and create the release tag. Confirm
   `git status --short` is empty and the tag points to that commit.
4. Build the release from the tagged commit. Do not publish the ad-hoc-signed
   output from `scripts/build-app.sh` as an official binary.

Configure a local Keychain profile once. Omitting `--password` keeps the
app-specific password out of shell history and prompts for it securely:

```sh
xcrun notarytool store-credentials codex-token-bar \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

Then create the complete release. `RELEASE_VERSION` must not include the
leading `v` used by the Git tag:

```sh
RELEASE_VERSION=0.1.4 \
BUILD_NUMBER=8 \
SIGNING_IDENTITY="Developer ID Application: Your Organization (TEAMID)" \
NOTARY_PROFILE=codex-token-bar \
./scripts/release-macos.sh
```

The script builds both architectures, signs and notarizes the app and disk
image, staples the tickets, runs Gatekeeper checks, and writes the final `.dmg`
and `SHA256SUMS.txt` to `dist/`.

The script intentionally refuses to overwrite release artifacts. If `dist/`
contains a previous release's checksum, preserve it alongside that older disk
image in a separate directory before starting a new release.

## Required release properties

The distributed app must have all of the following:

- Bundle identifier `io.github.zzzxtnt.codexlocaltokenbar`
- `LSMinimumSystemVersion` of `13.0`
- `LSUIElement` enabled so the app remains a menu bar accessory
- A `Developer ID Application` signature with a secure timestamp
- Hardened Runtime enabled
- `arm64` and `x86_64` slices
- A successful Apple notarization result
- A stapled notarization ticket on the app and final disk image

Package the app in a read-only `.dmg`. The disk image should present the app and
an Applications shortcut so users can install it by dragging the app.

## Verify the final disk image

Run these checks against the exact `.dmg` that will be uploaded. Replace the
example path with the real release asset:

```sh
DMG_PATH="dist/CodexTokenBar-v0.1.0-universal.dmg"
hdiutil verify "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
```

Mount the disk image and set `APP_PATH` to the mounted app, then verify it:

```sh
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
lipo -archs "$APP_PATH/Contents/MacOS/CodexTokenBar"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist"
```

The `codesign` display must identify `Developer ID Application`, `spctl` must
accept the app, `stapler` must validate both artifacts, and `lipo` must list
`arm64 x86_64` (order is not important).

Create a checksum from the final, unmodified disk image:

```sh
cd dist
shasum -a 256 CodexTokenBar-v*-universal.dmg > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
```

If the disk image changes for any reason, submit/staple/verify it again and
regenerate the checksum.

## Smoke test

Test the final disk image on a Mac where this build has not been launched before:

1. Drag the app into Applications and launch it from Finder.
2. Confirm there is no Gatekeeper bypass or unexpected permission request.
3. Confirm the menu bar displays a value and the panel opens.
   No standalone empty Settings window should appear. Verify that the panel
   shrinks with shorter content and that long notices can still scroll.
4. Compare the displayed exact daily total with the live test or parity probe.
5. Enable Launch at Login and confirm macOS reports it as enabled.
6. Quit and reopen the app, then disable Launch at Login again.
7. Confirm no network requests or credential reads, and no modification of `~/.codex`.
8. Confirm quota is labelled as unverified history. Clear old quota: it must stay
   hidden across restart until a newer record appears; token totals must not change.
9. Verify notifications with synthetic log fixtures only: permission allowed/denied,
   two fresh events, duplicate events, source changes, and manual clearing. Do not
   consume real reset credits. Check system banners separately on the installed app.

## Publish on GitHub

Use a draft release so all assets exist before the `published` event runs:

- The signed and notarized `.dmg`
- `SHA256SUMS.txt`
- Release notes describing changes and known limitations
- A link to [INSTALL.md](INSTALL.md)

Mark beta builds as prereleases. Publish only after the tag points at the tested
commit and the uploaded asset checksums match the local files. The
`Verify release assets` workflow validates the downloaded checksum, disk image,
signature, notarization ticket, Gatekeeper result, architecture slices, and
bundle metadata. It can also be run manually for an existing tag.

## Release notes template

```markdown
## Highlights

- <user-visible change>

## Install

Download the `.dmg`, drag Codex Token Bar into Applications, and open it there.
The binary is Developer ID signed and notarized by Apple. See the
[installation guide](https://github.com/zzzxtnt/codex-local-token-bar/blob/main/docs/INSTALL.md)
for checksum and Gatekeeper verification.

## Verify

Download `SHA256SUMS.txt` beside the `.dmg`, then run:

    shasum -a 256 -c SHA256SUMS.txt

## Notes

- The total is derived from local Codex session logs. It is not an invoice,
  subscription quota, or remaining-credit counter.
- Codex's local JSONL format is not a guaranteed stable public API.
```
