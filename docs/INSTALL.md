# Install Codex Token Bar

## Download and install

1. Go to [GitHub Releases](https://github.com/zzzxtnt/codex-local-token-bar/releases).
2. Choose the newest release that includes a `.dmg` file. A release described as
   **source-only** does not contain an installable app.
3. Download `CodexTokenBar-v<version>-universal.dmg` and
   `SHA256SUMS.txt` from the same release.
4. Open the disk image and drag **Codex Token Bar** into **Applications**.
5. Eject the disk image, then open **Applications → Codex Token Bar**.

Codex Token Bar is a menu bar accessory. It does not open a normal window or
show a Dock icon. Look for its token number on the right side of the macOS menu
bar and click the number to open its details.

Install the app in Applications before enabling Launch at Login. macOS records
the installed app's location when the login item is registered.

## Optional: verify the download

GitHub shows release assets separately. Download the checksum file into the same
folder as the `.dmg`, open Terminal in that folder, and run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

A successful check prints `OK`. Do not open the disk image if the checksum
fails.

After installation, macOS can also verify the app's Developer ID signature and
Apple notarization assessment:

```sh
codesign --verify --deep --strict --verbose=2 "/Applications/Codex Token Bar.app"
spctl --assess --type execute --verbose=4 "/Applications/Codex Token Bar.app"
```

`spctl` should report that the app is accepted and identify a notarized
Developer ID source.

## Gatekeeper messages

An official binary release should open normally because it is Developer ID
signed and notarized. If macOS says the developer cannot be verified, the app is
damaged, or the app should be moved to the Trash:

1. Delete that copy of the app and disk image.
2. Download the asset again from this repository's GitHub Releases page.
3. Verify its checksum and confirm that the release does not say source-only.
4. Make sure macOS has internet access, then try once more.

Do not disable Gatekeeper, remove quarantine attributes, or use an unsigned copy
from an unknown source. If a verified official download is still blocked, open
an issue with the app version, macOS version, Mac model/architecture, and the
exact Gatekeeper message. Do not attach Codex session logs.

## Launch at Login

1. Click Codex Token Bar in the menu bar.
2. Enable **登录时启动** (Launch at Login).
3. If the app says approval is required, open **System Settings → General →
   Login Items & Extensions** and allow Codex Token Bar under **Open at Login**.

To stop automatic startup, disable the switch in the app. You can also remove
or disable it in the same macOS Login Items settings. If you move the app after
enabling the setting, disable and enable Launch at Login again so macOS records
the new location.

## Update

From version 0.1.6, click **检查更新** next to the current version in the panel.
If a newer stable release is available, read its notes and click **下载并安装**.
Only these explicit actions contact GitHub. The app verifies the checksum,
Developer ID team, bundle identity/version and Gatekeeper approval, then exits,
replaces its installed bundle and restarts. There are no background updates.

Automatic replacement requires a writable `/Applications/Codex Token Bar.app`
or `~/Applications/Codex Token Bar.app`. Disk-image, renamed, read-only, ad-hoc
and development copies must be updated manually; no administrator password is requested.
For 0.1.5 and earlier, download the new DMG manually once to get the updater.
Your Codex session files and preferences are not changed.

Replacement or launch failure triggers rollback. A previous bundle is retained
under `.CodexTokenBar-update-<UUID>/Previous.app` beside the installation; an
interrupted update or power loss may require moving this backup back manually.
After confirming the new version works, the corresponding update folder can be
removed. A successful process launch is checked, not every future runtime behavior.

## Uninstall

1. Open the menu bar panel and turn off **登录时启动**.
2. Choose **退出** (Quit).
3. Move `/Applications/Codex Token Bar.app` to the Trash.
4. If Codex Token Bar still appears in **System Settings → General → Login Items
   & Extensions**, remove or disable it there.

The app does not create a usage database or copy your Codex logs, so there is no
usage-data folder to remove. Uninstalling the app does not delete anything under
`~/.codex`.

## Privacy and permissions

Codex Token Bar reads token-count metadata from:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

It does not read `~/.codex/auth.json`, account identity, or Keychain credentials,
upload session files or send telemetry. Only the manual updater contacts GitHub;
macOS may contact Apple to assess signed software. Prompt and response records
in the JSONL files are ignored. The app does not require Full Disk Access for
its normal location under your home folder. See [PRIVACY.md](../PRIVACY.md) for
the full privacy boundary.

For suspected-reset banners, use **重置提醒** and allow notifications
in macOS. If denied, enable them in System Settings → Notifications → Codex Token
Bar. Focus/banner settings may prevent a popup. Detection needs new local records;
it is not real-time account monitoring. After switching accounts, click
**清除旧额度**; this hides older quota without deleting logs.

## Build from source instead

Building requires macOS 13 or later, Swift 6, and recent Xcode Command Line
Tools:

```sh
git clone https://github.com/zzzxtnt/codex-local-token-bar.git
cd codex-local-token-bar
swift test --disable-sandbox
zsh scripts/build-app.sh
open "dist/Codex Token Bar.app"
```

The script produces a local, ad-hoc-signed app for the architecture of the Mac
that performs the build. It is suitable for local development, not for
redistribution. Official downloadable binaries must be Developer ID signed and
notarized by Apple.
