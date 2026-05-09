# TOJam 2026 RTS Prototype

An early Zig/Sokol isometric RTS prototype with an integrated ImGui editor. The code is split into runtime, editor, map, asset, and rendering-free pathfinding modules so the MVP can grow without turning into a one-file experiment.

## Requirements

- Zig 0.15.2
- Native platform SDK/toolchain supported by Sokol
- Optional: Emscripten SDK for the web build

## Run

```sh
zig build run
```

The default run mode is the packaged integrated experience with the game and editor together. Explicit native modes are also available:

```sh
zig build run-integrated
zig build run-editor
zig build run-game
```

`run-editor` starts with the editor enabled. `run-game` starts directly in gameplay with editor controls disabled. The same startup mode can be selected for native or web builds with `-Dapp-mode=integrated`, `-Dapp-mode=editor`, or `-Dapp-mode=game`.

## Test

```sh
zig build test
```

## Web

```sh
zig build web -Demsdk=/path/to/emsdk
```

The browser bundle is written to `zig-out/web`.

## Deploy Web Build To GitHub Pages

This repo includes `.github/workflows/deploy-pages.yml` to publish the web build on pushes to `main`.

Expected custom domain:

- `tojam2026.cbrnl.com`

Setup once in GitHub:

1. Open repo `Settings` -> `Pages`.
2. Under `Build and deployment`, set `Source` to `GitHub Actions`.
3. Ensure DNS has `CNAME` `tojam2026` -> `cabernal.github.io`.
4. Push to `main`, or run the `Deploy Web to GitHub Pages` workflow manually.

The workflow builds with Zig `0.15.2` and Emscripten `4.0.14`, runs:

```sh
zig build web -Demsdk=/tmp/emsdk -Doptimize=ReleaseFast
```

Then it copies `zig-out/web/tojam2026.html` to `zig-out/web/index.html`, writes `tojam2026.cbrnl.com` to `zig-out/web/CNAME`, and deploys the full `zig-out/web` directory.

## Assets

Starter PNGs from `../notes/Arid Badlands` are copied under `assets/`. The loader recursively scans that folder at startup, so art can be swapped or extended by replacing or adding PNG files under the same structure.

The editor also has `New Sprite` controls for terrain and object tools. These clone the active PNG into a generated sprite slot so newly created art can be placed immediately. Native builds write generated clones under `assets/generated/`; web builds create the same paths inside the browser asset filesystem for the current session.

## Controls

Full shortcut reference: [SHORTCUTS.md](SHORTCUTS.md).

- Left click/drag: paint, place, or erase with the active editor tool
- Right click: pick terrain/object into the brush
- Right mouse drag or `WASD`/arrow keys: pan
- Mouse wheel: zoom
- `Tab`: toggle editor overlay
- `Space`: advance setup from Player 1 to Player 2 to gameplay, then reset from gameplay/game over
- `1`/`2`/`3`/`4` or `T`/`O`/`X`/`V`: switch tools
- `Q`/`E`: cycle brush assets
- `Shift+1..9`: select quick asset slots
- `[` / `]`: adjust brush radius
- `Ctrl/Cmd+S` and `Ctrl/Cmd+L`: save/load map on native builds

Maps save as deterministic JSON to `assets/maps/default/map.json`. Native builds persist that file on disk; web builds mirror the same JSON into browser localStorage and restore it before loading.
