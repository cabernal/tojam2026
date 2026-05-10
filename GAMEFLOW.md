# Game Flow

## Game Mode Shell

When the app starts in `game` mode, it opens to a start menu before entering the battlefield. The menu shows the current preview/edit map, defaulting to the built-in `Default Map`.

Menu options:

- `Choose Map`
- `Map Editor`
- `Start Selected Level`
- `Start Random Game`

## Choose Map

`Choose Map` opens a map viewer and selector.

The view lists available maps. Each map row has:

- `Select`: saves the selected map and returns to the start menu.
- `Edit`: loads that map and opens it in the map editor.

The default map is selected when no other map has been chosen. Returning to the menu shows the current preview/edit map name. `Start Selected Level` loads that map directly. `Start Random Game` rolls a random level from the available maps.

`Default Map` is the built-in starter battlefield. Editable maps are JSON files under `assets/maps/generated/`, and the selector includes the generated starter maps:

- `Canyon Divide`
- `Oasis Ring`
- `Ruins Crossfire`
- `Open Dunes`
- `Maze Warren`
- `Island Chain`
- `Four Lanes`
- `Crossfire Plaza`
- `Spiral Ruins`
- `Twin Forts`

## Map Editor

The map editor uses the normal editor surface. Generated maps can be saved and deleted; the built-in `Default Map` can be opened as a reference but is protected from saving and deletion.

Editor controls:

- `Save`: saves the current map.
- `Delete`: deletes the selected map when it is not the default map.
- `Exit`: returns to the start menu.

The editor remains the normal editing experience for terrain, objects, erase, select, preview, layers, and debug controls.

## Start Game And Setup

`Start Selected Level` loads the current preview/edit map and starts player setup. `Start Random Game` chooses one available map at random, loads it, and starts player setup.

Setup flow:

1. Player 1 places their entities.
2. The menu highlights Player 1 in blue.
3. Clicking `Player Setup` advances to Player 2 setup.
4. Player 2 places their entities.
5. Once Player 2 is done, the setup action changes to `Start Game`.
6. Clicking `Start Game` begins the battle.

During setup, the game shows how many entities of each type the active player has placed and how many remain. If a player erases an entity, that entity returns to the available count.

## Pause Menu

During an active battle, pressing `Escape` pauses the simulation and opens the pause menu.

Pause menu options:

- `Continue`: resumes the battle.
- `Cancel Game`: cancels the current battle, reloads the selected map preview, and returns to the start menu.

Pressing `Escape` again while paused also resumes the battle.

## Placement Limits

Placement limits are per player during setup:

- Citadel: 1
- Imperator: 1
- Infantry, Captain, Artillery: 14 combined
- Portal: 2
- Healing Pod: 2
- Outpost, Defense Grid: 4 combined
- Obstacle: 12

## Game Over

When the game ends, show a toast using the winning player's color.

The toast includes:

- The winning player.
- The reason the player won.

Current win condition:

- Player 1 wins when Player 2's Imperator is destroyed.
- Player 2 wins when Player 1's Imperator is destroyed.
