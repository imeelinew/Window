<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Window">
</p>

<h1 align="center">Window</h1>

<p align="center">
  A lightweight native macOS window manager that stays in the background.<br>
  No main window, Dock icon, or menu bar icon — global hotkeys handle maximize, halves, centering, and workspace cleanup.
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Window/releases">Download</a> ·
  <a href="#hotkeys">Hotkeys</a> ·
  <a href="#install">Install</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

<p align="center">
  <a href="README.en.md">English</a>
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Window/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Window" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
</p>

---

## About

Window is a native macOS window manager by [Eli New](https://elinew.tech). It does one job: move and resize the focused window with global hotkeys. It runs as a background process with no Dock icon, menu bar extra, or settings window. Idle time is not spent polling; work is driven by hotkeys and system events.

Placements use the current display’s **visible work area**, so the menu bar and Dock are left clear. On multiple displays, the window is placed on the screen it already occupies. The first launch uses the standard macOS Accessibility prompt; hotkeys work after permission is granted.

## Why Window

The macOS Dock changes size as icons come and go, and the screen’s available work area changes with it. Maximized third-party windows usually do not recalculate their height, so a persistent gap can appear at the bottom after the Dock grows or shrinks.

Window exists to keep those windows flush: hotkeys snap the focused window into the work area, and already-maximized windows stay aligned when the Dock or display layout changes. If you later drag or resize that window yourself, Window stops tracking it.

- **Background only**: no main window, Dock icon, or menu bar icon
- **Hotkey driven**: acts on the currently focused window
- **Work-area aware**: maximize and half-screen layouts respect the menu bar and Dock
- **Maximized windows stay flush**: Dock resizing and display changes re-align windows that Window is still managing

## Hotkeys

| Shortcut | Action |
| --- | --- |
| `Command + ↑` | Maximize the focused window to the current screen’s available area |
| `Command + ←` | Place the focused window on the left half |
| `Command + →` | Place the focused window on the right half |
| `Command + ↓` | Resize the focused window to 998 × 836 and center it in the available area |
| `Command + Option + ↓` | Keep the focused window, hide other apps, and minimize the current app’s other windows |

Left and right halves tile the full work area with no gap between them.

## Behavior

- Only the frontmost app’s focused window is moved; Window never operates on itself.
- Frames are computed from the screen’s visible area, so space taken by the menu bar and Dock is reserved.
- The window is placed on the display that currently contains it.
- After maximize, Window keeps tracking that window: Dock size changes, screen layout changes, and the app becoming visible or returning from another Space will re-fit it to the work area. A window you move or resize by hand is dropped from tracking.
- Moves are animated; with Reduce Motion enabled, the window jumps to the target frame.
- Electron apps use a separate animation path so repeated size writes do not stutter.

## Permissions and updates

Window reads and sets window frames through the Accessibility API, so Accessibility permission is required. The first launch shows the system prompt; you can also enable it later in **System Settings → Privacy & Security → Accessibility**.

The app checks [GitHub Releases](https://github.com/imeelinew/Window/releases) for updates automatically with Sparkle.

## Install

Requires **macOS 14** or later.

Download the latest build from the [Releases page](https://github.com/imeelinew/Window/releases), move `Window.app` to `/Applications`, open it once, and grant Accessibility permission.

## Build from source

The Xcode project was created with Xcode 26. The app’s deployment target is macOS 14 or later.

```bash
git clone https://github.com/imeelinew/Window.git
cd Window
open Window.xcodeproj
```

Select the **Window** scheme and choose **Product → Run**. Grant Accessibility permission when prompted before using the hotkeys.

## License

Window is released under the [MIT License](LICENSE). Copyright © 2026 [Eli New](https://elinew.tech).
