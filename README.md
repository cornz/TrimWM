# cornzWM v2

cornzWM is a small, local tiling window manager for Apple Silicon Macs running
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
- Accessibility permission for `cornzWM.app`
- **Displays have separate Spaces** enabled

Version 2 manages normal windows on the main display. It observes but does not
move windows known to be on inactive native macOS Spaces. Logical cornzWM
workspaces are independent from native Spaces.

## Build and install

```sh
xcodebuild build \
  -project cornzWM.xcodeproj \
  -scheme cornzWM \
  -configuration Release \
  -derivedDataPath .build/cornzwm-release

backup_dir="$(mktemp -d /tmp/cornzwm-install.XXXXXX)"
if [ -e /Applications/cornzWM.app ]; then mv /Applications/cornzWM.app "$backup_dir/"; fi
ditto .build/cornzwm-release/Build/Products/Release/cornzWM.app /Applications/cornzWM.app
mkdir -p ~/.config/cornzwm
cp Examples/config ~/.config/cornzwm/config
open /Applications/cornzWM.app
```

Grant `/Applications/cornzWM.app` access under **System Settings → Privacy &
Security → Accessibility**. The menu-bar item changes from `Paused` to a status
such as `1N 2A 5A` when enabled. Every occupied workspace is listed; `A`, `N`,
and `F` mean Autotile, Niri, and WM-fullscreen.

The Release target is signed with the configured Apple Development team.
Replacing `/Applications/cornzWM.app` with another build signed by the same
certificate preserves its Accessibility identity. Grant access only to that
installed app. Xcode, `xctest`, Terminal, and copies below `.build` do not need
Accessibility access and their prompts can be declined. A different signing
certificate is a different identity and requires one fresh grant.

## Configuration

The config path is `~/.config/cornzwm/config`. If it is absent, cornzWM uses
the built-in default. [Examples/config](Examples/config) contains the complete
shipped configuration and migrated app rules.

The parser deliberately supports only variables, gaps, split ratio, mouse
focus, login launch, bindings and modes, exact bundle-ID assignments, and
floating rules. Reload is transactional; an invalid file leaves the previous
configuration active and displays the error in the menu.

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
- `Option+Shift+C`: reload configuration

`focus-follows-mouse true` activates the concrete managed window immediately
when the pointer crosses its boundary. It has no delay and never moves the
pointer.

## Recovery and removal

Logical workspaces are implemented by moving inactive windows safely beyond
all connected displays. Before cornzWM first hides a window, it atomically
stores only that window's original frame in:

```text
~/Library/Application Support/cornzWM/crash-journal.json
```

**Disable**, **Restore Hidden Windows**, and **Quit cornzWM** restore every
reachable hidden window. Failed restores remain in the journal for a later
best-effort attempt. No workspace, layout, focus, or session state is saved.

To uninstall, choose **Quit cornzWM** first, remove the app, then remove its
Accessibility and Login Items entries. The config may be retained or deleted.

## Development

Run the deterministic test suite:

```sh
xcodebuild test \
  -project cornzWM.xcodeproj \
  -scheme cornzWM \
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

cornzWM is an independent implementation inspired by the responsiveness and
per-process Accessibility architecture of
[OmniWM](https://github.com/OmniWM/OmniWM), the tree workflow of
[i3](https://i3wm.org/), the automatic split rule from
[nwg-piotr/autotiling](https://github.com/nwg-piotr/autotiling), and the
scrolling-column interaction model of [niri](https://github.com/YaLTeR/niri).
No OmniWM, AeroSpace, i3, autotiling, or niri source code is included.

## License

SPDX-License-Identifier: `GPL-2.0-only`. See [LICENSE](LICENSE).
