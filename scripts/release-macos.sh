#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_name="Codex Token Bar"
executable_name="CodexTokenBar"
bundle_id="${BUNDLE_ID:-io.github.zzzxtnt.codexlocaltokenbar}"
minimum_macos_version="${MINIMUM_MACOS_VERSION:-13.0}"

usage() {
    /bin/cat <<'EOF'
Build, sign, notarize, staple, and package a universal macOS release.

Required environment variables:
  RELEASE_VERSION     Release label without a leading "v", for example
                      0.1.0.
  BUILD_NUMBER        Numeric CFBundleVersion, for example 2.
  SIGNING_IDENTITY    Full Developer ID Application identity as shown by
                      `security find-identity -v -p codesigning`.
  NOTARY_PROFILE      notarytool Keychain profile created with
                      `xcrun notarytool store-credentials`.

Optional environment variables:
  BUNDLE_SHORT_VERSION  Numeric CFBundleShortVersionString. Defaults to the
                        portion of RELEASE_VERSION before the first hyphen.
  BUNDLE_ID             Defaults to io.github.zzzxtnt.codexlocaltokenbar.
  MINIMUM_MACOS_VERSION Defaults to 13.0.
  KEEP_RELEASE_WORK_DIR Set to 1 to retain intermediate files for debugging.

Example:
  RELEASE_VERSION=0.1.0 \
  BUILD_NUMBER=1 \
  SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
  NOTARY_PROFILE=codex-token-bar \
  ./scripts/release-macos.sh

The final files are written to dist/:
  CodexTokenBar-v<version>-universal.dmg
  SHA256SUMS.txt
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if (( $# != 0 )); then
    usage >&2
    exit 64
fi

die() {
    print -u2 -r -- "error: $*"
    exit 1
}

log() {
    print -r -- "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

release_version="${RELEASE_VERSION:-}"
build_number="${BUILD_NUMBER:-}"
signing_identity="${SIGNING_IDENTITY:-}"
notary_profile="${NOTARY_PROFILE:-}"

[[ -n "$release_version" ]] || die "RELEASE_VERSION is required"
[[ -n "$build_number" ]] || die "BUILD_NUMBER is required"
[[ -n "$signing_identity" ]] || die "SIGNING_IDENTITY is required"
[[ -n "$notary_profile" ]] || die "NOTARY_PROFILE is required"
[[ "$release_version" != v* ]] || die "RELEASE_VERSION must not include a leading v"

bundle_short_version="${BUNDLE_SHORT_VERSION:-${release_version%%-*}}"

/usr/bin/grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$' <<< "$release_version" || \
    die "RELEASE_VERSION contains unsupported filename characters"
/usr/bin/grep -Eq '^[0-9]+([.][0-9]+){0,2}$' <<< "$bundle_short_version" || \
    die "BUNDLE_SHORT_VERSION must contain one to three numeric components"
/usr/bin/grep -Eq '^[0-9]+([.][0-9]+){0,2}$' <<< "$build_number" || \
    die "BUILD_NUMBER must contain one to three numeric components"

if [[ "$signing_identity" != "Developer ID Application:"* ]]; then
    die "SIGNING_IDENTITY must be a Developer ID Application identity"
fi

for required_command in swift lipo plutil codesign ditto hdiutil xcrun spctl \
    shasum security mktemp; do
    require_command "$required_command"
done

installed_identities=$(/usr/bin/security find-identity -v -p codesigning 2>&1)
if [[ "$installed_identities" != *"$signing_identity"* ]]; then
    die "SIGNING_IDENTITY is not installed in the current Keychain"
fi

dist_dir="$project_dir/dist"
artifact_stem="CodexTokenBar-v${release_version}-universal"
dmg_name="${artifact_stem}.dmg"
dmg_path="$dist_dir/$dmg_name"
checksum_path="$dist_dir/SHA256SUMS.txt"

if [[ -e "$dmg_path" || -e "$checksum_path" ]]; then
    die "release artifact already exists for $release_version; move it before retrying"
fi

/bin/mkdir -p "$project_dir/.build" "$dist_dir"
work_dir=$(/usr/bin/mktemp -d "$project_dir/.build/macos-release.XXXXXX")
working_dmg_path="$work_dir/$dmg_name"

cleanup() {
    if [[ "${KEEP_RELEASE_WORK_DIR:-0}" == "1" ]]; then
        print -r -- "Intermediate files kept at: $work_dir"
    else
        /bin/rm -rf -- "$work_dir"
    fi
}
trap cleanup EXIT

built_binary=""
build_for_architecture() {
    local architecture="$1"
    local scratch_path="$work_dir/build-$architecture"
    local module_cache_path="$scratch_path/module-cache"
    local binary_dir

    /bin/mkdir -p "$module_cache_path"
    log "Building $architecture"
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_path" \
    CLANG_MODULE_CACHE_PATH="$module_cache_path" \
    MACOSX_DEPLOYMENT_TARGET="$minimum_macos_version" \
        swift build \
        --configuration release \
        --arch "$architecture" \
        --scratch-path "$scratch_path" \
        --disable-sandbox

    binary_dir=$(SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_path" \
        CLANG_MODULE_CACHE_PATH="$module_cache_path" \
        MACOSX_DEPLOYMENT_TARGET="$minimum_macos_version" \
        swift build \
        --configuration release \
        --arch "$architecture" \
        --scratch-path "$scratch_path" \
        --disable-sandbox \
        --show-bin-path)

    built_binary="$binary_dir/$executable_name"
    [[ -x "$built_binary" ]] || die "$architecture executable was not produced"
}

build_for_architecture arm64
arm64_binary="$built_binary"
build_for_architecture x86_64
x86_64_binary="$built_binary"

app_dir="$work_dir/$app_name.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
info_plist="$contents_dir/Info.plist"
universal_binary="$macos_dir/$executable_name"

/bin/mkdir -p "$macos_dir"
log "Creating universal application bundle"
/usr/bin/lipo -create "$arm64_binary" "$x86_64_binary" -output "$universal_binary"
/bin/chmod 755 "$universal_binary"

binary_architectures=$(/usr/bin/lipo -archs "$universal_binary")
[[ "$binary_architectures" == *arm64* ]] || die "universal executable is missing arm64"
[[ "$binary_architectures" == *x86_64* ]] || die "universal executable is missing x86_64"

/usr/bin/plutil -create xml1 "$info_plist"
/usr/bin/plutil -replace CFBundleName -string "$app_name" "$info_plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$info_plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$info_plist"
/usr/bin/plutil -replace CFBundleExecutable -string "$executable_name" "$info_plist"
/usr/bin/plutil -replace CFBundlePackageType -string APPL "$info_plist"
/usr/bin/plutil -replace CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$bundle_short_version" "$info_plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$info_plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string "$minimum_macos_version" "$info_plist"
/usr/bin/plutil -replace LSUIElement -bool true "$info_plist"
/usr/bin/plutil -lint "$info_plist"

log "Signing application with hardened runtime"
/usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$app_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"

notary_zip="$work_dir/${artifact_stem}.zip"
log "Submitting application for notarization"
/usr/bin/ditto -c -k --keepParent "$app_dir" "$notary_zip"
/usr/bin/xcrun notarytool submit "$notary_zip" \
    --keychain-profile "$notary_profile" \
    --wait

log "Stapling notarization ticket to application"
/usr/bin/xcrun stapler staple "$app_dir"
/usr/bin/xcrun stapler validate "$app_dir"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_dir"

dmg_root="$work_dir/dmg-root"
/bin/mkdir -p "$dmg_root"
/usr/bin/ditto "$app_dir" "$dmg_root/$app_name.app"
/bin/ln -s /Applications "$dmg_root/Applications"

log "Creating signed disk image"
/usr/bin/hdiutil create \
    -volname "$app_name" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$working_dmg_path"
/usr/bin/codesign \
    --force \
    --timestamp \
    --sign "$signing_identity" \
    "$working_dmg_path"
/usr/bin/codesign --verify --strict --verbose=2 "$working_dmg_path"

log "Submitting disk image for notarization"
/usr/bin/xcrun notarytool submit "$working_dmg_path" \
    --keychain-profile "$notary_profile" \
    --wait

log "Stapling and validating disk image"
/usr/bin/xcrun stapler staple "$working_dmg_path"
/usr/bin/xcrun stapler validate "$working_dmg_path"
/usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$working_dmg_path"

log "Writing SHA-256 checksum"
/usr/bin/ditto "$working_dmg_path" "$dmg_path"
checksum_output=$(/usr/bin/shasum -a 256 "$dmg_path")
checksum="${checksum_output%% *}"
print -r -- "$checksum  $dmg_name" > "$checksum_path"

print -r -- "Release ready:"
print -r -- "  $dmg_path"
print -r -- "  $checksum_path"
