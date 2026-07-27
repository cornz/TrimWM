# Changelog

This changelog records user-visible changes in published TrimWM releases. Its
sections follow the concise release-note style used by AeroSpace.

## [Unreleased]

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

[Unreleased]: https://github.com/cornz/TrimWM/compare/v0.2.31...HEAD
[0.2.31]: https://github.com/cornz/TrimWM/compare/v0.2.30...v0.2.31
[0.2.30]: https://github.com/cornz/TrimWM/compare/v0.2.29...v0.2.30
[0.2.29]: https://github.com/cornz/TrimWM/releases/tag/v0.2.29
