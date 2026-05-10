# Changelog

## May 9, 2026

### Added
- Added explicit native/web app modes for integrated editor, editor-only, and game-only startup.
- Added a consistent native and web loading experience with progress, stage names, asset counts, and failure feedback.
- Added setup handoff flow so players can place entities before starting play.
- Added flow-field unit movement toward enemy citadels.
- Added portal links and healing pods.
- Added collision battle engagement: nearby enemies stop moving, fight, and continue after combat resolves.
- Added select-mode hover inspection for tile, terrain, asset, and object properties.
- Added expanded editor layer controls, preview controls, and shortcut documentation.
- Added generated sprite creation controls and generated editor assets.
- Added audio engine support plus music, ambience, UI, gameplay, and unit sound assets.
- Added laser shooting visuals with trails, particles, and GPU shader rendering.
- Added an in-game perf readout for frame, CPU, simulation, FX, draw, submit, object, shot, and vertex load.
- Added GitHub Pages deployment workflow and a deployed game link.
- Added issue and enhancement tracking docs.

### Changed
- Replaced placeholder object rendering paths with the original sprite assets where available.
- Improved object sprite aspect handling so fallback sprites preserve their aspect ratio.
- Made native and web behavior consistent for loading, editor controls, previews, map persistence, and rendering.
- Persisted web map saves through `localStorage`.
- Switched laser effects from immediate-mode drawing to a batched GPU shader path.
- Added visual laser cadence and particle-pool backpressure so combat visuals do not overwrite live particles.
- Reworked asset loading so large terrain source sheets use small runtime sprite copies during startup.
- Changed the web asset bundle to avoid preloading oversized raw background sheets.
- Added a native asset-root fallback so detached macOS launches can find `assets/` from the executable location.

### Fixed
- Fixed web mouse picking and preview offset caused by stretched browser canvas sizing.
- Fixed citadel/object sprite placement and orientation issues.
- Fixed native loader failures caused by launching from the wrong working directory.
- Fixed web/native loading overlay mismatch.
- Fixed brush painting slowdowns by deferring pathing rebuilds during brush strokes.
- Fixed simulation hitches by reducing redundant pathing work and sharing citadel flow fields.
- Removed hot-loop square-root distance checks from combat, healing, and adjacent-contact tests.

### Performance
- Added perf instrumentation that showed particle rendering was cheap and simulation/pathing was the stutter source.
- Reduced duplicate flow-field creation for units targeting the same citadel.
- Reduced sprite startup decode cost by replacing four `6846x3956` runtime terrain loads with `256x148` runtime copies.
- Reduced the web bundle size by excluding raw oversized terrain background PNGs from the preloaded asset package.
