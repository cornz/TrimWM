# Details

## Why TrimWM?

TrimWM combines Niri-style scrolling columns with i3-style automatic tiling.

- Fast and animation-free
- No external dependencies or background network access
- No third-party dependency supply-chain risk
- Public or private APIs—whichever provides the fastest reliable result
- Deliberately smaller than OmniWM and more layout-focused than AeroSpace

TrimWM is a small, local tiling window manager for Apple Silicon Macs running
macOS 26 or later. It has two layouts: i3-style BSP autotiling and a minimal
Niri-style scrolling-column layout. It intentionally has no animations,
session restore, network access, external packages, or settings window.

> TrimWM uses Accessibility and a few dynamically resolved private SkyLight
> symbols. Private macOS APIs can change between OS releases.
>
> Official releases are signed with a Developer ID, use the hardened runtime,
> and are notarized by Apple. The notarization ticket is stapled to the app so
> Gatekeeper can verify it without relying on a live notarization lookup.

## Requirements

- Apple Silicon Mac
- macOS 26.0 or later
- Accessibility permission for `TrimWM.app`

## Current limitations

- TrimWM currently manages normal windows on the main display only.
- It observes but does not move windows known to be on inactive native macOS
  Spaces. Logical TrimWM workspaces are independent from native Spaces.
- Private SkyLight APIs may require updates for future macOS releases.

## Install

### Homebrew

```sh
brew tap cornz/tap
brew install --cask trimwm
```

### Manual

1. Download `TrimWM-<version>.zip` from the
   [latest GitHub release](https://github.com/cornz/TrimWM/releases/latest).
2. Unzip it and move `TrimWM.app` to `/Applications`.
3. Optionally download
   [Examples/config](https://github.com/cornz/TrimWM/raw/main/Examples/config)
   and install it:

   ```sh
   mkdir -p ~/.config/trimwm
   mv ~/Downloads/config ~/.config/trimwm/config
   ```

4. Open `/Applications/TrimWM.app`.
5. Grant it access under **System Settings → Privacy & Security →
   Accessibility**.

TrimWM uses its built-in defaults when `~/.config/trimwm/config` does not
exist. See [Configuration](configuration.md).

## Status menu

The menu-bar item changes from `Paused` to a status such as `[1N] 2T 5T` when
enabled. Every occupied workspace is listed, and brackets mark the active one;
`T`, `N`, and `F` mean Tiling, Niri, and WM-fullscreen.

## Build from source

Building from source requires Xcode 26 or later.

```sh
xcodebuild build \
  -project TrimWM.xcodeproj \
  -scheme TrimWM \
  -configuration Release \
  -derivedDataPath .build/trimwm-release

backup_dir="$(mktemp -d /tmp/trimwm-install.XXXXXX)"
if [ -e /Applications/TrimWM.app ]; then mv /Applications/TrimWM.app "$backup_dir/"; fi
ditto .build/trimwm-release/Build/Products/Release/TrimWM.app /Applications/TrimWM.app
mkdir -p ~/.config/trimwm
cp Examples/config ~/.config/trimwm/config
open /Applications/TrimWM.app
```

Grant `/Applications/TrimWM.app` access under **System Settings → Privacy &
Security → Accessibility**.

Replacing `/Applications/TrimWM.app` with another build signed by the same
certificate preserves its Accessibility identity. Grant access only to that
installed app. Xcode, `xctest`, Terminal, and copies below `.build` do not need
Accessibility access and their prompts can be declined. A different signing
certificate is a different identity and requires one fresh grant.

## Recovery and removal

Logical workspaces are implemented by moving inactive windows safely beyond
all connected displays. Before TrimWM first hides a window, it atomically
stores only that window's original frame in:

```text
~/Library/Application Support/TrimWM/crash-journal.json
```

**Disable**, **Restore Hidden Windows**, and **Quit TrimWM** restore every
reachable hidden window. Failed restores remain in the journal for a later
best-effort attempt. No workspace, layout, focus, or session state is saved.

Minimum sizes that apps refuse to shrink below are remembered in
`~/Library/Application Support/TrimWM/minimum-sizes.json`, so new windows of
those apps are laid out correctly the first time. A remembered minimum is
forgotten once a window of the app is seen smaller. Delete the file to forget
them all.

To uninstall, choose **Quit TrimWM** first, remove the app, then remove its
Accessibility and Login Items entries. The config may be retained or deleted.

## Development

Run the deterministic test suite:

```sh
xcodebuild test \
  -project TrimWM.xcodeproj \
  -scheme TrimWM \
  -configuration Debug \
  -derivedDataPath .build/tests \
  CODE_SIGNING_ALLOWED=NO
```

The runtime has one App target and one XCTest target. AX access is isolated per
application, events commit serially on the main actor, and layout engines are
pure value types. Window moves, resizes, and reorders arrive as WindowServer
notifications. There is no polling loop, animation engine, package manager
dependency, telemetry, IPC server, or helper daemon. The XCTest host explicitly
suppresses window-manager startup, so tests never need Accessibility
permission.

See [CONTRIBUTING.md](../CONTRIBUTING.md) before proposing a change.
User-visible changes are recorded in [CHANGELOG.md](../CHANGELOG.md), and
security issues should follow [SECURITY.md](../SECURITY.md).

## Inspiration and attribution

TrimWM is an independent implementation inspired by the responsiveness and
per-process Accessibility architecture of
[OmniWM](https://github.com/BarutSRB/OmniWM), the tree workflow of
[i3](https://i3wm.org/), the automatic split rule from
[nwg-piotr/autotiling](https://github.com/nwg-piotr/autotiling), and the
scrolling-column interaction model of [niri](https://github.com/YaLTeR/niri).
No OmniWM, AeroSpace, i3, autotiling, or niri source code is included.

The WindowServer focus border and window event handling are adapted from
[dinky](https://github.com/mikker/Dinky) under its MIT license, which
reimplements the approach of
[JankyBorders](https://github.com/FelixKratz/JankyBorders). See
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](../LICENSE). Releases up to 0.7.0 were published under
GPL-2.0-only.
