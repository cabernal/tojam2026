# Requirement Gap Tracking

This file tracks gaps found during the acceptance pass against `START.md` and `notes/BUILD.md`.
Completed items are crossed out in the commit that addresses them.

## Open Gaps

- [x] ~~Separate editor/game run modes are only partial. The current app is one executable with editor toggles, not explicit editor-only and game-only run targets.~~ Addressed with compile-time app modes plus `run-integrated`, `run-editor`, and `run-game` native steps.
- [x] ~~Web and native asset discovery are not equivalent. Native scans `assets/` recursively, while web uses a hardcoded manifest.~~ Addressed by replacing the hardcoded web list with a build-generated manifest from the same `assets/` tree.
- [x] ~~The level editor cannot create new sprite assets, only terrain variants and object placements.~~ Addressed with `New Sprite` controls that clone the active PNG into a generated sprite slot on native and web.
- [x] ~~The setup phase is incomplete. It lacks a real player-one/player-two handoff, setup visibility, placement limits, and a structured transition into gameplay.~~ Addressed with P1/P2 setup progression, active-player placement, setup limits, and opponent hiding during setup.
- [x] ~~Gameplay movement toward blocked citadels is fragile because citadels block their own target tile.~~ Addressed by routing units to walkable approach tiles around citadels.
- [x] ~~Flow fields are implemented and tested but not used by the runtime unit movement loop.~~ Addressed by moving units through cached flow fields with an A* fallback.
- [ ] Portal objects do not teleport or link units.
- [ ] Healing pods have negative damage stats, but the combat system skips non-damaging objects instead of healing allies.
- [ ] The editor layer panel is currently a set of toggles rather than a fuller layer control surface.
- [ ] Web map persistence is disabled while native save/load works.

## Already Verified

- [x] Native build passes with `zig build`.
- [x] Tests pass with `zig build test`.
- [x] Web build passes with `zig build web -Demsdk=/Users/bernal/git/emsdk`.
- [x] Web and native share the loading UI and current rendering path.
- [x] Basic web interaction works for object preview, placement, and playtest toggling.
