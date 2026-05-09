# Shortcuts

## Camera

| Input | Action |
| --- | --- |
| Right mouse drag | Pan camera |
| `W` / `A` / `S` / `D` | Pan camera |
| Arrow keys | Pan camera |
| Mouse wheel | Zoom in/out |

## Game

| Input | Action |
| --- | --- |
| `Space` | Advance setup from Player 1 to Player 2 to gameplay; reset from gameplay/game over |
| `Tab` | Toggle the editor overlay |

In `zig build run-game` or web builds made with `-Dapp-mode=game`, editor shortcuts are disabled and gameplay starts immediately.

## Editor Tools

| Input | Action |
| --- | --- |
| `1` or `T` | Terrain tool |
| `2` or `O` | Object tool |
| `3` or `X` | Erase tool |
| `4` or `V` | Select tool |

## Painting And Picking

| Input | Action |
| --- | --- |
| Left click | Paint terrain, place an object, or erase at the hovered tile |
| Left mouse drag | Continuous paint/erase while using terrain or erase tools |
| Right click | Pick the terrain/object under the cursor into the current brush |
| Right mouse drag | Pan camera instead of picking |
| `[` | Decrease brush radius |
| `]` | Increase brush radius |

## Brush Selection

| Input | Action |
| --- | --- |
| `Q` | Previous useful asset for the current tool |
| `E` | Next useful asset for the current tool |
| `Shift+1` through `Shift+9` | Select quick asset slot from the top preview strip |
| `Shift+Q` | Previous object kind and switch to object tool |
| `Shift+E` | Next object kind and switch to object tool |

## Map IO

| Input | Action |
| --- | --- |
| `Ctrl+S` / `Cmd+S` | Save map |
| `Ctrl+L` / `Cmd+L` | Load map |

Native saves to disk. Web saves the same JSON through browser localStorage.
