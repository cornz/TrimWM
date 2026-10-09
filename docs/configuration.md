# Configuration

The config path is `~/.config/trimwm/config`. If it is absent, TrimWM uses
the built-in default. [Examples/config](../Examples/config) contains the
complete shipped configuration and migrated app rules. **Open Configuration…**
in the status menu creates this file when needed and opens it with the default
text editor. Saving the file reloads it automatically, including through a
symlink into a dotfiles repository; `Option+Shift+C` still reloads it by hand.

The syntax is deliberately a small i3/Sway-style command language rather than
TOML or KDL. The parser supports only variables, gaps, layout options, border
style, mouse focus, login launch, bindings and modes, exact bundle-ID
assignments, and floating rules. Reload is transactional; an invalid file
leaves the previous configuration active and displays the error in the menu.

## Default bindings

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

## Modifier sides

Bindings can address one physical modifier side with `left-` or `right-`.
This works for `cmd`, `shift`, `ctrl`, `alt`, and their long aliases. For
example, this binding starts Warp or brings it to the front only when the
right Command key is held:

```text
bindsym right-cmd+w launch open -a Warp
```

`cmd+w` without a side continues to match either Command key. A generic and a
side-specific binding for the same chord cannot be used together.

## Layouts

Consume requires an adjacent column in the chosen direction. Expel requires at
least two windows in the focused column; it then creates a new column in the
chosen direction.

`niri single-window-full-width true` lets one Niri window use the full
workspace width. Adding a second window restores the configured column widths;
removing it expands the remaining window again. Set the option to `false` to
keep a single window at its normal column width.

![TrimWM arranging horizontally scrolling columns](../Design/Screenshots/trimwm-niri.png)

## Focus

`focus-follows-mouse true` activates the concrete managed window immediately
when the pointer crosses its boundary. It has no delay and never moves the
pointer. Activating an app through Command-Tab follows its focused window to
the corresponding TrimWM workspace.

## Border

The focused managed window has a thin, click-through border. Configure it in
points and with either the macOS accent color or an RGB/RGBA hex value:

```text
border color accent
# Alternatives: border color 0x0A84FF
#               border color 0x0A84FFFF
border width 2
border radius auto
```

Only one `border color` line is needed. A width of `0` hides the border. The
border sits outside the window, so `gaps inner` of at least twice the border
width leaves visible space beside it.

The border is a window of its own, kept directly above the focused window at
the same level, so windows in front of the focused window also cover its
border, and it stays on the focused window's Space. It reaches one point into
the window to cover the thin rim macOS draws along window edges, so it meets
the content without a seam.

The default radius, `auto`, follows each window's actual corner radius as
reported by WindowServer, so the inner edge fits the window exactly; where that
is unavailable it falls back to 16 points on macOS 27 and a 9-point outer
radius on macOS 26. A numeric radius sets the outer radius directly, including
`0` for square corners. In an existing configuration, replace
`border radius 9` with `border radius auto` to adopt the new default.
