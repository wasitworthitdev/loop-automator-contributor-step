# Loop Automator

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Godot 4.7](https://img.shields.io/badge/Godot-4.7-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Build](https://github.com/wozitdev/loop-automator/actions/workflows/build.yml/badge.svg)](https://github.com/wozitdev/loop-automator/actions/workflows/build.yml)
[![Latest release](https://img.shields.io/github/v/release/wozitdev/loop-automator)](https://github.com/wozitdev/loop-automator/releases/latest)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

A Godot **4.7** tool for visually building automated **mouse + keyboard loops** —
think a TAS you assemble in a UI — together with an **on-screen overlay** that
draws what each action does (detection rects, click points, movement paths).

The whole project runs as a single, endlessly repeating **loop**. The loop is
split into **layers** so automators can organise it into separate "screens" that
can be flipped through and viewed individually in the overlay.

---

## Download

Prebuilt binaries are on the
[Releases](https://github.com/wozitdev/loop-automator/releases) page:

| Platform | File | Notes |
|----------|------|-------|
| Windows 10/11 (64-bit) | `loop-automator-<version>-windows-x86_64.zip` | The supported platform: real input backend + overlay click-through. |
| Linux (64-bit) | `loop-automator-<version>-linux-x86_64.tar.gz` | Experimental: Preview backend only, overlay behaviour untested. |

Unzip and run `Loop Automator.exe` — nothing to install. Windows SmartScreen may
warn that the app is unrecognised because the binary is not code-signed; choose
**More info → Run anyway**. Every release ships a `SHA256SUMS.txt` so you can
verify what you downloaded.

Prefer running from source? Open the folder in Godot 4.7 and press **F5** — see
[Building](#building).

---

## Core concepts

| Concept    | Meaning |
|------------|---------|
| **Project / Loop** | The full automation. Runs forever, top to bottom, then repeats. |
| **Layer**  | A named group of actions. *All enabled layers run every iteration.* Layers exist purely to organise a loop into flip-through "screens" with their own colour + overlay view. |
| **Action** | One step: Move, Click, Drag, Key, Wait, or Pixel Detect. |

So a loop with `Layer 1` and `Layer 2` runs **Layer 1's actions, then Layer 2's
actions, then repeats** — exactly as described: layer 2 runs in the same loop as
layer 1, just broken out so you can view each layer's visuals separately.

---

## Action types

- **Move** — move the cursor to `(x, y)` (optional dwell duration).
- **Click** — move to `(x, y)` and click Left / Right / Middle.
- **Drag** — press at A, move to B, release.
- **Key** — send keystrokes. On the Windows backend this uses the
  [`SendKeys`](https://learn.microsoft.com/dotnet/api/system.windows.forms.sendkeys)
  format, e.g. `abc`, `{ENTER}`, `^c` (Ctrl+C), `%{F4}` (Alt+F4).
- **Wait** — pause N milliseconds.
- **Pixel Detect** — sample a screen rect for an expected colour (± tolerance).
  The pixel at the rect's **centre** is checked. **Pick & sample** centres the
  rect on the point you click and reads its colour; **Just sample** reads the
  colour of the point you click without moving the rect. If *not* found you can
  **Continue**, **Skip the rest of the layer**, or **Stop** the loop.

Every action stores screen coordinates, so the overlay can draw it at the right
place over your other applications.

---

## Using it

1. Run the [downloaded binary](#download), or open the folder in Godot 4.7 and
   press **Run** (F5).
2. Pick a **layer** on the left (add / remove / reorder / rename / recolour).
3. Add **actions** in the middle column, edit them on the right.
   - Use the **🎯 Pick on screen** buttons to place a point/rect *interactively*:
     the overlay takes over the screen, you move the mouse to the real target and
     **left-click** to set it (drag for a detection rect). **Right-click / Esc**
     cancels. This replaces the old "grab current mouse" approach, which captured
     the button's own position.
4. Toggle **Overlay: ON** to see the visuals drawn full-screen, always on top.
   - `◀ Layer` / `Layer ▶` (or **←/→**, **PgUp/PgDn**, `[` / `]`) flip through
     layers; the toolbar shows the current view (e.g. `View: 2/3 · Layer 2`).
     Flipping also selects that layer for editing.
   - Number keys **1–9** jump straight to a layer.
   - **Show All** (or `\`) toggles drawing every visible layer at once.
5. Choose a **Backend** and press **▶ Run** (or **F5**).

> The status line lives in the **bottom bar**; the toolbar scrolls horizontally
> if the window is too narrow to show every control.

### Hotkeys
| Key | Action |
|-----|--------|
| F5  | Start / stop the loop |
| F8 / Esc | Stop the loop |
| ← / → · PgUp / PgDn · `[` / `]` | Flip to previous / next layer |
| 1–9 | Jump to layer N |
| `\` | Toggle Show All layers |

> Navigation keys are ignored while typing in a text field, so editing names,
> keys, and comments still works normally.

Projects save/load as `.loop` JSON files — see [examples/](examples/) for a
starter loop.

---

## Backends (how input is actually sent)

Godot cannot synthesize OS-wide input on its own, so input is sent through a
pluggable `InputBackend`:

- **Preview (safe)** — *default*. Touches nothing on your OS; it only feeds the
  overlay/status so you can design and dry-run a loop safely. Pixel-detect always
  reports "found" so the flow continues.
- **Windows (real)** — *experimental*. Drives the real cursor/keyboard and reads
  screen pixels via a small generated PowerShell helper (`user://input_helper.ps1`)
  using `SetCursorPos`, `mouse_event`, `SendKeys`, and `CopyFromScreen`.
  It is **functional but slow** (each action spawns PowerShell). It's here to
  prove the pipeline end-to-end.

> For high-speed real automation, replace `WindowsBackend` with a native
> **GDExtension** that implements the same `InputBackend` API — nothing else in
> the app needs to change.

---

## Project layout

```
.github/workflows/build.yml # CI: headless exports on every push/PR, draft releases on tags
export_presets.cfg         # Godot export presets (Windows Desktop, Linux)
project.godot              # autoloads, renderer, transparency + native-subwindow settings
icon.svg
scenes/
  main.tscn                # builder window (UI built in code)
  overlay.tscn             # transparent overlay Window
scripts/
  main.gd                  # the builder GUI
  overlay.gd               # overlay Window: borderless, on-top, click-through
  overlay_canvas.gd        # draws rects / points / paths / current action
  overlay_native.gd        # Windows helper: real click-through (WS_EX_LAYERED|TRANSPARENT)
  pick_overlay.gd          # interactive full-screen window for "Pick on screen"
  autoload/
    project_data.gd        # current project + selection state + signals + IO
    playback_engine.gd     # the endless loop runner
  model/
    loop_action.gd         # one step (+ JSON)
    loop_layer.gd          # a layer of actions (+ JSON)
    loop_project.gd        # the whole loop (+ JSON)
  input/
    input_backend.gd       # backend interface
    preview_backend.gd     # safe, no-OS backend
    windows_backend.gd     # experimental real Windows input
```

## Notes / limitations

- The overlay is a native borderless, always-on-top, transparent, click-through
  window. `display/window/subwindows/embed_subwindows` is **off** so child
  `Window` nodes become real OS windows.
- Per-pixel transparency requires
  `display/window/per_pixel_transparency/allowed = true` (already set) **and a
  renderer that can composite transparent windows**. On Windows the Forward+ and
  Mobile (Vulkan) renderers usually can't (the overlay shows up as an opaque
  black window), so the project runs on the **Compatibility** renderer. If you
  switch renderers and the overlay goes black, that's why — the status line
  will tell you.
- Godot's `Window.FLAG_MOUSE_PASSTHROUGH` only lets clicks through to windows of
  the *same application*. On Windows the overlay therefore applies the real
  thing (`WS_EX_LAYERED | WS_EX_TRANSPARENT`) through a small generated
  PowerShell helper (`user://overlay_helper.ps1`) right after it is shown; the
  status line / overlay HUD report when click-through is active. On other
  platforms the Godot flag is used as-is.
- "Pick on screen" uses a separate, *non*-click-through window so the click that
  places a point or rect is captured and never reaches the program underneath.
- The real Windows backend is best-effort; a GDExtension is the path to fast,
  robust global input and a global stop-hotkey.

---

## Building

Development needs no build step — open the project in Godot 4.7 and press F5.
Binaries are produced by Godot's headless exporter from the presets in
`export_presets.cfg` (single-file builds with the PCK embedded):

```sh
godot --headless --import
godot --headless --export-release "Windows Desktop" "build/Loop Automator.exe"
godot --headless --export-release "Linux" build/loop-automator.x86_64
```

The matching **export templates** must be installed (Editor → Manage Export
Templates). With [rcedit](https://github.com/electron/rcedit) on your `PATH`
(or set in Editor Settings → Export → Windows) the Windows exe also gets the
project icon and version info.

### Releases

[GitHub Actions](.github/workflows/build.yml) exports both platforms on every
push and pull request; the builds hang off the workflow run as artifacts.
Pushing a version tag turns a build into a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow stamps the version into the build, packages the archives plus
`SHA256SUMS.txt`, and creates a **draft** GitHub Release. Download and test the
binaries, then press *Publish release* on GitHub to make them public. Tags with
a suffix (`v1.1.0-rc1`) are marked as pre-releases.

## Contributing

Contributions are very welcome — especially native input backends, new action
types, and cross-platform testing. See [CONTRIBUTING.md](CONTRIBUTING.md) to
get started.

## Responsible use

Loop Automator sends real mouse/keyboard input when a real backend is selected.
Use it only on systems and software you're permitted to automate; automating
online games or third-party services may violate their terms of service.

## License

[MIT](LICENSE) © 2026 wozitdev

