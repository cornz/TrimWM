# TrimWM

TrimWM is a small, local tiling window manager for Apple Silicon Macs running
macOS 26. It has two layouts: i3-style BSP autotiling and a minimal
Niri-style scrolling-column layout. It intentionally has no animations,
session restore, network access, external packages, or settings window.

> **Status:** local release candidate. The project uses Accessibility and a
> few dynamically resolved private SkyLight symbols. Private macOS APIs can
> change between OS releases.

## Requirements

- Apple Silicon Mac
- macOS 26.x
- Xcode 26.x command-line tools
- Accessibility permission for `TrimWM.app`
- **Displays have separate Spaces** enabled

TrimWM manages normal windows on the main display. It observes but does not
move windows known to be on inactive native macOS Spaces. Logical TrimWM
workspaces are independent from native Spaces.

## Build and install

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
Security → Accessibility**. The menu-bar item changes from `Paused` to a status
such as `[1N] 2T 5T` when enabled. Every occupied workspace is listed, and
brackets mark the active one; `T`, `N`, and `F` mean Tiling, Niri, and
WM-fullscreen.

The distributed Release app is signed with a Developer ID Application
certificate and hardened runtime. Replacing `/Applications/TrimWM.app` with
another build signed by the same certificate preserves its Accessibility
identity. Grant access only to that installed app. Xcode, `xctest`, Terminal,
and copies below `.build` do not need Accessibility access and their prompts
can be declined. A different signing certificate is a different identity and
requires one fresh grant.

## Configuration

The config path is `~/.config/trimwm/config`. If it is absent, TrimWM uses
the built-in default. [Examples/config](Examples/config) contains the complete
shipped configuration and migrated app rules.

The syntax is deliberately a small i3/Sway-style command language rather than
TOML or KDL. The parser supports only variables, gaps, split ratio, border
style, mouse focus, login launch, bindings and modes, exact bundle-ID
assignments, and floating rules. Reload is transactional; an invalid file
leaves the previous configuration active and displays the error in the menu.

Default highlights:

- `Option+J/K/L/;`: focus left/down/up/right
- `Option+Shift+J/K/L/;`: move
- `Option+1…9/0`: logical workspace 1…10
- `Option+Shift+1…8`: move and follow
- `Option+Control+1…8`: move without following
- `Option+H/V`: force the next BSP split
- `Option+W`: switch the current workspace to Niri
- `Option+Shift+E`: switch back to BSP autotiling
- `Option+,/.`: consume into the existing column on the left/right
- `Option+Shift+,/.`: expel into a new column on the left/right
- `Option+Shift+Space`: toggle floating
- `Option+F`: toggle WM-fullscreen
- `Option+R`: resize mode; Return or Escape exits it
- `Option+right-drag`: resize the window under the pointer
- `Option+left-drag`: move a whole Niri column, or swap two BSP window slots
- `Option+Shift+C`: reload configuration

Consume requires an adjacent column in the chosen direction. Expel requires at
least two windows in the focused column; it then creates a new column in the
chosen direction.

`focus-follows-mouse true` activates the concrete managed window immediately
when the pointer crosses its boundary. It has no delay and never moves the
pointer. Activating an app through Command-Tab follows its focused window to
the corresponding TrimWM workspace. The focused managed window has a thin,
click-through border. Configure it in points and with either the macOS accent
color or an RGB/RGBA hex value:

```text
border color accent
# Alternatives: border color 0x0A84FF
#               border color 0x0A84FFFF
border width 2
border radius 9
```

Only one `border color` line is needed. A width of `0` hides the border.
`Option+Shift+C` reloads all three values immediately.

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
pure value types. There is no polling loop, timer, animation engine, package
manager dependency, telemetry, IPC server, or helper daemon. The XCTest host
explicitly suppresses window-manager startup, so tests never need Accessibility
permission.

## Inspiration and attribution

TrimWM is an independent implementation inspired by the responsiveness and
per-process Accessibility architecture of
[OmniWM](https://github.com/OmniWM/OmniWM), the tree workflow of
[i3](https://i3wm.org/), the automatic split rule from
[nwg-piotr/autotiling](https://github.com/nwg-piotr/autotiling), and the
scrolling-column interaction model of [niri](https://github.com/YaLTeR/niri).
No OmniWM, AeroSpace, i3, autotiling, or niri source code is included.

## License

SPDX-License-Identifier: `GPL-2.0-only`. See [LICENSE](LICENSE).
