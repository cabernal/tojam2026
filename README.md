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

## Test

```sh
zig build test
```

## Web

```sh
zig build web -Demsdk=/path/to/emsdk
```

The browser bundle is written to `zig-out/web`.

## Assets

Starter PNGs from `../notes/Arid Badlands` are copied under `assets/`. The loader recursively scans that folder at startup, so art can be swapped or extended by replacing or adding PNG files under the same structure.

## Controls

- Left mouse: paint terrain or place the selected object while the editor is enabled
- Right mouse drag or WASD: pan
- Mouse wheel: zoom
- Tab: toggle editor overlay
- Space: toggle playtest
- 1/2/3: switch tool
- S/L: save/load map on native builds

Maps save as deterministic JSON to `assets/maps/default/map.json`.
