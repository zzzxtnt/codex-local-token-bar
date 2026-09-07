#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

module_cache_dir="$project_dir/.build/module-cache"
mkdir -p "$module_cache_dir"
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_dir" \
CLANG_MODULE_CACHE_PATH="$module_cache_dir" \
swift build -c release --disable-sandbox

app_dir="$project_dir/dist/Codex Token Bar.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

mkdir -p "$macos_dir"
cp "$project_dir/.build/release/CodexTokenBar" "$macos_dir/CodexTokenBar"

/usr/libexec/PlistBuddy -c 'Clear dict' "$contents_dir/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Codex Token Bar' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Codex Token Bar' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.zzzxtnt.codexlocaltokenbar' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string CodexTokenBar' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.3' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 4' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$contents_dir/Info.plist"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
