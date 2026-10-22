# Changelog

This changelog records user-visible changes in published TrimWM releases. Its
sections follow the concise release-note style used by AeroSpace.

## [Unreleased]

## [0.9.5] — 22 October 2026

Bug fixes

- Return BSP windows to their old layout once they fit side by side again.
  When an app applied a resize late, TrimWM briefly took its old size for its
  minimum and stacked the windows to fit it, and they stayed stacked after the
  minimum was forgotten, until TrimWM restarted.

## [0.9.4] — 21 October 2026

Changes

- Leave the workspace list out of the first line of the status menu: the
  menu bar already shows the workspaces with their layout glyphs.

## [0.9.3] — 17 October 2026

Bug fixes

- Return a BSP window that vanished for a moment, for example while its app
  was hidden, to its old place instead of splitting the focused window. When
  all windows of a workspace vanished at once, as on another Space, they come
  back in their old layout in whatever order they reappear. The first window of an app that relaunched within 30 seconds,
  as after an update, takes the place of its old one. Before, two columns above
  a full-width line could turn into a line above two columns.
- Focus the window that grows into the space of a closed BSP window, instead of
  the last window of the workspace.

## [0.9.2] — 14 October 2026

Improvements

- Leave out the focus border around a WM-fullscreen window and the active tab:
  each is the only tiled window in view. Focused floating windows keep their
  border.
- Add `border single-window false` to also leave out the border around the
  only window of a BSP or Niri workspace.

## [0.9.1] — 14 October 2026

New features

- Place the tab bar at the bottom or as a rail at the right too, with
  `tabs position bottom` or `tabs position right`.

Bug fixes

- Keep an expanded tab rail open while the pointer is pushed against the screen
  edge it sits at, instead of collapsing it.

## [0.9.0] — 14 October 2026

New features

- Add `layout tabs`, bound to `Option+T` in the default configuration
  (`bindsym $mod+t layout tabs` in your own): every window of the workspace
  shares one frame like tabs in a browser, and a tab bar with app icons and
  window titles switches between them by click, `focus`, and `focus next`;
  `move` reorders them. The bar is a Liquid Glass island with the window's
  corner radius. It sits at the top or as an icon rail on the left that
  expands on hover (`tabs position top|left`), can be resized (`tabs size`),
  and can hide until the pointer touches its screen edge
  (`tabs autohide true`).
- Show each workspace's layout in the menu bar as a glyph instead of a letter.

## [0.8.1] — 13 October 2026

Bug fixes

- Stop remembering an app's old size as its minimum when it applies a resize
  late, as Warp does: TrimWM now checks a refused resize again a moment later.
  Such a minimum kept the app from sharing the screen side by side, so its
  windows were always stacked.
- Forget a remembered minimum size once a window of the app is seen smaller.
- Ignore minimum sizes remembered by 0.8.0; they are learned again as needed.

## [0.8.0] — 9 October 2026

Changes

- License TrimWM under MIT instead of GPL-2.0-only from this release on.
- Keep the README short and move configuration and details to `docs/`.

New features

- Reload the configuration automatically when it is saved, also when it is a
  symlink.

Improvements

- Track window moves and resizes through WindowServer notifications instead of
  asking each app, so busy apps no longer delay layout updates.
- Remember minimum sizes apps refuse to shrink below across launches, so new
  windows of those apps are laid out correctly the first time.
- Write frames faster by checking each app's enhanced accessibility mode once
  per burst of writes instead of on every write.
- Reuse the on-screen window list within one layout pass.
- Draw the focus border as a window of its own directly above the focused
  window: windows in front of the focused window now cover the border too, and
  it moves with the focused window's Space instead of showing on every Space.
- Cover the window's own edge rim with the focus border, so no seam shows
  between the border and the window's content.
- Match the focus border to each window's actual corner radius with
  `border radius auto` instead of assuming 16 points.
- Reshape, redraw, and move the focus border in one screen update, so it no
  longer flickers while windows resize.

Bug fixes

- Move windows that are only a few points off their target, so changing gaps
  places every window correctly instead of leaving some offset by the gap
  difference.
- Draw the focus border around the window's actual frame, so it stays on the
  window edge while resizing and around windows that snap to a grid or refuse
  a size.

## [0.7.0] — 17 September 2026

New features

- Add `border radius auto` to match macOS 27's uniform window corners,
  accounting for border width. Keep numeric radius overrides and the previous
  automatic appearance on macOS 26. Existing configurations can opt in by
  replacing `border radius 9` with `border radius auto`.

Bug fixes

- Let floating windows keep manual position and size changes instead of
  snapping back to their previous frame.

## [0.6.1] — 1 September 2026

Bug fixes

- Detect physical modifier sides from each keyboard event so right-side hotkeys trigger reliably.

## [0.6.0] — 1 September 2026

New features

- Open the configuration from the status menu with the default text editor.
- Address the left or right physical modifier key in hotkey bindings.

## [0.5.0] — 30 August 2026

Bug fixes

- Focus the remaining visible window immediately after the focused window closes.

## [0.4.1] — 25 August 2026

Bug fixes

- Leave WM-fullscreen when focus switches to a window that fullscreen would
  otherwise hide.

## [0.4.0] — 19 August 2026

Bug fixes

- Ignore transient and unknown Accessibility windows so browser suggestion
  popups do not receive the focus border or window-manager commands.

## [0.3.1] — 27 July 2026

New features

- Show the installed version in the status menu and link directly to the changelog.

Bug fixes

- Keep snapping manually moved windows back to their tile while still tolerating applications that repeatedly enforce the same size.

## [0.3.0] — 27 July 2026

Bug fixes

- Stop retrying the same rejected tile size when applications such as Slack
  clamp a window to a maximum size or fixed aspect ratio.
- Stop fighting windows such as Slack Huddles that initially accept a tile
  size but repeatedly restore an application-controlled size.

## [0.2.31] — 26 July 2026

New features

- Add `niri single-window-full-width` so a lone Niri window can use the full
  workspace and return to its configured column width when another window
  appears.

Bug fixes

- Reconcile closed windows that remain exposed as offscreen Accessibility
  elements so layouts reflow immediately.

Documentation

- Add Homebrew Tap installation commands.

## [0.2.30] — 25 July 2026

Documentation

- Add the project goals, upstream inspiration, and contribution expectations.
- Replace the release-candidate wording with direct installation instructions.
- Add a security policy and structured bug and feature request forms.
- Ignore common certificate, provisioning, key, and environment files.
- Add sanitized BSP and Niri screenshots.

Bug fixes

- Show only the applicable Enable or Disable action in the menu.

## [0.2.29] — 24 July 2026

This is the first published, notarized TrimWM release. Versions 0.2.1 through
0.2.28 were internal development iterations and were not published releases.

New features

- Add Niri-style scrolling columns alongside i3-style BSP autotiling.
- Add logical workspaces with move, move-and-follow, and cross-workspace app
  activation.
- Add Niri consume and expel operations for stacking windows within columns.
- Add WM-fullscreen, floating windows, directional focus and movement, forced
  BSP splits, and keyboard resize mode.
- Add immediate focus-follows-mouse behavior without pointer warping or delay.
- Add `Option` + right-drag resizing.
- Add `Option` + left-drag column movement in Niri and slot swapping in BSP.
- Add visible drag targets for mouse-driven moves.
- Add a configurable focused-window border with accent or RGBA color, width,
  and corner radius.
- Show every occupied workspace in the menu bar, mark the active workspace,
  and label BSP, Niri, and fullscreen layouts as `T`, `N`, and `F`.
- Add exact bundle-ID workspace assignments, floating rules, gaps, split
  ratios, custom modes, transactional config reload, and launch-at-login.

Bug fixes

- Resolve move-and-follow and workspace move targets from the live
  Accessibility focus.
- Follow an activated application's focused window to its TrimWM workspace.
- Fix Niri consume and expel focus and resolve stack targets from live
  Accessibility state.
- Keep WM-fullscreen exclusive while allowing transient application overlays,
  menus, and form popovers to retain focus.
- Focus the window under the pointer after switching workspaces.
- Correct mouse drag-and-drop move detection and target feedback.

Improvements

- Rename the project and bundle from cornzWM to TrimWM and remove legacy
  versioning and implementation references.
- Add the TrimWM app icon.
- Keep the runtime event-driven, animation-free, local, and free of external
  packages, helper daemons, telemetry, and background network access.
- Sign release builds with Developer ID, enable the hardened runtime, notarize
  them with Apple, and staple the notarization ticket.
- Correct runtime requirements and document release signing and Accessibility
  identity behavior.

Testing

- Add isolated runtime-controller and fullscreen-overlay regression tests.
- Reach full line coverage for the pure core layout and state-transition
  logic.
- Ship 139 deterministic tests that run without Accessibility permission.

## 0.2.0 — 23 July 2026

- Establish the independent minimal macOS window-manager implementation with
  Accessibility isolation, serial event processing, pure layout engines,
  crash-safe hidden-window recovery, and no session restoration.

[Unreleased]: https://github.com/cornz/TrimWM/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/cornz/TrimWM/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/cornz/TrimWM/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/cornz/TrimWM/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/cornz/TrimWM/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/cornz/TrimWM/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/cornz/TrimWM/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/cornz/TrimWM/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/cornz/TrimWM/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/cornz/TrimWM/compare/v0.2.31...v0.3.0
[0.2.31]: https://github.com/cornz/TrimWM/compare/v0.2.30...v0.2.31
[0.2.30]: https://github.com/cornz/TrimWM/compare/v0.2.29...v0.2.30
[0.2.29]: https://github.com/cornz/TrimWM/releases/tag/v0.2.29
