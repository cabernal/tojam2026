const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const slog = sokol.log;
const stime = sokol.time;
const c = @import("cimgui.zig").c;

const runtime = @import("runtime/game.zig");
const render = @import("runtime/render.zig");
const map_mod = @import("map/map.zig");
const map_io = @import("map/map_io.zig");
const schema = @import("map/schema.zig");
const asset_loader = @import("assets/asset_loader.zig");
const sprite_defs = @import("assets/sprite_defs.zig");
const png_loader = @import("assets/png_loader.zig");
const editor_mod = @import("editor/editor.zig");
const tools = @import("editor/tools.zig");
const imgui_ui = @import("editor/imgui_ui.zig");
const platform = @import("platform/web.zig");
const sim_mod = @import("runtime/simulation.zig");
const audio_mod = @import("audio/audio.zig");

const TileW: f32 = 64;
const TileH: f32 = 32;
const GameTitle = "Imperator's Gambit";
const EventBlurb = "Created at TOJam 2026: Twenty years, one weekend";
const BuildVersion = build_options.build_version;
const MaxSprites = asset_loader.MaxAssets;
const NoAsset: u16 = std.math.maxInt(u16);
const MaxLaserBeams = 192;
const MaxLaserParticles = 1024;
const MaxLaserEmitters = map_mod.MaxObjects;
const LaserBeamVertices = 12;
const LaserParticleVertices = 12;
const MaxLaserFxVertices = MaxLaserBeams * LaserBeamVertices + MaxLaserParticles * LaserParticleVertices;
const MaxShaderTileVertices = map_mod.MapW * map_mod.MapH * 6;
const LaserBeamLife: f32 = 0.13;
const LaserEmitterIdleSeconds: f32 = 0.75;
const ReplayFrameSeconds: f32 = 0.25;
const MaxReplayFrames = 2400;
const MaxReplayShots = 6000;
const StarParallaxLayers = [_]StarLayer{
    .{ .count = 880, .parallax = 0.010, .zoom_reactivity = 0.030, .drift_x = 8.0, .drift_y = 1.8, .radius_min = 0.46, .radius_range = 0.62, .alpha = 0.36, .tint = .{ 0.62, 0.78, 0.96 } },
    .{ .count = 720, .parallax = 0.022, .zoom_reactivity = 0.055, .drift_x = 13.0, .drift_y = 3.0, .radius_min = 0.56, .radius_range = 0.84, .alpha = 0.44, .tint = .{ 0.78, 0.84, 0.98 } },
    .{ .count = 520, .parallax = 0.040, .zoom_reactivity = 0.085, .drift_x = 20.0, .drift_y = 4.7, .radius_min = 0.70, .radius_range = 1.08, .alpha = 0.54, .tint = .{ 0.96, 0.88, 0.68 } },
    .{ .count = 320, .parallax = 0.066, .zoom_reactivity = 0.115, .drift_x = 29.0, .drift_y = 6.4, .radius_min = 0.92, .radius_range = 1.28, .alpha = 0.50, .tint = .{ 0.72, 0.96, 1.0 } },
};
const MusicTrack = struct {
    id: audio_mod.MusicId,
    name: []const u8,
    gain: f32,
};
const MusicPlaylist = [_]MusicTrack{
    .{ .id = .scifi, .name = "Scifi", .gain = 0.34 },
    .{ .id = .scifi2, .name = "Scifi 2", .gain = 0.58 },
    .{ .id = .scifitrimmed, .name = "Scifi Trimmed", .gain = 0.54 },
    .{ .id = .simple_bgm_loop, .name = "Simple BGM Loop", .gain = 0.24 },
};
const AmbientGain: f32 = 0.18;
const ShotSfxGain: f32 = 0.42;
const HitSfxGain: f32 = 0.22;
const StaticEditableMaps = [_]struct {
    name: []const u8,
    rel_path: []const u8,
}{
    .{ .name = "Canyon Divide", .rel_path = "maps/generated/canyon_divide.json" },
    .{ .name = "Oasis Ring", .rel_path = "maps/generated/oasis_ring.json" },
    .{ .name = "Ruins Crossfire", .rel_path = "maps/generated/ruins_crossfire.json" },
    .{ .name = "Open Dunes", .rel_path = "maps/generated/open_dunes.json" },
    .{ .name = "Maze Warren", .rel_path = "maps/generated/maze_warren.json" },
    .{ .name = "Island Chain", .rel_path = "maps/generated/island_chain.json" },
    .{ .name = "Four Lanes", .rel_path = "maps/generated/four_lanes.json" },
    .{ .name = "Crossfire Plaza", .rel_path = "maps/generated/crossfire_plaza.json" },
    .{ .name = "Spiral Ruins", .rel_path = "maps/generated/spiral_ruins.json" },
    .{ .name = "Twin Forts", .rel_path = "maps/generated/twin_forts.json" },
};

const LoadingPhase = enum {
    intro,
    scan_assets,
    load_assets,
    sprite_defs,
    assign_world,
    complete,
    failed,
};

const AppMode = enum {
    integrated,
    editor,
    game,
};

const GameShellScreen = enum {
    disabled,
    menu,
    sound,
    rules,
    credits,
    choose_map,
    map_editor,
    setup,
    battle,
    replay,
};

const MaxGameMaps = 16;

const GameMapChoice = struct {
    path: [256]u8 = [_]u8{0} ** 256,
    path_len: usize = 0,
    name: [96]u8 = [_]u8{0} ** 96,
    name_len: usize = 0,
    protected: bool = false,
    builtin: bool = false,

    fn set(self: *GameMapChoice, name: []const u8, path: []const u8, protected: bool, is_builtin: bool) void {
        self.name_len = copyToBuffer(self.name[0..], name);
        self.path_len = copyToBuffer(self.path[0..], path);
        self.protected = protected;
        self.builtin = is_builtin;
    }

    fn nameSlice(self: *const GameMapChoice) []const u8 {
        return self.name[0..self.name_len];
    }

    fn pathSlice(self: *const GameMapChoice) []const u8 {
        return self.path[0..self.path_len];
    }
};

const EntityCounts = struct {
    citadel: usize = 0,
    imperator: usize = 0,
    infantry: usize = 0,
    captain: usize = 0,
    artillery: usize = 0,
    portal: usize = 0,
    healing_pod: usize = 0,
    outpost: usize = 0,
    defense_grid: usize = 0,
    obstacle: usize = 0,

    fn mobile(self: EntityCounts) usize {
        return self.infantry + self.captain + self.artillery;
    }

    fn structures(self: EntityCounts) usize {
        return self.outpost + self.defense_grid;
    }
};

pub const ObjectPlacementSummary = struct {
    limited: bool = false,
    placed: usize = 0,
    limit: usize = 0,
    remaining: usize = 0,
    full: bool = false,
};

const GameToast = struct {
    active: bool = false,
    timer: f32 = 0,
    winner: u8 = 0,
    message: [160]u8 = [_]u8{0} ** 160,
    message_len: usize = 0,

    fn text(self: *const GameToast) []const u8 {
        return self.message[0..self.message_len];
    }
};

const LoadingState = struct {
    phase: LoadingPhase = .intro,
    frames_seen: u32 = 0,
    asset_index: usize = 0,
    loaded_assets: usize = 0,
    skipped_assets: usize = 0,
    progress: f32 = 0.04,
    error_name: [64]u8 = undefined,
    error_len: usize = 0,

    fn errorSlice(self: *const LoadingState) []const u8 {
        return self.error_name[0..self.error_len];
    }
};

const Vec2 = struct {
    x: f32,
    y: f32,
};

const StarLayer = struct {
    count: usize,
    parallax: f32,
    zoom_reactivity: f32,
    drift_x: f32,
    drift_y: f32,
    radius_min: f32,
    radius_range: f32,
    alpha: f32,
    tint: [3]f32,
};

const Sprite = struct {
    image: sg.Image = .{},
    view: sg.View = .{},
    width: f32 = 0,
    height: f32 = 0,

    fn valid(self: Sprite) bool {
        return self.image.id != 0 and self.view.id != 0;
    }
};

const LaserBeam = struct {
    active: bool = false,
    start: Vec2 = .{ .x = 0, .y = 0 },
    end: Vec2 = .{ .x = 0, .y = 0 },
    life: f32 = 0,
    max_life: f32 = LaserBeamLife,
    color: [4]f32 = .{ 1, 1, 1, 1 },
};

const LaserParticle = struct {
    active: bool = false,
    pos: Vec2 = .{ .x = 0, .y = 0 },
    vel: Vec2 = .{ .x = 0, .y = 0 },
    accel: Vec2 = .{ .x = 0, .y = 0 },
    life: f32 = 0,
    max_life: f32 = 0,
    radius: f32 = 1,
    color: [4]f32 = .{ 1, 1, 1, 1 },
};

const LaserEmitter = struct {
    active: bool = false,
    attacker_id: u32 = 0,
    cooldown: f32 = 0,
    idle_seconds: f32 = 0,
};

const ReplayFrame = struct {
    time: f32 = 0,
    object_count: usize = 0,
    objects: [map_mod.MaxObjects]map_mod.MapObject = [_]map_mod.MapObject{.{}} ** map_mod.MaxObjects,
};

const ReplayShot = struct {
    time: f32 = 0,
    event: sim_mod.ShotEvent = .{},
};

const LaserFxVertex = extern struct {
    position: [2]f32 = .{ 0, 0 },
    color: [4]f32 = .{ 1, 1, 1, 1 },
};

const ShaderTileVertex = extern struct {
    position: [2]f32 = .{ 0, 0 },
    uv: [2]f32 = .{ 0, 0 },
    kind: f32 = 0,
    seed: f32 = 0,
    time: f32 = 0,
};

pub const PerfStats = struct {
    frame_ms: f32 = 0,
    fps: f32 = 0,
    cpu_ms: f32 = 0,
    update_ms: f32 = 0,
    sim_ms: f32 = 0,
    fx_update_ms: f32 = 0,
    shot_ms: f32 = 0,
    ui_ms: f32 = 0,
    world_ms: f32 = 0,
    sgl_ms: f32 = 0,
    laser_draw_ms: f32 = 0,
    imgui_render_ms: f32 = 0,
    submit_ms: f32 = 0,
    raw_shot_events: usize = 0,
    visual_shots: usize = 0,
    object_count: usize = 0,
    active_objects: usize = 0,
    active_beams: usize = 0,
    active_particles: usize = 0,
    laser_vertices: usize = 0,
};

pub const AppState = struct {
    allocator: std.mem.Allocator = undefined,
    game: runtime.RuntimeGame = undefined,
    catalog: asset_loader.AssetCatalog = undefined,
    object_sprites: sprite_defs.SpriteDefinitions = undefined,
    editor: editor_mod.EditorState = .{},
    sprites: [MaxSprites]Sprite = [_]Sprite{.{}} ** MaxSprites,
    sprite_count: usize = 0,
    tojam_logo_sprite: Sprite = .{},
    tojam_goat_sprite: Sprite = .{},
    sampler: sg.Sampler = .{},
    alpha_pipeline: sgl.Pipeline = .{},
    pass_action: sg.PassAction = .{},
    laser_fx_shader: sg.Shader = .{},
    laser_fx_pipeline: sg.Pipeline = .{},
    laser_fx_vertex_buffer: sg.Buffer = .{},
    shader_tile_shader: sg.Shader = .{},
    shader_tile_pipeline: sg.Pipeline = .{},
    shader_tile_vertex_buffer: sg.Buffer = .{},
    initialized: bool = false,
    allow_editor: bool = true,
    loading: LoadingState = .{},
    mouse: Vec2 = .{ .x = 0, .y = 0 },
    last_mouse: Vec2 = .{ .x = 0, .y = 0 },
    panning: bool = false,
    painting: bool = false,
    pathing_dirty: bool = false,
    generated_asset_counter: u32 = 0,
    right_pan_start: Vec2 = .{ .x = 0, .y = 0 },
    right_pan_moved: bool = false,
    keys: [512]bool = [_]bool{false} ** 512,
    camera: Vec2 = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,
    starfield_time: f32 = 0,
    laser_beams: [MaxLaserBeams]LaserBeam = [_]LaserBeam{.{}} ** MaxLaserBeams,
    laser_particles: [MaxLaserParticles]LaserParticle = [_]LaserParticle{.{}} ** MaxLaserParticles,
    laser_emitters: [MaxLaserEmitters]LaserEmitter = [_]LaserEmitter{.{}} ** MaxLaserEmitters,
    laser_fx_vertices: [MaxLaserFxVertices]LaserFxVertex = undefined,
    shader_tile_vertices: [MaxShaderTileVertices]ShaderTileVertex = undefined,
    laser_beam_cursor: usize = 0,
    laser_particle_cursor: usize = 0,
    laser_emitter_cursor: usize = 0,
    laser_beam_active_count: usize = 0,
    laser_particle_active_count: usize = 0,
    laser_fx_vertex_count: usize = 0,
    shader_tile_vertex_count: usize = 0,
    laser_rng: u32 = 0x6d2b79f5,
    map_rng: u32 = 0x9e3779b9,
    perf: PerfStats = .{},
    audio: audio_mod.Engine = .{},
    music_started: bool = false,
    music_track_index: usize = 0,
    music_muted: bool = false,
    sfx_volume: f32 = 1.0,
    music_volume: f32 = 1.0,
    ambient_volume: f32 = 1.0,
    game_shell_screen: GameShellScreen = .disabled,
    rules_show_entities: bool = false,
    maps: [MaxGameMaps]GameMapChoice = [_]GameMapChoice{.{}} ** MaxGameMaps,
    map_count: usize = 0,
    selected_map_index: usize = 0,
    editing_map_index: usize = 0,
    last_sim_phase: sim_mod.Phase = .setup_player_one,
    game_over_toast: GameToast = .{},
    game_paused: bool = false,
    replay_frames: std.ArrayList(ReplayFrame) = .empty,
    replay_shots: std.ArrayList(ReplayShot) = .empty,
    replay_recording: bool = false,
    replay_available: bool = false,
    replay_elapsed: f32 = 0,
    replay_capture_accum: f32 = 0,
    replay_playing: bool = false,
    replay_playhead: f32 = 0,
    replay_frame_index: usize = 0,
    replay_shot_cursor: usize = 0,

    pub fn init(self: *AppState, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.catalog = asset_loader.AssetCatalog.init(allocator);
        self.object_sprites = sprite_defs.SpriteDefinitions.init(allocator);
        self.game = runtime.RuntimeGame.init(allocator) catch |err| {
            std.log.err("runtime init failed: {s}", .{@errorName(err)});
            return;
        };
        self.configureStartupMode();
        self.camera = .{ .x = 0, .y = 420 };
        self.zoom = 1.0;
        self.editor.setStatus("Editor ready. Assets are loaded from {s}.", .{platform.assetRoot()});

        stime.setup();
        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });
        sgl.setup(.{ .logger = .{ .func = slog.func } });
        simgui.setup(.{ .logger = .{ .func = slog.func } });
        self.audio.init(allocator, platform.assetRoot());

        var alpha_desc: sg.PipelineDesc = .{};
        alpha_desc.colors[0].blend.enabled = true;
        alpha_desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA;
        alpha_desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA;
        alpha_desc.colors[0].blend.src_factor_alpha = .ONE;
        alpha_desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA;
        self.alpha_pipeline = sgl.makePipeline(alpha_desc);

        self.pass_action = .{};
        self.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0.075, .g = 0.082, .b = 0.078, .a = 1.0 },
        };
        self.sampler = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        });
        self.initLaserFxPipeline();
        self.initShaderTilePipeline();

        self.initialized = true;
    }

    pub fn cleanup(self: *AppState) void {
        if (!self.initialized) return;
        destroySprite(&self.tojam_logo_sprite);
        destroySprite(&self.tojam_goat_sprite);
        for (self.sprites[0..self.sprite_count]) |*sprite| destroySprite(sprite);
        if (self.shader_tile_vertex_buffer.id != 0) sg.destroyBuffer(self.shader_tile_vertex_buffer);
        if (self.shader_tile_pipeline.id != 0) sg.destroyPipeline(self.shader_tile_pipeline);
        if (self.shader_tile_shader.id != 0) sg.destroyShader(self.shader_tile_shader);
        if (self.laser_fx_vertex_buffer.id != 0) sg.destroyBuffer(self.laser_fx_vertex_buffer);
        if (self.laser_fx_pipeline.id != 0) sg.destroyPipeline(self.laser_fx_pipeline);
        if (self.laser_fx_shader.id != 0) sg.destroyShader(self.laser_fx_shader);
        if (self.sampler.id != 0) sg.destroySampler(self.sampler);
        if (self.alpha_pipeline.id != 0) sgl.destroyPipeline(self.alpha_pipeline);
        self.object_sprites.deinit();
        self.catalog.deinit();
        self.replay_frames.deinit(self.allocator);
        self.replay_shots.deinit(self.allocator);
        self.game.deinit();
        self.audio.deinit();
        simgui.shutdown();
        sgl.shutdown();
        sg.shutdown();
        self.initialized = false;
    }

    pub fn frame(self: *AppState) void {
        if (!self.initialized) return;
        const frame_start = stime.now();
        var dt: f32 = @floatCast(sapp.frameDuration());
        if (!(dt > 0 and dt < 0.25)) dt = 1.0 / 60.0;
        self.perf.frame_ms = dt * 1000.0;
        self.perf.fps = if (dt > 0) 1.0 / dt else 0;
        self.perf.raw_shot_events = 0;
        self.perf.visual_shots = 0;
        self.updateStarfield(dt);

        if (!self.ready() and self.loading.frames_seen > 0 and self.loading.phase != .failed) {
            self.advanceLoading();
        }
        const is_ready = self.ready();
        if (is_ready) {
            self.ensureBackgroundAudio();
            self.updateMusicCycle();
            const update_start = stime.now();
            self.syncEditorPlayerWithSetup();
            self.updateHoverAt(self.mouse);
            if (!self.painting) self.flushPathingRebuild();
            self.handleKeyboardCamera(dt);
            const sim_start = stime.now();
            const paused = self.battlePaused();
            if (!paused) {
                self.game.update(dt);
                self.updateReplayRecording(dt);
                self.updateReplayPlayback(dt);
            }
            const sim_end = stime.now();
            const fx_start = stime.now();
            if (!paused) self.updateLaserFx(dt);
            const fx_end = stime.now();
            const shot_start = stime.now();
            if (!paused) self.consumeShotEvents();
            const shot_end = stime.now();
            self.updateGameShell(dt);
            smoothMs(&self.perf.sim_ms, elapsedMs(sim_start, sim_end));
            smoothMs(&self.perf.fx_update_ms, elapsedMs(fx_start, fx_end));
            smoothMs(&self.perf.shot_ms, elapsedMs(shot_start, shot_end));
            smoothMs(&self.perf.update_ms, elapsedMs(update_start, shot_end));
            self.refreshPerfCounters();
        }

        const ui_start = stime.now();
        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = dt,
            .dpi_scale = sapp.dpiScale(),
        });
        if (is_ready) {
            if (self.shouldDrawEditorUi()) imgui_ui.draw(self);
            self.drawGameShellUi();
        } else {
            self.drawLoadingUi();
        }
        const ui_end = stime.now();
        smoothMs(&self.perf.ui_ms, elapsedMs(ui_start, ui_end));

        sg.beginPass(.{
            .action = self.pass_action,
            .swapchain = sglue.swapchain(),
        });

        self.prepareScreenSgl();

        const world_start = stime.now();
        if (is_ready) {
            self.drawWorld();
        } else {
            self.drawLoadingBackdrop();
        }
        const world_end = stime.now();
        smoothMs(&self.perf.world_ms, elapsedMs(world_start, world_end));
        const sgl_start = stime.now();
        sgl.draw();
        const sgl_end = stime.now();
        smoothMs(&self.perf.sgl_ms, elapsedMs(sgl_start, sgl_end));
        const laser_start = stime.now();
        if (is_ready) self.drawShaderTiles();
        if (is_ready) self.drawLaserFx();
        const laser_end = stime.now();
        smoothMs(&self.perf.laser_draw_ms, elapsedMs(laser_start, laser_end));
        const imgui_render_start = stime.now();
        simgui.render();
        const imgui_render_end = stime.now();
        smoothMs(&self.perf.imgui_render_ms, elapsedMs(imgui_render_start, imgui_render_end));
        const submit_start = stime.now();
        sg.endPass();
        sg.commit();
        const submit_end = stime.now();
        smoothMs(&self.perf.submit_ms, elapsedMs(submit_start, submit_end));
        smoothMs(&self.perf.cpu_ms, elapsedMs(frame_start, submit_end));

        if (!is_ready and self.loading.phase != .complete) {
            self.loading.frames_seen +|= 1;
        }
    }

    pub fn handleEvent(self: *AppState, ev: sapp.Event) void {
        const consumed = if (self.ready()) simgui.handleEvent(ev) else false;
        if (!self.ready()) return;
        switch (ev.type) {
            .MOUSE_MOVE => {
                self.last_mouse = self.mouse;
                self.mouse = .{ .x = ev.mouse_x, .y = ev.mouse_y };
                if (self.panning) {
                    const dx = self.mouse.x - self.last_mouse.x;
                    const dy = self.mouse.y - self.last_mouse.y;
                    self.camera.x -= dx / self.zoom;
                    self.camera.y -= dy / self.zoom;
                    const total_dx = self.mouse.x - self.right_pan_start.x;
                    const total_dy = self.mouse.y - self.right_pan_start.y;
                    if (total_dx * total_dx + total_dy * total_dy > 16) self.right_pan_moved = true;
                } else if (self.painting and !consumed) {
                    self.applyEditorAt(self.mouse);
                }
            },
            .MOUSE_DOWN => {
                self.mouse = .{ .x = ev.mouse_x, .y = ev.mouse_y };
                if (ev.mouse_button == .RIGHT) {
                    self.panning = true;
                    self.right_pan_start = self.mouse;
                    self.right_pan_moved = false;
                } else if (ev.mouse_button == .LEFT and !consumed) {
                    self.painting = true;
                    self.applyEditorAt(self.mouse);
                }
            },
            .MOUSE_UP => {
                if (ev.mouse_button == .RIGHT) {
                    const was_pick = self.panning and !self.right_pan_moved and !consumed;
                    self.panning = false;
                    if (was_pick) self.pickEditorAt(self.mouse);
                } else if (ev.mouse_button == .LEFT) {
                    self.painting = false;
                    self.flushPathingRebuild();
                }
            },
            .MOUSE_SCROLL => {
                if (!consumed) {
                    const next = self.zoom * (1.0 + ev.scroll_y * 0.08);
                    self.zoom = std.math.clamp(next, 0.45, 2.6);
                }
            },
            .KEY_DOWN => {
                self.setKey(ev.key_code, true);
                if (ev.key_repeat) return;
                switch (ev.key_code) {
                    .TAB => {
                        if (self.editorToggleAllowed()) {
                            self.editor.enabled = !self.editor.enabled;
                            self.audio.playSfx(if (self.editor.enabled) .panel_open else .panel_close);
                        }
                    },
                    .SPACE => self.togglePlaytest(),
                    .ESCAPE => self.handleEscapeKey(),
                    .S => if (hasCommandModifier(ev.modifiers)) self.saveMap(),
                    .L => if (hasCommandModifier(ev.modifiers)) self.loadMap(),
                    ._1 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(0) else self.setEditorTool(.terrain);
                    },
                    ._2 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(1) else self.setEditorTool(.object);
                    },
                    ._3 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(2) else self.setEditorTool(.erase);
                    },
                    ._4 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(3) else self.setEditorTool(.select);
                    },
                    ._5 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(4);
                    },
                    ._6 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(5);
                    },
                    ._7 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(6);
                    },
                    ._8 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(7);
                    },
                    ._9 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(8);
                    },
                    .Q => if (hasShift(ev.modifiers)) self.cycleObjectKind(-1) else self.cycleBrushAsset(-1),
                    .E => if (hasShift(ev.modifiers)) self.cycleObjectKind(1) else self.cycleBrushAsset(1),
                    .LEFT_BRACKET => self.adjustBrushRadius(-1),
                    .RIGHT_BRACKET => self.adjustBrushRadius(1),
                    .T => self.setEditorTool(.terrain),
                    .O => self.setEditorTool(.object),
                    .X => self.setEditorTool(.erase),
                    .V => self.setEditorTool(.select),
                    else => {},
                }
            },
            .KEY_UP => self.setKey(ev.key_code, false),
            else => {},
        }
    }

    pub fn saveMap(self: *AppState) void {
        if (self.game_shell_screen == .map_editor) {
            self.saveShellMap();
            return;
        }
        if (!platform.canPersistMaps()) {
            self.editor.setStatus("Map save is disabled on this platform.", .{});
            return;
        }
        map_io.save(schema.DefaultMapPath, &self.game.map) catch |err| {
            self.editor.setStatus("Save failed: {s}", .{@errorName(err)});
            return;
        };
        if (!platform.persistMap(schema.DefaultMapPath)) {
            self.editor.setStatus("Saved map, but browser persistence failed.", .{});
            return;
        }
        self.editor.setStatus("Saved {s}", .{schema.DefaultMapPath});
    }

    pub fn loadMap(self: *AppState) void {
        if (self.game_shell_screen == .map_editor) {
            _ = self.loadShellMap(self.editing_map_index, true);
            return;
        }
        if (!platform.canPersistMaps()) {
            self.editor.setStatus("Map load is disabled on this platform.", .{});
            return;
        }
        if (!platform.restoreMap(schema.DefaultMapPath)) {
            self.editor.setStatus("No saved map found.", .{});
            return;
        }
        const loaded = map_io.load(self.allocator, schema.DefaultMapPath) catch |err| {
            self.editor.setStatus("Load failed: {s}", .{@errorName(err)});
            return;
        };
        self.game.map = loaded;
        self.assignObjectAssets(true);
        self.game.rebuildPathing() catch {};
        self.pathing_dirty = false;
        self.editor.setStatus("Loaded {s}", .{schema.DefaultMapPath});
    }

    pub fn resetDefaultMap(self: *AppState) void {
        self.game.map = map_mod.GameMap.initDefault();
        self.game.simulation.resetSetup();
        self.clearLaserFx();
        self.syncEditorPlayerWithSetup();
        self.assignStarterAssets();
        self.game.rebuildPathing() catch {};
        self.pathing_dirty = false;
        self.editor.setStatus("Reset to starter battlefield.", .{});
    }

    pub fn selectAsset(self: *AppState, asset_id: u16) void {
        self.editor.brush_asset_id = asset_id;
        self.audio.playSfx(.hover_tick);
        if (self.catalog.get(asset_id)) |asset| {
            self.editor.setStatus("Selected asset {d}: {s}", .{ asset.id, asset.name });
        }
    }

    fn setEditorTool(self: *AppState, tool: tools.Tool) void {
        if (self.editor.tool != tool) {
            self.audio.playSfx(.tool_cycle);
        }
        self.editor.tool = tool;
    }

    pub fn createGeneratedTerrainAsset(self: *AppState) void {
        self.createGeneratedSpriteAsset(.terrain, self.editor.brush_asset_id) catch |err| {
            self.editor.setStatus("New terrain sprite failed: {s}", .{@errorName(err)});
        };
    }

    pub fn createGeneratedObjectAsset(self: *AppState) void {
        const source_id = self.assetForObjectKind(self.editor.object_kind);
        const kind = assetKindForObjectKind(self.editor.object_kind);
        self.createGeneratedSpriteAsset(kind, source_id) catch |err| {
            self.editor.setStatus("New object sprite failed: {s}", .{@errorName(err)});
        };
    }

    pub fn togglePlaytest(self: *AppState) void {
        if (self.game_shell_screen != .disabled) {
            if (self.game_shell_screen == .setup) self.advanceGameSetupAction();
            return;
        }
        if (!self.allow_editor) return;
        self.game.simulation.togglePlay();
        self.clearLaserFx();
        self.syncEditorPlayerWithSetup();
        self.audio.playSfx(.click_confirm);
        self.editor.setStatus("Phase: {s}", .{@tagName(self.game.simulation.phase)});
    }

    fn shouldDrawEditorUi(self: *const AppState) bool {
        return switch (self.game_shell_screen) {
            .disabled, .map_editor => self.editor.enabled,
            else => false,
        };
    }

    fn editorToggleAllowed(self: *const AppState) bool {
        return self.allow_editor and (self.game_shell_screen == .disabled or self.game_shell_screen == .map_editor);
    }

    fn updateGameShell(self: *AppState, dt: f32) void {
        if (self.game_over_toast.active) {
            self.game_over_toast.timer -= dt;
            if (self.game_over_toast.timer <= 0) self.game_over_toast.active = false;
        }

        const phase = self.game.simulation.phase;
        if (self.game_shell_screen == .battle and self.last_sim_phase != .game_over and phase == .game_over) {
            self.showGameOverToast();
        }
        self.last_sim_phase = phase;
    }

    fn ensureBackgroundAudio(self: *AppState) void {
        if (self.music_started) return;
        self.applyAudioLevels();
        self.music_track_index %= MusicPlaylist.len;
        if (!self.music_muted) self.playCurrentMusicTrack();
        self.audio.playAmbient(.scifi_city_ambient_loop, AmbientGain);
        self.music_started = true;
    }

    fn updateMusicCycle(self: *AppState) void {
        if (!self.music_started or self.music_muted or self.audio.musicActive()) return;
        self.nextMusicTrack(false);
    }

    fn nextMusicTrack(self: *AppState, announce: bool) void {
        self.music_track_index = (self.music_track_index + 1) % MusicPlaylist.len;
        if (!self.music_muted) self.playCurrentMusicTrack();
        if (announce) {
            self.audio.playSfx(.click_confirm);
            self.editor.setStatus("Music: {s}", .{self.currentMusicName()});
        }
    }

    fn toggleMusicMute(self: *AppState) void {
        self.music_muted = !self.music_muted;
        if (self.music_muted) {
            self.audio.stopMusic();
            self.applyAudioLevels();
            self.editor.setStatus("Music muted. Ambient remains on.", .{});
        } else {
            self.applyAudioLevels();
            self.playCurrentMusicTrack();
            self.editor.setStatus("Music: {s}", .{self.currentMusicName()});
        }
        self.audio.playSfx(.click_confirm);
    }

    fn playCurrentMusicTrack(self: *AppState) void {
        const track = MusicPlaylist[self.music_track_index % MusicPlaylist.len];
        self.audio.playMusic(track.id, track.gain, false);
    }

    fn currentMusicName(self: *const AppState) []const u8 {
        return MusicPlaylist[self.music_track_index % MusicPlaylist.len].name;
    }

    fn musicMuteLabel(self: *const AppState) [:0]const u8 {
        return if (self.music_muted) "Unmute Music" else "Mute Music";
    }

    fn applyAudioLevels(self: *AppState) void {
        self.audio.setSfxVolume(self.sfx_volume);
        self.audio.setMusicVolume(if (self.music_muted) 0 else self.music_volume);
        self.audio.setAmbientVolume(self.ambient_volume);
    }

    fn drawGameShellUi(self: *AppState) void {
        switch (self.game_shell_screen) {
            .disabled => {},
            .menu => self.drawMainMenuShell(),
            .sound => self.drawSoundShell(),
            .rules => self.drawRulesShell(),
            .credits => self.drawCreditsShell(),
            .choose_map => self.drawChooseMapShell(),
            .map_editor => self.drawMapEditorShell(),
            .setup => self.drawSetupShell(),
            .battle => self.drawBattleShell(),
            .replay => self.drawReplayShell(),
        }
        self.drawGameOverToast();
    }

    fn drawMainMenuShell(self: *AppState) void {
        var selected_buf: [160]u8 = undefined;
        const selected_z = std.fmt.bufPrintZ(&selected_buf, "Selected map: {s}", .{self.selectedMapName()}) catch return;

        const panel_w = @min(420, @max(300, sapp.widthf() - 48));
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(panel_w, 408), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Start Menu##game-shell", null, flags);
        defer c.igEnd();

        c.igTextUnformatted(GameTitle, null);
        var version_buf: [96]u8 = undefined;
        const version_z = std.fmt.bufPrintZ(&version_buf, "Version: {s}", .{BuildVersion}) catch "Version: unknown";
        c.igTextUnformatted(version_z.ptr, null);
        c.igSeparator();
        c.igTextUnformatted(selected_z.ptr, null);
        c.igSpacing();

        if (c.igButton("Select Level", uiV2(-1, 30))) self.enterChooseMapShell();
        if (c.igButton("Level Editor", uiV2(-1, 30))) self.enterMapEditorShell(self.selected_map_index);
        if (c.igButton("Sound", uiV2(-1, 30))) self.enterSoundShell();
        if (c.igButton("Rules", uiV2(-1, 30))) self.enterRulesShell();
        if (c.igButton("Credits", uiV2(-1, 30))) self.enterCreditsShell();
        c.igSpacing();
        c.igPushStyleColor_U32(c.ImGuiCol_Button, uiCol32(42, 119, 174, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, uiCol32(54, 143, 204, 255));
        defer c.igPopStyleColor(2);
        if (c.igButton("Start Selected Level", uiV2(-1, 34))) self.startSelectedGameSetup();
        if (c.igButton("Start Random Game", uiV2(-1, 34))) self.startRandomGameSetup();
        c.igSpacing();
        c.igSeparator();
        c.igTextUnformatted(EventBlurb, null);
    }

    fn drawSoundShell(self: *AppState) void {
        const panel_w = @min(420, @max(300, sapp.widthf() - 48));
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(panel_w, 310), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Sound##game-shell", null, flags);
        defer c.igEnd();

        c.igTextUnformatted("Sound", null);
        c.igSeparator();

        self.drawVolumeSlider("SFX", "##sfx-volume", &self.sfx_volume);
        self.drawVolumeSlider("Music", "##music-volume", &self.music_volume);
        self.drawVolumeSlider("Ambience", "##ambience-volume", &self.ambient_volume);

        c.igSpacing();
        var music_buf: [96]u8 = undefined;
        const music_z = std.fmt.bufPrintZ(&music_buf, "Song: {s}{s}", .{ self.currentMusicName(), if (self.music_muted) " (muted)" else "" }) catch return;
        c.igTextUnformatted(music_z.ptr, null);
        if (c.igButton("Skip Song", uiV2(-1, 28))) self.nextMusicTrack(true);
        if (c.igButton(self.musicMuteLabel().ptr, uiV2(-1, 28))) self.toggleMusicMute();

        c.igSeparator();
        if (c.igButton("Back", uiV2(-1, 30))) self.enterMainMenuShell();
    }

    fn drawVolumeSlider(self: *AppState, label: [:0]const u8, id: [:0]const u8, value: *f32) void {
        c.igTextUnformatted(label.ptr, null);
        c.igSameLine(0, 12);
        c.igSetNextItemWidth(-1);
        if (c.igSliderFloat(id.ptr, value, 0, 1, "%.2f", 0)) self.applyAudioLevels();
    }

    fn drawRulesShell(self: *AppState) void {
        const panel_w = @min(620, @max(340, sapp.widthf() - 56));
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(panel_w, 500), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Rules##game-shell", null, flags);
        defer c.igEnd();

        c.igTextUnformatted("How To Play", null);
        c.igSeparator();

        if (c.igButton("Rules##rules-tab", uiV2((panel_w - 34) * 0.5, 30))) self.rules_show_entities = false;
        c.igSameLine(0, 8);
        if (c.igButton("Entities##rules-tab", uiV2((panel_w - 34) * 0.5, 30))) self.rules_show_entities = true;
        c.igSeparator();

        c.igPushTextWrapPos(0);
        defer c.igPopTextWrapPos();
        if (self.rules_show_entities) {
            self.drawEntityRules();
        } else {
            self.drawGameplayRules();
        }

        c.igSeparator();
        if (c.igButton("Back", uiV2(-1, 30))) self.enterMainMenuShell();
    }

    fn drawGameplayRules(self: *AppState) void {
        _ = self;
        c.igTextUnformatted("Goal", null);
        ruleBullet("Destroy the enemy Imperator. The battle ends immediately when either Imperator falls.");
        ruleBullet("Citadels anchor the battlefield and pull enemy units across the map, but the Imperator is the win condition.");
        c.igSpacing();

        c.igTextUnformatted("Setup", null);
        ruleBullet("Pick a selected level or start a random game from the start menu.");
        ruleBullet("Player 1 places first, then Player 2 places. Erasing an entity refunds that slot.");
        ruleBullet("The setup panel shows placed counts and remaining limits directly on the entity buttons.");
        c.igSpacing();

        c.igTextUnformatted("Battle", null);
        ruleBullet("When the game starts, mobile units advance toward the opposing Imperator, then the citadel if the Imperator cannot be reached.");
        ruleBullet("If mobile enemies meet, they stop moving, fight nearby targets, then continue once the contact is cleared.");
        ruleBullet("Low-health units try to fall back to allied healing pods or citadels, and pressured units briefly retreat.");
        ruleBullet("Units will peel back to protect an Imperator or citadel that is taking sustained damage.");
        ruleBullet("If both Imperators are alive and the battle goes quiet with no movement, the game ends in a draw.");
        ruleBullet("Press Escape during battle to pause, continue, or cancel back to the start menu.");
        c.igSpacing();

        c.igTextUnformatted("Placement Limits", null);
        ruleBullet("Each player gets 1 Citadel, 1 Imperator, 14 total mobile units, 2 Portals, 2 Healing Pods, 4 total combat structures, and 12 Obstacles.");
    }

    fn drawEntityRules(self: *AppState) void {
        _ = self;
        c.igTextUnformatted("Core", null);
        ruleBullet("Citadel: High-health base. Enemy mobile units path toward it, but destroying it does not end the game.");
        ruleBullet("Imperator: Tough commander with long-range damage. If your Imperator dies, you lose.");
        c.igSpacing();

        c.igTextUnformatted("Mobile Units", null);
        ruleBullet("Infantry: Fast, cheap front-line unit with short-range damage.");
        ruleBullet("Captain: Slower and tougher than infantry, with better range and damage.");
        ruleBullet("Artillery: Long-range damage dealer. Slower and more fragile than the captain.");
        c.igSpacing();

        c.igTextUnformatted("Support", null);
        ruleBullet("Portal: Linked portals teleport mobile units that step onto them to the other portal's nearest open exit.");
        ruleBullet("Healing Pod: Repairs nearby friendly entities over time. It is targetable by enemies.");
        c.igSpacing();

        c.igTextUnformatted("Structures And Terrain Control", null);
        ruleBullet("Outpost: Static defensive structure with solid health and medium range.");
        ruleBullet("Defense Grid: Static defensive structure with longer range and strong sustained damage.");
        ruleBullet("Obstacle: Blocks movement and shapes lanes. Obstacles are not combat targets.");
    }

    fn drawCreditsShell(self: *AppState) void {
        const panel_w = @min(620, @max(340, sapp.widthf() - 56));
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(panel_w, 462), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Credits##game-shell", null, flags);
        defer c.igEnd();

        c.igTextUnformatted("Credits", null);
        c.igSeparator();
        c.igPushTextWrapPos(0);
        defer c.igPopTextWrapPos();

        c.igTextUnformatted("Game", null);
        ruleBullet("Imperator's Gambit was created at TOJam 2026: Twenty years, one weekend.");
        c.igSpacing();

        c.igTextUnformatted("Visual Assets", null);
        ruleBullet("Arid Badlands environment art: tiles, floors, structures, rocks, flora, waterways, and props imported from the Arid Badlands pack under notes/Arid Badlands.");
        ruleBullet("Starter unit/object sprites: project-specific sprites in assets/sprites/starter, generated for this prototype.");
        ruleBullet("TOJam logo and goat artwork: TOJam branding assets in assets/tojam.");
        c.igSpacing();

        c.igTextUnformatted("Audio", null);
        ruleBullet("Sound effects: Kenney UI Audio, Sci-fi Sounds, Digital Audio, and Impact Sounds packs, licensed CC0.");
        ruleBullet("Music: Into the Stars by KiluaBoy and Simple BGM Loop by Theforeshadower from OpenGameArt, licensed CC0.");
        ruleBullet("Ambience: Scifi City - Ambient Loop by TinyWorlds from OpenGameArt, licensed CC0.");
        ruleBullet("Additional sci-fi music tracks are user-provided runtime music files in assets/audio/music.");
        c.igSpacing();

        c.igTextUnformatted("Tech", null);
        ruleBullet("Built with Zig, Sokol, Dear ImGui/cimgui, and stb_image.");

        c.igSeparator();
        if (c.igButton("Back", uiV2(-1, 30))) self.enterMainMenuShell();
    }

    fn drawChooseMapShell(self: *AppState) void {
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(@min(660, @max(360, sapp.widthf() - 56)), 430), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Choose Map##game-shell", null, flags);
        defer c.igEnd();

        c.igTextUnformatted("Select Level", null);
        c.igSeparator();
        if (self.map_count == 0) {
            c.igTextUnformatted("No maps found.", null);
        }
        for (self.maps[0..self.map_count], 0..) |*choice, i| {
            var label_buf: [192]u8 = undefined;
            const selected = i == self.selected_map_index;
            const label_z = std.fmt.bufPrintZ(&label_buf, "{s}{s}", .{ if (selected) "* " else "  ", choice.nameSlice() }) catch continue;
            c.igTextUnformatted(label_z.ptr, null);
            c.igSameLine(0, 8);
            var select_buf: [48]u8 = undefined;
            const select_z = std.fmt.bufPrintZ(&select_buf, "Select##map-{d}", .{i}) catch continue;
            if (c.igButton(select_z.ptr, uiV2(78, 0))) {
                self.selected_map_index = i;
                _ = self.loadShellMap(i, false);
                self.enterMainMenuShell();
            }
            c.igSameLine(0, 6);
            var edit_buf: [48]u8 = undefined;
            const edit_z = std.fmt.bufPrintZ(&edit_buf, "Edit##map-{d}", .{i}) catch continue;
            if (c.igButton(edit_z.ptr, uiV2(62, 0))) {
                self.enterMapEditorShell(i);
            }
        }
        c.igSeparator();
        if (c.igButton("Back", uiV2(96, 0))) self.enterMainMenuShell();
    }

    fn drawMapEditorShell(self: *AppState) void {
        c.igSetNextWindowPos(uiV2(170, 56), c.ImGuiCond_Always, uiV2(0, 0));
        c.igSetNextWindowSize(uiV2(@min(520, @max(320, sapp.widthf() - 540)), 74), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.88);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Map Editor##game-shell", null, flags);
        defer c.igEnd();

        var label_buf: [160]u8 = undefined;
        const label_z = std.fmt.bufPrintZ(&label_buf, "Editing: {s}", .{self.editingMapName()}) catch return;
        c.igTextUnformatted(label_z.ptr, null);
        if (c.igButton("Save", uiV2(92, 0))) self.saveShellMap();
        c.igSameLine(0, 8);
        if (c.igButton("Delete", uiV2(92, 0))) self.deleteShellMap();
        c.igSameLine(0, 8);
        if (c.igButton("Exit", uiV2(92, 0))) self.enterMainMenuShell();
    }

    fn drawSetupShell(self: *AppState) void {
        const active_player = self.game.simulation.activeSetupPlayer() orelse 0;
        const counts = self.countEntitiesForPlayer(active_player);
        c.igSetNextWindowPos(uiV2(170, 56), c.ImGuiCond_Always, uiV2(0, 0));
        c.igSetNextWindowSize(uiV2(@min(620, @max(420, sapp.widthf() - 620)), 188), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.90);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Player Setup##game-shell", null, flags);

        c.igPushStyleColor_U32(c.ImGuiCol_Text, playerUiColor(active_player, 255));
        var player_buf: [96]u8 = undefined;
        const player_z = std.fmt.bufPrintZ(&player_buf, "Player {d} Setup", .{active_player + 1}) catch "Player Setup";
        c.igTextUnformatted(player_z.ptr, null);
        c.igPopStyleColor(1);

        c.igSameLine(0, 18);
        const action_label: [:0]const u8 = if (self.game.simulation.phase == .setup_player_one) "Finish Setup" else "Start Game";
        c.igPushStyleColor_U32(c.ImGuiCol_Button, playerUiColor(active_player, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, playerUiColor(active_player, 220));
        if (c.igButton(action_label.ptr, uiV2(136, 0))) self.advanceGameSetupAction();
        c.igPopStyleColor(2);

        c.igSameLine(0, 10);
        const erase_active = self.editor.tool == .erase;
        if (erase_active) {
            c.igPushStyleColor_U32(c.ImGuiCol_Button, uiCol32(190, 82, 62, 255));
            c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, uiCol32(216, 99, 76, 255));
        }
        if (c.igButton("Erase", uiV2(82, 0))) {
            self.editor.brush_radius = 0;
            self.audio.playSfx(.click_confirm);
            if (erase_active) {
                self.editor.tool = .object;
                self.editor.setStatus("Place entities.", .{});
            } else {
                self.editor.tool = .erase;
                self.editor.setStatus("Erase entities to refund their setup slots.", .{});
            }
        }
        if (erase_active) c.igPopStyleColor(2);

        c.igSeparator();
        self.drawCountLine("Citadel", counts.citadel, 1);
        c.igSameLine(0, 14);
        self.drawCountLine("Imperator", counts.imperator, 1);
        self.drawCountLine("Units", counts.mobile(), 14);
        c.igSameLine(0, 14);
        self.drawCountLine("Portals", counts.portal, 2);
        c.igSameLine(0, 14);
        self.drawCountLine("Healing", counts.healing_pod, 2);
        self.drawCountLine("Structures", counts.structures(), 4);
        c.igSameLine(0, 14);
        self.drawCountLine("Obstacles", counts.obstacle, 12);
        var detail_buf: [176]u8 = undefined;
        const detail_z = std.fmt.bufPrintZ(
            &detail_buf,
            "Inf {d}  Cap {d}  Art {d}  Outpost {d}  Defense {d}",
            .{ counts.infantry, counts.captain, counts.artillery, counts.outpost, counts.defense_grid },
        ) catch "Entity details unavailable";
        c.igTextUnformatted(detail_z.ptr, null);
        c.igEnd();

        self.drawSetupEntitiesShell(active_player);
    }

    fn drawSetupEntitiesShell(self: *AppState, active_player: u8) void {
        const panel_w: f32 = @min(500.0, @max(420.0, sapp.widthf() - 48.0));
        c.igSetNextWindowPos(uiV2(@max(12.0, sapp.widthf() - panel_w - 12.0), 56), c.ImGuiCond_Always, uiV2(0, 0));
        c.igSetNextWindowSize(uiV2(panel_w, @min(392.0, @max(348.0, sapp.heightf() - 84.0))), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.90);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);

        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoTitleBar;
        _ = c.igBegin("##entities-game-shell", null, flags);
        defer c.igEnd();

        c.igPushStyleColor_U32(c.ImGuiCol_Text, playerUiColor(active_player, 255));
        var title_buf: [64]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(&title_buf, "Entities - Player {d}", .{active_player + 1}) catch return;
        c.igTextUnformatted(title_z.ptr, null);
        c.igPopStyleColor(1);
        c.igSeparator();

        for (tools.ObjectPalette) |kind| {
            self.drawSetupEntityRow(kind);
        }

        c.igSeparator();
        self.drawInspectorStateSummary(active_player);
    }

    fn drawBattleShell(self: *AppState) void {
        if (self.game_paused and self.game.simulation.phase == .playing) {
            self.drawPauseShell();
            return;
        }
        if (self.game.simulation.phase != .game_over) return;
        const winner = self.game.simulation.winner;
        var reason_buf: [192]u8 = undefined;
        const reason_z = self.gameOverReasonZ(&reason_buf);

        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(@min(460.0, @max(320.0, sapp.widthf() - 48.0)), 190), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.95);
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, gameOverPanelColor(winner, 232));
        c.igPushStyleColor_U32(c.ImGuiCol_Border, gameOverAccentColor(winner, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_Text, gameOverAccentColor(winner, 255));
        defer c.igPopStyleColor(3);
        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoTitleBar;
        _ = c.igBegin("##game-over-shell", null, flags);
        defer c.igEnd();
        c.igTextUnformatted("Game Over", null);
        c.igSeparator();
        c.igTextUnformatted(reason_z.ptr, null);
        c.igSpacing();
        c.igPushStyleColor_U32(c.ImGuiCol_Button, gameOverAccentColor(winner, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, gameOverAccentColor(winner, 220));
        c.igPushStyleColor_U32(c.ImGuiCol_Text, uiCol32(245, 248, 242, 255));
        if (!self.replay_available) c.igBeginDisabled(true);
        if (c.igButton("Watch Replay", uiV2(-1, 30))) self.enterReplayShell();
        if (!self.replay_available) c.igEndDisabled();
        if (c.igButton("Back To Menu", uiV2(-1, 30))) self.cancelGameToMenu();
        c.igPopStyleColor(3);
    }

    fn drawReplayShell(self: *AppState) void {
        const duration = self.replayDuration();
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, 24), c.ImGuiCond_Always, uiV2(0.5, 0));
        c.igSetNextWindowSize(uiV2(@min(560.0, @max(340.0, sapp.widthf() - 48.0)), 132), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.92);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);
        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Replay##game-shell", null, flags);
        defer c.igEnd();

        var title_buf: [160]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(
            &title_buf,
            "Replay  {d}/{d} frames",
            .{ self.replay_frame_index + 1, @max(@as(usize, 1), self.replay_frames.items.len) },
        ) catch "Replay";
        c.igTextUnformatted(title_z.ptr, null);

        var time_buf: [64]u8 = undefined;
        const time_z = std.fmt.bufPrintZ(&time_buf, "{d:.1}s / {d:.1}s", .{ self.replay_playhead, duration }) catch "";
        var playhead = self.replay_playhead;
        c.igSetNextItemWidth(-1);
        if (c.igSliderFloat("##replay-time", &playhead, 0, @max(0.01, duration), time_z.ptr, 0)) {
            self.seekReplay(playhead);
        }

        const play_label: [:0]const u8 = if (self.replay_playing) "Pause" else "Play";
        if (c.igButton(play_label.ptr, uiV2(92, 28))) self.toggleReplayPlayback();
        c.igSameLine(0, 8);
        if (c.igButton("Restart", uiV2(92, 28))) self.restartReplay();
        c.igSameLine(0, 8);
        if (c.igButton("Back To Result", uiV2(134, 28))) self.exitReplayToResult();
        c.igSameLine(0, 8);
        if (c.igButton("Menu", uiV2(92, 28))) self.cancelGameToMenu();
    }

    fn drawPauseShell(self: *AppState) void {
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(@min(360, @max(280, sapp.widthf() - 48)), 156), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        self.pushShellStyle();
        defer c.igPopStyleColor(3);
        const flags = c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Paused##game-shell", null, flags);
        defer c.igEnd();

        c.igTextUnformatted("Paused", null);
        c.igSeparator();
        if (c.igButton("Continue", uiV2(-1, 30))) self.resumeBattle();
        if (c.igButton("Cancel Game", uiV2(-1, 30))) self.cancelGameToMenu();
    }

    fn drawGameOverToast(self: *AppState) void {
        if (!self.game_over_toast.active) return;
        if (self.game_shell_screen == .battle and self.game.simulation.phase == .game_over) return;
        var text_buf: [192]u8 = undefined;
        const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{self.game_over_toast.text()}) catch return;

        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, 24), c.ImGuiCond_Always, uiV2(0.5, 0));
        c.igSetNextWindowSize(uiV2(@min(460, @max(280, sapp.widthf() - 48)), 64), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, uiCol32(13, 16, 15, 238));
        c.igPushStyleColor_U32(c.ImGuiCol_Border, playerUiColor(self.game_over_toast.winner, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_Text, playerUiColor(self.game_over_toast.winner, 255));
        defer c.igPopStyleColor(3);
        const flags = c.ImGuiWindowFlags_NoDecoration |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoNav |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Winner Toast##game-shell", null, flags);
        defer c.igEnd();
        c.igTextUnformatted(text_z.ptr, null);
    }

    fn drawCountLine(self: *AppState, label: []const u8, placed: usize, limit: usize) void {
        _ = self;
        var buf: [80]u8 = undefined;
        const remaining = if (placed >= limit) @as(usize, 0) else limit - placed;
        const z = std.fmt.bufPrintZ(&buf, "{s}: {d}/{d} ({d})", .{ label, placed, limit, remaining }) catch return;
        c.igTextUnformatted(z.ptr, null);
    }

    fn drawSetupEntityRow(self: *AppState, kind: map_mod.ObjectKind) void {
        const summary = self.objectPlacementSummary(kind);
        var label_buf: [96]u8 = undefined;
        const label_z = std.fmt.bufPrintZ(
            &label_buf,
            "{s} {d}/{d} ({d})",
            .{ tools.objectKindName(kind), summary.placed, summary.limit, summary.remaining },
        ) catch return;
        var stats_buf: [96]u8 = undefined;
        const stats_z = entityStatsZ(kind, &stats_buf);

        const selected = self.editor.tool == .object and self.editor.object_kind == kind;
        if (selected) {
            c.igPushStyleColor_U32(c.ImGuiCol_Button, playerUiColor(self.editor.current_player, 255));
            c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, playerUiColor(self.editor.current_player, 220));
        } else if (summary.full) {
            c.igPushStyleColor_U32(c.ImGuiCol_Button, uiCol32(54, 58, 58, 255));
            c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, uiCol32(54, 58, 58, 255));
        }
        defer {
            if (selected or summary.full) c.igPopStyleColor(2);
        }

        if (summary.full) c.igBeginDisabled(true);
        const clicked = c.igButton(label_z.ptr, uiV2(180, 23));
        if (summary.full) c.igEndDisabled();
        if (clicked) {
            self.editor.tool = .object;
            self.editor.object_kind = kind;
            self.editor.brush_asset_id = self.assetForObjectKind(kind);
            self.audio.playSfx(.click_confirm);
            self.editor.setStatus("Place {s}.", .{tools.objectKindName(kind)});
        }
        c.igSameLine(0, 8);
        c.igTextUnformatted(stats_z.ptr, null);
    }

    fn drawInspectorStateSummary(self: *AppState, active_player: u8) void {
        var buf: [192]u8 = undefined;
        const active = self.activeObjectCount();
        const phase = if (self.game.simulation.phase == .setup_player_one) "P1 Setup" else "P2 Setup";
        const z = std.fmt.bufPrintZ(
            &buf,
            "{s}  Player {d}  Objects {d}/{d}",
            .{ phase, active_player + 1, active, self.game.map.object_count },
        ) catch return;
        c.igTextUnformatted(z.ptr, null);
        c.igPushTextWrapPos(0);
        c.igTextWrapped("%s", &self.editor.status);
        c.igPopTextWrapPos();
    }

    fn activeObjectCount(self: *const AppState) usize {
        var count: usize = 0;
        for (self.game.map.objects[0..self.game.map.object_count]) |object| {
            if (object.active) count += 1;
        }
        return count;
    }

    fn gameOverReasonZ(self: *const AppState, buf: []u8) [:0]const u8 {
        if (self.game.simulation.winner) |winner| {
            const loser = if (winner == 0) @as(u8, 1) else @as(u8, 0);
            return std.fmt.bufPrintZ(
                buf,
                "Player {d} wins because Player {d}'s Imperator was destroyed.",
                .{ winner + 1, loser + 1 },
            ) catch "Battle finished.";
        }
        var p0_lost = true;
        var p1_lost = true;
        for (self.game.map.objects[0..self.game.map.object_count]) |object| {
            if (object.kind != .imperator) continue;
            if (object.team == 0) p0_lost = !object.active;
            if (object.team == 1) p1_lost = !object.active;
        }
        if (p0_lost and p1_lost) {
            return std.fmt.bufPrintZ(buf, "Stalemate: both Imperators were destroyed.", .{}) catch "Stalemate.";
        }
        if (self.game.simulation.outcome == .draw) {
            return std.fmt.bufPrintZ(buf, "Stalemate. Both Imperators survived, but neither army could keep moving.", .{}) catch "Stalemate.";
        }
        return std.fmt.bufPrintZ(buf, "Battle finished.", .{}) catch "Battle finished.";
    }

    fn pushShellStyle(self: *AppState) void {
        _ = self;
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, uiCol32(13, 16, 15, 232));
        c.igPushStyleColor_U32(c.ImGuiCol_Border, uiCol32(70, 79, 70, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_Button, uiCol32(38, 78, 122, 255));
    }

    fn battlePaused(self: *const AppState) bool {
        return self.game_shell_screen == .battle and self.game_paused and self.game.simulation.phase == .playing;
    }

    fn handleEscapeKey(self: *AppState) void {
        if (self.game_shell_screen == .replay) {
            self.exitReplayToResult();
            return;
        }
        if (self.game_shell_screen != .battle) return;
        if (self.game.simulation.phase == .game_over) {
            self.cancelGameToMenu();
            return;
        }
        if (self.game_paused) {
            self.resumeBattle();
        } else {
            self.pauseBattle();
        }
    }

    fn pauseBattle(self: *AppState) void {
        if (self.game_shell_screen != .battle or self.game.simulation.phase != .playing) return;
        self.game_paused = true;
        self.audio.playSfx(.panel_open);
        self.editor.setStatus("Paused.", .{});
    }

    fn resumeBattle(self: *AppState) void {
        if (self.game_shell_screen != .battle) return;
        self.game_paused = false;
        self.audio.playSfx(.panel_close);
        self.editor.setStatus("Battle resumed.", .{});
    }

    fn cancelGameToMenu(self: *AppState) void {
        self.game_paused = false;
        self.painting = false;
        self.clearReplay();
        self.game.simulation.resetSetup();
        self.last_sim_phase = self.game.simulation.phase;
        _ = self.loadSelectedMapForShell(false);
        self.enterMainMenuShell();
        self.editor.setStatus("Game cancelled.", .{});
    }

    fn clearReplay(self: *AppState) void {
        self.replay_frames.clearRetainingCapacity();
        self.replay_shots.clearRetainingCapacity();
        self.replay_recording = false;
        self.replay_available = false;
        self.replay_elapsed = 0;
        self.replay_capture_accum = 0;
        self.replay_playing = false;
        self.replay_playhead = 0;
        self.replay_frame_index = 0;
        self.replay_shot_cursor = 0;
    }

    fn startReplayRecording(self: *AppState) void {
        self.clearReplay();
        self.replay_recording = true;
        self.replay_available = true;
        self.captureReplayFrame(0) catch |err| {
            self.replay_recording = false;
            self.replay_available = false;
            self.editor.setStatus("Replay recording failed: {s}", .{@errorName(err)});
        };
    }

    fn updateReplayRecording(self: *AppState, dt: f32) void {
        if (!self.replay_recording) return;
        self.replay_elapsed += dt;
        self.recordReplayShots();
        if (self.game.simulation.phase == .playing) {
            self.replay_capture_accum += dt;
            if (self.replay_capture_accum >= ReplayFrameSeconds) {
                self.replay_capture_accum = 0;
                self.captureReplayFrame(self.replay_elapsed) catch |err| {
                    self.replay_recording = false;
                    self.editor.setStatus("Replay recording stopped: {s}", .{@errorName(err)});
                };
            }
            return;
        }
        if (self.game.simulation.phase == .game_over) {
            self.captureReplayFrame(self.replay_elapsed) catch {};
            self.replay_recording = false;
            self.replay_available = self.replay_frames.items.len > 1;
        }
    }

    fn captureReplayFrame(self: *AppState, time: f32) !void {
        if (self.replay_frames.items.len >= MaxReplayFrames) {
            if (self.replay_frames.items.len > 0) self.replay_frames.items[self.replay_frames.items.len - 1] = self.makeReplayFrame(time);
            return;
        }
        try self.replay_frames.append(self.allocator, self.makeReplayFrame(time));
    }

    fn makeReplayFrame(self: *const AppState, time: f32) ReplayFrame {
        var replay_frame: ReplayFrame = .{ .time = time, .object_count = self.game.map.object_count };
        for (self.game.map.objects[0..self.game.map.object_count], 0..) |object, i| {
            replay_frame.objects[i] = object;
        }
        return replay_frame;
    }

    fn recordReplayShots(self: *AppState) void {
        if (self.game.simulation.shot_event_count == 0) return;
        const count = @min(self.game.simulation.shot_event_count, self.game.simulation.shot_events.len);
        for (self.game.simulation.shot_events[0..count]) |event| {
            if (self.replay_shots.items.len >= MaxReplayShots) return;
            self.replay_shots.append(self.allocator, .{ .time = self.replay_elapsed, .event = event }) catch return;
        }
    }

    fn enterReplayShell(self: *AppState) void {
        if (!self.replay_available or self.replay_frames.items.len == 0) return;
        self.game_shell_screen = .replay;
        self.game_paused = false;
        self.editor.enabled = false;
        self.replay_playing = true;
        self.seekReplay(0);
        self.audio.playSfx(.panel_open);
        self.editor.setStatus("Replay started.", .{});
    }

    fn exitReplayToResult(self: *AppState) void {
        self.replay_playing = false;
        self.clearLaserFx();
        self.game_shell_screen = .battle;
        self.audio.playSfx(.panel_close);
        self.editor.setStatus("Replay closed.", .{});
    }

    fn toggleReplayPlayback(self: *AppState) void {
        if (!self.replay_available) return;
        if (!self.replay_playing and self.replay_playhead >= self.replayDuration()) self.seekReplay(0);
        self.replay_playing = !self.replay_playing;
        self.audio.playSfx(.click_confirm);
    }

    fn restartReplay(self: *AppState) void {
        self.seekReplay(0);
        self.replay_playing = true;
        self.audio.playSfx(.click_confirm);
    }

    fn seekReplay(self: *AppState, time: f32) void {
        const duration = self.replayDuration();
        self.replay_playhead = std.math.clamp(time, 0, duration);
        self.replay_frame_index = self.replayFrameIndexAt(self.replay_playhead);
        self.replay_shot_cursor = self.replayShotIndexAt(self.replay_playhead);
        self.clearLaserFx();
    }

    fn updateReplayPlayback(self: *AppState, dt: f32) void {
        if (self.game_shell_screen != .replay or !self.replay_available or !self.replay_playing) return;
        const duration = self.replayDuration();
        const previous = self.replay_playhead;
        self.replay_playhead = @min(duration, self.replay_playhead + dt);
        self.replay_frame_index = self.replayFrameIndexAt(self.replay_playhead);
        self.emitReplayShots(previous, self.replay_playhead);
        if (self.replay_playhead >= duration) self.replay_playing = false;
    }

    fn emitReplayShots(self: *AppState, previous: f32, current: f32) void {
        while (self.replay_shot_cursor < self.replay_shots.items.len) : (self.replay_shot_cursor += 1) {
            const shot = self.replay_shots.items[self.replay_shot_cursor];
            if (shot.time <= previous) continue;
            if (shot.time > current) break;
            self.spawnLaserShot(shot.event);
        }
    }

    fn replayDuration(self: *const AppState) f32 {
        if (self.replay_frames.items.len == 0) return 0;
        return self.replay_frames.items[self.replay_frames.items.len - 1].time;
    }

    fn replayFrameIndexAt(self: *const AppState, time: f32) usize {
        if (self.replay_frames.items.len == 0) return 0;
        var index: usize = 0;
        while (index + 1 < self.replay_frames.items.len and self.replay_frames.items[index + 1].time <= time) : (index += 1) {}
        return index;
    }

    fn replayShotIndexAt(self: *const AppState, time: f32) usize {
        var index: usize = 0;
        while (index < self.replay_shots.items.len and self.replay_shots.items[index].time <= time) : (index += 1) {}
        return index;
    }

    fn activeReplayFrame(self: *const AppState) ?*const ReplayFrame {
        if (self.game_shell_screen != .replay or self.replay_frames.items.len == 0) return null;
        return &self.replay_frames.items[@min(self.replay_frame_index, self.replay_frames.items.len - 1)];
    }

    fn enterChooseMapShell(self: *AppState) void {
        self.refreshAvailableMaps();
        self.editor.enabled = false;
        self.game_paused = false;
        self.game_shell_screen = .choose_map;
        _ = self.loadShellMap(self.selected_map_index, false);
        self.audio.playSfx(.panel_open);
    }

    fn enterSoundShell(self: *AppState) void {
        self.editor.enabled = false;
        self.game_paused = false;
        self.game_shell_screen = .sound;
        self.audio.playSfx(.panel_open);
    }

    fn enterRulesShell(self: *AppState) void {
        self.editor.enabled = false;
        self.game_paused = false;
        self.game_shell_screen = .rules;
        self.audio.playSfx(.panel_open);
    }

    fn enterCreditsShell(self: *AppState) void {
        self.editor.enabled = false;
        self.game_paused = false;
        self.game_shell_screen = .credits;
        self.audio.playSfx(.panel_open);
    }

    fn enterMapEditorShell(self: *AppState, index: usize) void {
        if (!self.loadShellMap(index, true)) return;
        self.editing_map_index = index;
        self.game_shell_screen = .map_editor;
        self.game_paused = false;
        self.editor.enabled = true;
        self.editor.tool = .terrain;
        self.game.simulation.resetSetup();
        self.syncEditorPlayerWithSetup();
        self.audio.playSfx(.panel_open);
    }

    fn enterMainMenuShell(self: *AppState) void {
        self.editor.enabled = false;
        self.painting = false;
        self.game_shell_screen = .menu;
        self.game_paused = false;
        self.clearLaserFx();
        self.audio.playSfx(.panel_close);
    }

    fn startRandomGameSetup(self: *AppState) void {
        self.refreshAvailableMaps();
        if (self.map_count > 0) self.selected_map_index = self.randomMapIndex();
        const map_name = self.selectedMapName();
        self.startCurrentMapSetup(map_name, true);
    }

    fn startSelectedGameSetup(self: *AppState) void {
        self.refreshAvailableMaps();
        const map_name = self.selectedMapName();
        self.startCurrentMapSetup(map_name, false);
    }

    fn startCurrentMapSetup(self: *AppState, map_name: []const u8, random: bool) void {
        if (!self.loadSelectedMapForShell(true)) return;
        self.game.simulation.resetSetup();
        self.last_sim_phase = self.game.simulation.phase;
        self.game_shell_screen = .setup;
        self.game_paused = false;
        self.editor.enabled = true;
        self.editor.tool = .object;
        self.editor.show_preview = true;
        self.editor.current_player = 0;
        self.syncEditorPlayerWithSetup();
        self.clearLaserFx();
        self.clearReplay();
        self.audio.playSfx(.click_confirm);
        if (random) {
            self.editor.setStatus("Random map: {s}. Player 1 setup. Place entities, then choose Finish Setup.", .{map_name});
        } else {
            self.editor.setStatus("Selected map: {s}. Player 1 setup. Place entities, then choose Finish Setup.", .{map_name});
        }
    }

    fn randomMapIndex(self: *AppState) usize {
        if (self.map_count <= 1) return 0;
        const value = self.nextMapRandom();
        return @intCast(value % @as(u32, @intCast(self.map_count)));
    }

    fn nextMapRandom(self: *AppState) u32 {
        const ticks = stime.now();
        self.map_rng ^= @as(u32, @truncate(ticks));
        self.map_rng ^= @as(u32, @truncate(ticks >> 32));
        self.map_rng = self.map_rng *% 1664525 +% 1013904223;
        if (self.map_rng == 0) self.map_rng = 0x9e3779b9;
        return self.map_rng;
    }

    fn advanceGameSetupAction(self: *AppState) void {
        switch (self.game.simulation.phase) {
            .setup_player_one => {
                self.game.simulation.phase = .setup_player_two;
                self.syncEditorPlayerWithSetup();
                self.audio.playSfx(.click_confirm);
                self.editor.setStatus("Player 2 setup. Place entities, then start the game.", .{});
            },
            .setup_player_two => {
                self.game.simulation.startPlaying();
                self.last_sim_phase = self.game.simulation.phase;
                self.game_shell_screen = .battle;
                self.game_paused = false;
                self.editor.enabled = false;
                self.clearLaserFx();
                self.startReplayRecording();
                self.audio.playSfx(.click_confirm);
                self.editor.setStatus("Battle started.", .{});
            },
            else => {},
        }
    }

    fn refreshAvailableMaps(self: *AppState) void {
        self.map_count = 0;
        self.addMapChoice("Default Map", "", true, true);
        self.addStaticEditableMaps();
        if (comptime !platform.is_web) self.scanNativeMaps();
        if (self.selected_map_index >= self.map_count) self.selected_map_index = 0;
        if (self.editing_map_index >= self.map_count) self.editing_map_index = self.selected_map_index;
    }

    fn addStaticEditableMaps(self: *AppState) void {
        for (StaticEditableMaps) |entry| {
            var path_buf: [256]u8 = undefined;
            const path = self.assetRelativeMapPath(entry.rel_path, &path_buf);
            self.addMapChoice(entry.name, path, false, false);
        }
    }

    fn scanNativeMaps(self: *AppState) void {
        var maps_root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const maps_root = std.fmt.bufPrint(&maps_root_buf, "{s}/maps", .{platform.assetRoot()}) catch return;
        var dir = if (std.fs.path.isAbsolute(maps_root))
            std.fs.openDirAbsolute(maps_root, .{ .iterate = true }) catch return
        else
            std.fs.cwd().openDir(maps_root, .{ .iterate = true }) catch return;
        defer dir.close();
        var walker = dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (true) {
            const maybe_entry = walker.next() catch break;
            const entry = maybe_entry orelse break;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) continue;
            if (std.mem.eql(u8, entry.path, "default/map.json")) continue;
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ maps_root, entry.path }) catch continue;
            const name = std.fs.path.basename(entry.path);
            self.addMapChoice(name, path, false, false);
        }
    }

    fn addMapChoice(self: *AppState, name: []const u8, path: []const u8, protected: bool, is_builtin: bool) void {
        if (self.map_count >= self.maps.len) return;
        for (self.maps[0..self.map_count]) |choice| {
            if (std.mem.eql(u8, choice.pathSlice(), path)) return;
        }
        self.maps[self.map_count].set(name, path, protected, is_builtin);
        self.map_count += 1;
    }

    fn assetRelativeMapPath(self: *const AppState, rel_path: []const u8, buffer: []u8) []const u8 {
        _ = self;
        if (comptime platform.is_web) return std.fmt.bufPrint(buffer, "assets/{s}", .{rel_path}) catch rel_path;
        const root = platform.assetRoot();
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ root, rel_path }) catch rel_path;
    }

    fn loadSelectedMapForShell(self: *AppState, announce: bool) bool {
        return self.loadShellMap(self.selected_map_index, announce);
    }

    fn loadShellMap(self: *AppState, index: usize, announce: bool) bool {
        if (index >= self.map_count) return false;
        const choice = &self.maps[index];
        if (choice.builtin) {
            self.game.map = map_mod.GameMap.initDefault();
            self.afterShellMapLoaded(announce, choice.nameSlice());
            return true;
        }
        const path = choice.pathSlice();
        const loaded = map_io.load(self.allocator, path) catch |err| {
            self.editor.setStatus("Map load failed: {s}", .{@errorName(err)});
            return false;
        };
        self.game.map = loaded;
        self.afterShellMapLoaded(announce, choice.nameSlice());
        return true;
    }

    fn afterShellMapLoaded(self: *AppState, announce: bool, name: []const u8) void {
        self.assignObjectAssets(true);
        self.game.rebuildPathing() catch {};
        self.pathing_dirty = false;
        self.clearLaserFx();
        if (announce) self.editor.setStatus("Loaded map: {s}", .{name});
    }

    fn saveShellMap(self: *AppState) void {
        if (self.editing_map_index >= self.map_count) return;
        const choice = &self.maps[self.editing_map_index];
        if (choice.builtin) {
            self.editor.setStatus("Default Map is built in. Edit a generated map to save changes.", .{});
            self.audio.playSfx(.invalid_action);
            return;
        }
        const path = choice.pathSlice();
        map_io.save(path, &self.game.map) catch |err| {
            self.editor.setStatus("Save failed: {s}", .{@errorName(err)});
            return;
        };
        self.editor.setStatus("Saved map: {s}", .{choice.nameSlice()});
    }

    fn deleteShellMap(self: *AppState) void {
        if (self.editing_map_index >= self.map_count) return;
        if (self.maps[self.editing_map_index].protected) {
            self.editor.setStatus("The default map cannot be deleted.", .{});
            self.audio.playSfx(.invalid_action);
            return;
        }
        const path = self.maps[self.editing_map_index].pathSlice();
        if (std.fs.path.isAbsolute(path)) {
            std.fs.deleteFileAbsolute(path) catch |err| {
                self.editor.setStatus("Delete failed: {s}", .{@errorName(err)});
                return;
            };
        } else {
            std.fs.cwd().deleteFile(path) catch |err| {
                self.editor.setStatus("Delete failed: {s}", .{@errorName(err)});
                return;
            };
        }
        var i = self.editing_map_index;
        while (i + 1 < self.map_count) : (i += 1) {
            self.maps[i] = self.maps[i + 1];
        }
        if (self.map_count > 0) self.map_count -= 1;
        self.selected_map_index = 0;
        self.editing_map_index = 0;
        _ = self.loadSelectedMapForShell(true);
        self.enterMainMenuShell();
    }

    fn selectedMapName(self: *const AppState) []const u8 {
        if (self.map_count == 0 or self.selected_map_index >= self.map_count) return "Default Map";
        return self.maps[self.selected_map_index].nameSlice();
    }

    fn editingMapName(self: *const AppState) []const u8 {
        if (self.map_count == 0 or self.editing_map_index >= self.map_count) return "Default Map";
        return self.maps[self.editing_map_index].nameSlice();
    }

    pub fn objectPlacementSummary(self: *const AppState, kind: map_mod.ObjectKind) ObjectPlacementSummary {
        if (!self.placementLimitsVisible()) return .{};
        const player = self.game.simulation.placementPlayer(self.editor.current_player);
        const counts = self.countEntitiesForPlayer(player);
        var placed: usize = 0;
        var limit: usize = 0;
        switch (kind) {
            .citadel => {
                placed = counts.citadel;
                limit = 1;
            },
            .imperator => {
                placed = counts.imperator;
                limit = 1;
            },
            .infantry, .captain, .artillery => {
                placed = counts.mobile();
                limit = 14;
            },
            .portal => {
                placed = counts.portal;
                limit = 2;
            },
            .healing_pod => {
                placed = counts.healing_pod;
                limit = 2;
            },
            .outpost, .defense_grid => {
                placed = counts.structures();
                limit = 4;
            },
            .obstacle => {
                placed = counts.obstacle;
                limit = 12;
            },
        }
        const remaining = if (placed >= limit) @as(usize, 0) else limit - placed;
        return .{
            .limited = true,
            .placed = placed,
            .limit = limit,
            .remaining = remaining,
            .full = remaining == 0,
        };
    }

    fn placementLimitsVisible(self: *const AppState) bool {
        return (self.game_shell_screen == .setup or self.game_shell_screen == .disabled) and self.game.simulation.activeSetupPlayer() != null;
    }

    fn countEntitiesForPlayer(self: *const AppState, player: u8) EntityCounts {
        var counts: EntityCounts = .{};
        for (self.game.map.objects[0..self.game.map.object_count]) |object| {
            if (!object.active or object.team != player) continue;
            switch (object.kind) {
                .citadel => counts.citadel += 1,
                .imperator => counts.imperator += 1,
                .infantry => counts.infantry += 1,
                .captain => counts.captain += 1,
                .artillery => counts.artillery += 1,
                .portal => counts.portal += 1,
                .healing_pod => counts.healing_pod += 1,
                .outpost => counts.outpost += 1,
                .defense_grid => counts.defense_grid += 1,
                .obstacle => counts.obstacle += 1,
            }
        }
        return counts;
    }

    fn showGameOverToast(self: *AppState) void {
        const winner = self.game.simulation.winner orelse return;
        const loser = if (winner == 0) @as(u8, 1) else @as(u8, 0);
        const message = std.fmt.bufPrint(
            self.game_over_toast.message[0..],
            "Player {d} wins: Player {d}'s Imperator was destroyed.",
            .{ winner + 1, loser + 1 },
        ) catch return;
        self.game_over_toast.message_len = message.len;
        self.game_over_toast.winner = winner;
        self.game_over_toast.timer = 6.0;
        self.game_over_toast.active = true;
        self.audio.playSfx(.click_confirm);
    }

    fn ready(self: *const AppState) bool {
        return self.loading.phase == .complete;
    }

    fn prepareScreenSgl(self: *AppState) void {
        _ = self;
        sgl.defaults();
        sgl.matrixModeProjection();
        sgl.loadIdentity();
        sgl.ortho(0, sapp.widthf(), sapp.heightf(), 0, -1, 1);
        sgl.matrixModeModelview();
        sgl.loadIdentity();
    }

    fn initLaserFxPipeline(self: *AppState) void {
        self.laser_fx_shader = sg.makeShader(laserFxShaderDesc());

        var pipeline_desc: sg.PipelineDesc = .{};
        pipeline_desc.shader = self.laser_fx_shader;
        pipeline_desc.layout.buffers[0].stride = @sizeOf(LaserFxVertex);
        pipeline_desc.layout.attrs[0].format = .FLOAT2;
        pipeline_desc.layout.attrs[0].offset = @offsetOf(LaserFxVertex, "position");
        pipeline_desc.layout.attrs[1].format = .FLOAT4;
        pipeline_desc.layout.attrs[1].offset = @offsetOf(LaserFxVertex, "color");
        pipeline_desc.color_count = 1;
        pipeline_desc.colors[0].blend.enabled = true;
        pipeline_desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA;
        pipeline_desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA;
        pipeline_desc.colors[0].blend.src_factor_alpha = .ONE;
        pipeline_desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA;
        pipeline_desc.primitive_type = .TRIANGLES;
        pipeline_desc.label = "laser-fx-pipeline";
        self.laser_fx_pipeline = sg.makePipeline(pipeline_desc);

        self.laser_fx_vertex_buffer = sg.makeBuffer(.{
            .usage = .{
                .vertex_buffer = true,
                .stream_update = true,
            },
            .size = @sizeOf(LaserFxVertex) * MaxLaserFxVertices,
            .label = "laser-fx-vertices",
        });
    }

    fn initShaderTilePipeline(self: *AppState) void {
        self.shader_tile_shader = sg.makeShader(shaderTileShaderDesc());

        var pipeline_desc: sg.PipelineDesc = .{};
        pipeline_desc.shader = self.shader_tile_shader;
        pipeline_desc.layout.buffers[0].stride = @sizeOf(ShaderTileVertex);
        pipeline_desc.layout.attrs[0].format = .FLOAT2;
        pipeline_desc.layout.attrs[0].offset = @offsetOf(ShaderTileVertex, "position");
        pipeline_desc.layout.attrs[1].format = .FLOAT2;
        pipeline_desc.layout.attrs[1].offset = @offsetOf(ShaderTileVertex, "uv");
        pipeline_desc.layout.attrs[2].format = .FLOAT;
        pipeline_desc.layout.attrs[2].offset = @offsetOf(ShaderTileVertex, "kind");
        pipeline_desc.layout.attrs[3].format = .FLOAT;
        pipeline_desc.layout.attrs[3].offset = @offsetOf(ShaderTileVertex, "seed");
        pipeline_desc.layout.attrs[4].format = .FLOAT;
        pipeline_desc.layout.attrs[4].offset = @offsetOf(ShaderTileVertex, "time");
        pipeline_desc.color_count = 1;
        pipeline_desc.colors[0].blend.enabled = true;
        pipeline_desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA;
        pipeline_desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA;
        pipeline_desc.colors[0].blend.src_factor_alpha = .ONE;
        pipeline_desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA;
        pipeline_desc.primitive_type = .TRIANGLES;
        pipeline_desc.label = "shader-tile-pipeline";
        self.shader_tile_pipeline = sg.makePipeline(pipeline_desc);

        self.shader_tile_vertex_buffer = sg.makeBuffer(.{
            .usage = .{
                .vertex_buffer = true,
                .stream_update = true,
            },
            .size = @sizeOf(ShaderTileVertex) * MaxShaderTileVertices,
            .label = "shader-tile-vertices",
        });
    }

    fn configureStartupMode(self: *AppState) void {
        switch (appMode()) {
            .integrated => {
                self.allow_editor = true;
                self.editor.enabled = true;
                self.game.simulation.phase = .setup_player_one;
            },
            .editor => {
                self.allow_editor = true;
                self.editor.enabled = true;
                self.game.simulation.phase = .setup_player_one;
            },
            .game => {
                self.allow_editor = true;
                self.editor.enabled = false;
                self.game.simulation.resetSetup();
                self.game_shell_screen = .menu;
            },
        }
        self.last_sim_phase = self.game.simulation.phase;
    }

    fn syncEditorPlayerWithSetup(self: *AppState) void {
        if (self.game_shell_screen != .disabled and self.game_shell_screen != .setup) return;
        if (self.game.simulation.activeSetupPlayer()) |player| {
            self.editor.current_player = player;
        }
    }

    fn updateHoverAt(self: *AppState, screen: Vec2) void {
        if (!self.editor.enabled) {
            self.editor.hover_cell_x = -1;
            self.editor.hover_cell_y = -1;
            return;
        }
        const world = self.screenToWorld(screen);
        const x: i32 = @intFromFloat(@floor(world.x));
        const y: i32 = @intFromFloat(@floor(world.y));
        if (!self.game.map.inBounds(x, y)) {
            self.editor.hover_cell_x = -1;
            self.editor.hover_cell_y = -1;
            return;
        }
        self.editor.hover_cell_x = x;
        self.editor.hover_cell_y = y;
    }

    fn markPathingDirty(self: *AppState) void {
        self.pathing_dirty = true;
    }

    fn flushPathingRebuild(self: *AppState) void {
        if (!self.pathing_dirty) return;
        self.game.rebuildPathing() catch {};
        self.pathing_dirty = false;
    }

    fn advanceLoading(self: *AppState) void {
        switch (self.loading.phase) {
            .intro => {
                self.loading.progress = 0.08;
                self.loading.phase = .scan_assets;
            },
            .scan_assets => self.scanAssetsForLoading(),
            .load_assets => self.loadAssetBatch(),
            .sprite_defs => {
                self.loading.progress = 0.88;
                self.loadObjectSpriteDefinitions();
                self.loading.phase = .assign_world;
            },
            .assign_world => {
                self.loading.progress = 0.94;
                self.assignStarterAssets();
                self.loadTojamBrandingSprites();
                self.refreshAvailableMaps();
                if (self.game_shell_screen != .disabled) _ = self.loadSelectedMapForShell(false);
                self.game.rebuildPathing() catch {};
                self.pathing_dirty = false;
                self.loading.progress = 1.0;
                self.loading.phase = .complete;
                self.editor.setStatus("Ready. Loaded {d} assets.", .{self.loading.loaded_assets});
            },
            .complete, .failed => {},
        }
    }

    fn scanAssetsForLoading(self: *AppState) void {
        self.editor.setStatus("Scanning assets under {s}", .{platform.assetRoot()});
        self.catalog.scan(platform.assetRoot()) catch |err| {
            self.failLoading(err);
            return;
        };
        self.sprite_count = @min(self.catalog.assets.items.len, self.sprites.len);
        self.loading.asset_index = 0;
        self.loading.loaded_assets = 0;
        self.loading.skipped_assets = 0;
        self.loading.progress = 0.16;
        self.loading.phase = if (self.sprite_count == 0) .sprite_defs else .load_assets;
    }

    fn loadAssetBatch(self: *AppState) void {
        const batch_size: usize = 2;
        var loaded_this_frame: usize = 0;
        while (loaded_this_frame < batch_size and self.loading.asset_index < self.sprite_count) : (loaded_this_frame += 1) {
            const i = self.loading.asset_index;
            self.loading.asset_index += 1;
            var asset = &self.catalog.assets.items[i];
            const image = png_loader.loadRgba(self.allocator, asset.path) catch {
                self.loading.skipped_assets += 1;
                continue;
            };
            defer image.deinit();
            self.sprites[i] = createSprite(image.width, image.height, image.pixels);
            asset.width = @floatFromInt(image.width);
            asset.height = @floatFromInt(image.height);
            self.loading.loaded_assets += 1;
        }

        self.loading.progress = 0.18 + 0.62 * self.assetLoadFraction();
        if (self.loading.asset_index >= self.sprite_count) {
            if (self.catalog.firstOfKind(.terrain)) |id| self.editor.brush_asset_id = id;
            self.editor.setStatus("Loaded {d} assets from {s}", .{ self.loading.loaded_assets, platform.assetRoot() });
            self.loading.phase = .sprite_defs;
        }
    }

    fn assetLoadFraction(self: *const AppState) f32 {
        if (self.sprite_count == 0) return 1.0;
        return @as(f32, @floatFromInt(self.loading.asset_index)) / @as(f32, @floatFromInt(self.sprite_count));
    }

    fn failLoading(self: *AppState, err: anyerror) void {
        const name = @errorName(err);
        const len = @min(name.len, self.loading.error_name.len);
        @memcpy(self.loading.error_name[0..len], name[0..len]);
        self.loading.error_len = len;
        self.loading.phase = .failed;
        self.editor.setStatus("Loading failed: {s}", .{self.loading.errorSlice()});
    }

    fn loadingStage(self: *const AppState) []const u8 {
        return switch (self.loading.phase) {
            .intro => "Starting renderer",
            .scan_assets => "Scanning asset catalog",
            .load_assets => "Loading sprites",
            .sprite_defs => "Loading object sprite definitions",
            .assign_world => "Building starter battlefield",
            .complete => "Ready",
            .failed => "Load failed",
        };
    }

    fn loadingDetail(self: *const AppState, buffer: []u8) []const u8 {
        return switch (self.loading.phase) {
            .intro => std.fmt.bufPrint(buffer, "Preparing native and web render path", .{}) catch "Preparing render path",
            .scan_assets => std.fmt.bufPrint(buffer, "Looking under {s}", .{platform.assetRoot()}) catch "Scanning assets",
            .load_assets => blk: {
                if (self.loading.asset_index < self.sprite_count) {
                    const asset = self.catalog.assets.items[self.loading.asset_index];
                    break :blk std.fmt.bufPrint(
                        buffer,
                        "{d}/{d}  {s}",
                        .{ self.loading.asset_index + 1, self.sprite_count, asset.name },
                    ) catch "Loading sprite";
                }
                break :blk std.fmt.bufPrint(buffer, "{d}/{d} sprites decoded", .{ self.loading.loaded_assets, self.sprite_count }) catch "Sprites decoded";
            },
            .sprite_defs => std.fmt.bufPrint(buffer, "Resolving object kinds to sprite assets", .{}) catch "Resolving object sprites",
            .assign_world => std.fmt.bufPrint(buffer, "Assigning tiles, objects, and pathing", .{}) catch "Assigning starter battlefield",
            .complete => std.fmt.bufPrint(buffer, "Entering battlefield", .{}) catch "Ready",
            .failed => std.fmt.bufPrint(buffer, "{s}", .{self.loading.errorSlice()}) catch "Open logs for details",
        };
    }

    fn drawLoadingBackdrop(self: *AppState) void {
        _ = self;
        const w = sapp.widthf();
        const h = sapp.heightf();
        const center = Vec2{ .x = w * 0.5, .y = h * 0.5 };

        drawRect(.{ .x = 0, .y = 0 }, w, h, .{ 0.055, 0.065, 0.058, 1.0 });
        drawDiamond(.{ .x = center.x - 170, .y = center.y - 92 }, 160, 80, .{ 0.50, 0.42, 0.28, 0.10 });
        drawDiamond(.{ .x = center.x + 170, .y = center.y + 92 }, 180, 90, .{ 0.25, 0.48, 0.58, 0.08 });
        drawDiamond(.{ .x = center.x, .y = center.y + 12 }, 420, 210, .{ 0.02, 0.025, 0.022, 0.34 });
    }

    fn drawLoadingUi(self: *AppState) void {
        var stage_buf: [96]u8 = undefined;
        var detail_buf: [192]u8 = undefined;
        var detail_z_buf: [192]u8 = undefined;
        var percent_buf: [24]u8 = undefined;
        const stage_z = std.fmt.bufPrintZ(&stage_buf, "{s}", .{self.loadingStage()}) catch return;
        const detail = self.loadingDetail(&detail_buf);
        const detail_z = std.fmt.bufPrintZ(&detail_z_buf, "{s}", .{detail}) catch return;
        const pct = @as(i32, @intFromFloat(@round(std.math.clamp(self.loading.progress, 0, 1) * 100)));
        const percent_z = std.fmt.bufPrintZ(&percent_buf, "{d}%", .{pct}) catch return;

        const panel_w = @min(520, @max(320, sapp.widthf() - 48));
        c.igSetNextWindowPos(uiV2(sapp.widthf() * 0.5, sapp.heightf() * 0.5), c.ImGuiCond_Always, uiV2(0.5, 0.5));
        c.igSetNextWindowSize(uiV2(panel_w, 154), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.92);
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, uiCol32(13, 16, 15, 236));
        c.igPushStyleColor_U32(c.ImGuiCol_Border, uiCol32(64, 70, 61, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, uiCol32(8, 10, 9, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_PlotHistogram, if (self.loading.phase == .failed) uiCol32(255, 116, 88, 255) else uiCol32(82, 166, 210, 255));
        defer c.igPopStyleColor(4);

        const flags = c.ImGuiWindowFlags_NoDecoration |
            c.ImGuiWindowFlags_NoMove |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoNav |
            c.ImGuiWindowFlags_NoResize;
        _ = c.igBegin("Loading##startup", null, flags);
        defer c.igEnd();

        c.igTextUnformatted(GameTitle, null);
        c.igSpacing();
        c.igTextUnformatted(stage_z.ptr, null);
        c.igProgressBar(std.math.clamp(self.loading.progress, 0, 1), uiV2(-1, 16), percent_z.ptr);
        c.igTextUnformatted(detail_z.ptr, null);
        if (self.loading.skipped_assets > 0) {
            var skipped_buf: [64]u8 = undefined;
            const skipped_z = std.fmt.bufPrintZ(&skipped_buf, "Skipped {d} sprite(s)", .{self.loading.skipped_assets}) catch return;
            c.igTextUnformatted(skipped_z.ptr, null);
        }
    }

    fn loadAssets(self: *AppState) void {
        self.catalog.scan(platform.assetRoot()) catch |err| {
            self.editor.setStatus("Asset scan failed: {s}", .{@errorName(err)});
            return;
        };
        self.sprite_count = @min(self.catalog.assets.items.len, self.sprites.len);
        for (self.catalog.assets.items[0..self.sprite_count], 0..) |*asset, i| {
            const image = png_loader.loadRgba(self.allocator, asset.path) catch continue;
            defer image.deinit();
            self.sprites[i] = createSprite(image.width, image.height, image.pixels);
            asset.width = @floatFromInt(image.width);
            asset.height = @floatFromInt(image.height);
        }
        if (self.catalog.firstOfKind(.terrain)) |id| self.editor.brush_asset_id = id;
        self.editor.setStatus("Loaded {d} assets from {s}", .{ self.sprite_count, platform.assetRoot() });
    }

    fn loadObjectSpriteDefinitions(self: *AppState) void {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/sprites/object_sprites.json", .{platform.assetRoot()}) catch {
            self.editor.setStatus("Object sprite definition path is too long.", .{});
            return;
        };
        self.object_sprites.loadFromFile(path, &self.catalog) catch |err| {
            self.editor.setStatus("Object sprite definitions skipped: {s}", .{@errorName(err)});
            return;
        };

        var linked: usize = 0;
        for (self.object_sprites.objects.items) |def| {
            if (def.asset_id != null) linked += 1;
        }
        self.editor.setStatus("Loaded {d} object sprite definitions ({d} linked).", .{ self.object_sprites.objects.items.len, linked });
    }

    fn loadTojamBrandingSprites(self: *AppState) void {
        if (!self.tojam_logo_sprite.valid()) {
            self.tojam_logo_sprite = self.loadBrandSprite("tojam/logo.png") catch .{};
        }
        if (!self.tojam_goat_sprite.valid()) {
            self.tojam_goat_sprite = self.loadBrandSprite("tojam/goat.png") catch .{};
        }
    }

    fn loadBrandSprite(self: *AppState, rel_path: []const u8) !Sprite {
        var path_buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ platform.assetRoot(), rel_path });
        const image = try png_loader.loadRgba(self.allocator, path);
        defer image.deinit();
        return createSprite(image.width, image.height, image.pixels);
    }

    fn assignStarterAssets(self: *AppState) void {
        const terrain_count = self.countAssets(.terrain);
        const water_id = self.catalog.firstOfKind(.water) orelse self.catalog.firstOfKind(.terrain) orelse NoAsset;
        const rock_id = self.defaultRockAsset();
        for (0..self.game.map.height) |y| {
            for (0..self.game.map.width) |x| {
                var cell = &self.game.map.terrain[y][x];
                if (map_mod.isVoidTerrain(cell.*) or map_mod.isShaderTerrain(cell.*)) {
                    cell.asset_id = NoAsset;
                } else if (cell.terrain_id == 3) {
                    cell.asset_id = water_id;
                } else if (!cell.walkable) {
                    cell.asset_id = if (rock_id != NoAsset) rock_id else self.terrainAsset(cell.terrain_id);
                } else if (terrain_count > 0) {
                    cell.asset_id = self.terrainAssetForCell(x, y, cell.terrain_id);
                } else {
                    cell.asset_id = NoAsset;
                }
            }
        }

        self.assignObjectAssets(false);
        self.editor.brush_asset_id = self.catalog.firstOfKind(.terrain) orelse 0;
    }

    fn assignObjectAssets(self: *AppState, preserve_valid: bool) void {
        const rock_id = self.defaultRockAsset();
        for (self.game.map.objects[0..self.game.map.object_count]) |*object| {
            if (preserve_valid and self.assetFitsObjectKind(object.kind, object.asset_id)) continue;
            object.asset_id = self.defaultAssetForObject(object.*, rock_id);
        }
    }

    fn defaultAssetForObject(self: *const AppState, object: map_mod.MapObject, rock_id: u16) u16 {
        if (self.originalShowcaseAsset(object)) |asset_id| return asset_id;
        return self.defaultAssetForObjectKind(object.kind, rock_id);
    }

    fn defaultAssetForObjectKind(self: *const AppState, kind: map_mod.ObjectKind, rock_id: u16) u16 {
        if (self.object_sprites.assetForKind(kind)) |asset_id| return asset_id;
        return switch (kind) {
            .outpost, .defense_grid => self.catalog.nthOfKind(.building, 2) orelse self.catalog.firstOfKind(.building) orelse NoAsset,
            .obstacle => rock_id,
            else => NoAsset,
        };
    }

    fn defaultRockAsset(self: *const AppState) u16 {
        return self.catalog.nthOfKind(.doodad, 2) orelse self.catalog.firstOfKind(.doodad) orelse NoAsset;
    }

    fn originalShowcaseAsset(self: *const AppState, object: map_mod.MapObject) ?u16 {
        return switch (object.kind) {
            .outpost => self.originalBuilding(if (object.team == 0) 0 else 3),
            .defense_grid => self.originalBuilding(if (object.team == 0) 1 else 2),
            .obstacle => self.originalBarrierAsset(object.id),
            else => null,
        };
    }

    fn originalBuilding(self: *const AppState, index: usize) ?u16 {
        const suffixes = [_][]const u8{
            "buildings/arid_badlands/Building A1.1 sz2 shadow.png",
            "buildings/arid_badlands/Building B sz2 noshadow.png",
            "buildings/arid_badlands/Building C sz1 noshadow.png",
            "buildings/arid_badlands/Building H1.2 sz1 shadow.png",
        };
        return self.catalog.findByPathSuffix(suffixes[index % suffixes.len]);
    }

    fn originalBarrierAsset(self: *const AppState, object_id: u32) ?u16 {
        const suffixes = [_][]const u8{
            "buildings/arid_badlands/Building A1.2 sz2 shadow.png",
            "buildings/arid_badlands/Building B1.2 sz2 shadow.png",
            "buildings/arid_badlands/Building E1.2 sz3 shadow.png",
            "buildings/arid_badlands/Building G1.2 sz1 shadow.png",
            "doodads/arid_badlands/odds/Desert_terrain_l_Objective-Crashed Aerostatic-sz1-0.1.png",
            "doodads/arid_badlands/odds/Rail Segment 2.2.png",
            "doodads/arid_badlands/flora/Acacia Style Trees Patch 2z2 A-green.png",
            "doodads/arid_badlands/flora/Giant Cactus Patch 2x2 C-green.png",
            "doodads/arid_badlands/rocks/Dersert Rocks - Size 3A - medium.png",
            "doodads/arid_badlands/rocks/Desert Sunken Rocks- Dif terrain C - medium.png",
        };
        const index: usize = @intCast(object_id % suffixes.len);
        return self.catalog.findByPathSuffix(suffixes[index]);
    }

    fn terrainAsset(self: *const AppState, terrain_id: u8) u16 {
        const count = self.countAssets(.terrain);
        if (count == 0) return NoAsset;
        return self.catalog.nthOfKind(.terrain, @as(usize, terrain_id) % count) orelse NoAsset;
    }

    fn terrainAssetForCell(self: *const AppState, x: usize, y: usize, terrain_id: u8) u16 {
        const count = self.countAssets(.terrain);
        if (count == 0) return NoAsset;
        const base_count = @min(count, 4);
        const base_asset = self.catalog.nthOfKind(.terrain, @as(usize, terrain_id) % base_count) orelse NoAsset;
        if (count <= base_count) return base_asset;

        const hash = terrainVariantHash(x, y, terrain_id);
        if (hash % 100 >= 42) return base_asset;
        const variant_count = count - base_count;
        const variant_index = base_count + (@as(usize, @intCast(hash / 100)) % variant_count);
        return self.catalog.nthOfKind(.terrain, variant_index) orelse base_asset;
    }

    fn countAssets(self: *const AppState, kind: asset_loader.AssetKind) usize {
        var count: usize = 0;
        for (self.catalog.assets.items) |asset| {
            if (asset.kind == kind) count += 1;
        }
        return count;
    }

    fn createGeneratedSpriteAsset(self: *AppState, kind: asset_loader.AssetKind, source_id: u16) !void {
        if (self.sprite_count >= self.sprites.len) return error.AssetCatalogFull;
        const source = self.catalog.get(source_id) orelse return error.MissingSourceAsset;
        self.generated_asset_counter +|= 1;

        var path_buf: [1024]u8 = undefined;
        const dest_path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/generated/{s}_{d}.png",
            .{ platform.assetRoot(), @tagName(kind), self.generated_asset_counter },
        );
        try makeParentPath(dest_path);

        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, source.path, 12 * 1024 * 1024);
        defer self.allocator.free(bytes);
        try writeWholeFile(dest_path, bytes);

        const image = try png_loader.loadRgba(self.allocator, dest_path);
        defer image.deinit();
        const id = try self.catalog.addFileAsset(dest_path, kind);
        self.sprites[id] = createSprite(image.width, image.height, image.pixels);
        self.catalog.assets.items[id].width = @floatFromInt(image.width);
        self.catalog.assets.items[id].height = @floatFromInt(image.height);
        self.sprite_count = @max(self.sprite_count, @as(usize, id) + 1);
        self.editor.brush_asset_id = id;
        self.editor.setStatus("Created sprite {d}: {s}", .{ id, self.catalog.assets.items[id].name });
    }

    fn drawWorld(self: *AppState) void {
        self.drawStarParallax();
        if (self.editor.show_terrain) self.drawTerrain();
        if (self.editor.show_pathing) self.drawPathingOverlay();
        if (self.editor.show_sectors) self.drawSectorOverlay();
        if (self.editor.show_portals) self.drawPortalOverlay();
        if (self.shouldDrawEditorGrid()) self.drawGrid();
        if (self.editor.show_objects) self.drawObjects();
        self.drawEditorPreviewOverlay();
        self.drawStartMenuBranding();
    }

    fn drawStartMenuBranding(self: *AppState) void {
        switch (self.game_shell_screen) {
            .menu, .sound, .rules, .credits => {},
            else => return,
        }

        const screen_w = sapp.widthf();
        const screen_h = sapp.heightf();
        const edge: f32 = 28.0;
        const t = self.starfield_time;

        if (self.tojam_logo_sprite.valid()) {
            const logo_w = @min(330.0, @max(140.0, screen_w * 0.22));
            const logo_h = logo_w * (self.tojam_logo_sprite.height / self.tojam_logo_sprite.width);
            const drift_x = @sin(t * 0.75) * 5.0;
            const drift_y = @sin(t * 1.15) * 7.0;
            const center = Vec2{
                .x = edge + logo_w * 0.5 + drift_x,
                .y = edge + logo_h * 0.5 + drift_y,
            };
            drawSpriteUpright(self.tojam_logo_sprite, self.sampler, self.alpha_pipeline, center, logo_w, logo_h, 0.92);
        }

        if (self.tojam_goat_sprite.valid()) {
            const goat_h = @min(250.0, @max(130.0, screen_h * 0.26));
            const goat_w = goat_h * (self.tojam_goat_sprite.width / self.tojam_goat_sprite.height);
            const drift_x = @sin(t * 0.85 + 1.4) * 6.0;
            const drift_y = @sin(t * 1.25 + 0.7) * 10.0;
            const center = Vec2{
                .x = screen_w - edge - goat_w * 0.5 + drift_x,
                .y = edge + goat_h * 0.5 + drift_y,
            };
            drawSpriteUpright(self.tojam_goat_sprite, self.sampler, self.alpha_pipeline, center, goat_w, goat_h, 0.92);
        }
    }

    fn drawStarParallax(self: *AppState) void {
        const screen_w = @max(1, sapp.widthf());
        const screen_h = @max(1, sapp.heightf());
        const center = Vec2{ .x = screen_w * 0.5, .y = screen_h * 0.5 };
        const margin: f32 = 150;
        const field_w = screen_w + margin * 2;
        const field_h = screen_h + margin * 2;

        sgl.beginQuads();
        for (StarParallaxLayers, 0..) |layer, layer_index| {
            const layer_seed: u32 = 0x91e10da5 +% @as(u32, @intCast(layer_index)) *% 0x45d9f3b;
            const camera_drift_x = (self.camera.x * layer.parallax + self.camera.y * layer.parallax * 0.18) * self.zoom;
            const camera_drift_y = (self.camera.y * layer.parallax - self.camera.x * layer.parallax * 0.12) * self.zoom;
            const zoom_scale = 1.0 + (self.zoom - 1.0) * layer.zoom_reactivity;
            for (0..layer.count) |i| {
                const seed = layer_seed +% @as(u32, @intCast(i)) *% 0x9e3779b9;
                const rx = starHash01(seed ^ 0x68bc21eb);
                const ry = starHash01(seed ^ 0x02e5be93);
                const rs = starHash01(seed ^ 0x4211f1d3);
                const rb = starHash01(seed ^ 0xb5297a4d);
                const speed = 0.70 + rs * 0.55;
                const phase = rb * std.math.tau;
                const twinkle = 0.86 + @sin(self.starfield_time * 0.9 + phase) * 0.08;
                const shimmer = (0.72 + rb * 0.28) * twinkle;
                const drift_x = camera_drift_x + self.starfield_time * layer.drift_x * speed;
                const drift_y = camera_drift_y + self.starfield_time * layer.drift_y * (0.8 + rb * 0.4);

                const wrapped_x = wrapFloat(rx * field_w - margin - drift_x, -margin, screen_w + margin);
                const wrapped_y = wrapFloat(ry * field_h - margin - drift_y, -margin, screen_h + margin);
                const x = center.x + (wrapped_x - center.x) * zoom_scale;
                const y = center.y + (wrapped_y - center.y) * zoom_scale;
                if (x < -margin or x > screen_w + margin or y < -margin or y > screen_h + margin) continue;

                const size = layer.radius_min + rs * layer.radius_range;
                const color: [4]f32 = .{
                    @min(1.0, layer.tint[0] * shimmer),
                    @min(1.0, layer.tint[1] * shimmer),
                    @min(1.0, layer.tint[2] * shimmer),
                    layer.alpha * (0.62 + rs * 0.38),
                };
                emitStarDiamond(.{ .x = x, .y = y }, size, color);
            }
        }
        sgl.end();
    }

    fn updateStarfield(self: *AppState, dt: f32) void {
        self.starfield_time += dt;
        if (self.starfield_time > 3600) self.starfield_time -= 3600;
    }

    fn shouldDrawEditorGrid(self: *const AppState) bool {
        return self.editor.show_grid and self.game_shell_screen == .map_editor;
    }

    fn drawTerrain(self: *AppState) void {
        self.shader_tile_vertex_count = 0;
        for (0..self.game.map.height) |y| {
            for (0..self.game.map.width) |x| {
                const cell = self.game.map.terrain[y][x];
                const center = self.worldToScreen(.{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                });
                if (map_mod.isVoidTerrain(cell)) {
                    continue;
                }
                if (map_mod.isShaderTerrain(cell)) {
                    self.appendShaderTile(center, TileW * self.zoom, TileH * self.zoom, cell.terrain_id, x, y);
                    continue;
                }
                const color = render.terrainColor(cell);
                drawDiamond(center, TileW * self.zoom, TileH * self.zoom, color);
                if (self.spriteForAsset(cell.asset_id)) |sprite| {
                    drawSprite(sprite, self.sampler, self.alpha_pipeline, center, TileW * self.zoom, TileH * self.zoom, 0.23);
                }
            }
        }
    }

    fn appendShaderTile(self: *AppState, center: Vec2, w: f32, h: f32, terrain_id: u8, x: usize, y: usize) void {
        if (self.shader_tile_vertex_count + 6 > self.shader_tile_vertices.len) return;
        const kind: f32 = if (terrain_id == map_mod.LavaTerrainId) 1.0 else 2.0;
        const seed: f32 = @floatFromInt((x *% 37 + y *% 131) % 997);
        const top = Vec2{ .x = center.x, .y = center.y - h * 0.5 };
        const right = Vec2{ .x = center.x + w * 0.5, .y = center.y };
        const bottom = Vec2{ .x = center.x, .y = center.y + h * 0.5 };
        const left = Vec2{ .x = center.x - w * 0.5, .y = center.y };
        self.emitShaderTileVertex(top, .{ .x = 0.5, .y = 0.0 }, kind, seed);
        self.emitShaderTileVertex(right, .{ .x = 1.0, .y = 0.5 }, kind, seed);
        self.emitShaderTileVertex(bottom, .{ .x = 0.5, .y = 1.0 }, kind, seed);
        self.emitShaderTileVertex(top, .{ .x = 0.5, .y = 0.0 }, kind, seed);
        self.emitShaderTileVertex(bottom, .{ .x = 0.5, .y = 1.0 }, kind, seed);
        self.emitShaderTileVertex(left, .{ .x = 0.0, .y = 0.5 }, kind, seed);
    }

    fn emitShaderTileVertex(self: *AppState, pos: Vec2, uv: Vec2, kind: f32, seed: f32) void {
        if (self.shader_tile_vertex_count >= self.shader_tile_vertices.len) return;
        self.shader_tile_vertices[self.shader_tile_vertex_count] = .{
            .position = self.screenToClip(pos),
            .uv = .{ uv.x, uv.y },
            .kind = kind,
            .seed = seed,
            .time = self.starfield_time,
        };
        self.shader_tile_vertex_count += 1;
    }

    fn drawShaderTiles(self: *AppState) void {
        if (self.shader_tile_pipeline.id == 0 or self.shader_tile_vertex_buffer.id == 0) return;
        if (self.shader_tile_vertex_count == 0) return;
        sg.updateBuffer(self.shader_tile_vertex_buffer, sg.asRange(self.shader_tile_vertices[0..self.shader_tile_vertex_count]));
        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = self.shader_tile_vertex_buffer;
        sg.applyPipeline(self.shader_tile_pipeline);
        sg.applyBindings(bindings);
        sg.draw(0, @intCast(self.shader_tile_vertex_count), 1);
    }

    fn drawObjects(self: *AppState) void {
        if (self.activeReplayFrame()) |replay_frame| {
            for (replay_frame.objects[0..replay_frame.object_count]) |object| {
                self.drawWorldObject(object);
            }
            return;
        }
        for (self.game.map.objects[0..self.game.map.object_count]) |object| {
            self.drawWorldObject(object);
        }
    }

    fn drawWorldObject(self: *AppState, object: map_mod.MapObject) void {
        if (!object.active) return;
        if (!self.objectVisibleInPhase(object)) return;
        const center = self.worldToScreen(.{
            .x = @as(f32, @floatFromInt(object.x)) + 0.5,
            .y = @as(f32, @floatFromInt(object.y)) + 0.5,
        });
        if (!self.tryDrawObjectSprite(object, center)) {
            self.drawObjectMarker(object, center);
        }
        if (self.editor.show_health) self.drawHealthBar(object, center);
    }

    fn consumeShotEvents(self: *AppState) void {
        const count = @min(self.game.simulation.shot_event_count, self.game.simulation.shot_events.len);
        self.perf.raw_shot_events = count;
        for (self.game.simulation.shot_events[0..count]) |event| {
            if (!self.shouldEmitLaserShot(event)) continue;
            self.perf.visual_shots += 1;
            self.playShotSfx(event);
            self.spawnLaserShot(event);
        }
    }

    fn playShotSfx(self: *AppState, event: sim_mod.ShotEvent) void {
        const sfx: audio_mod.SfxId = switch (event.attacker_kind) {
            .artillery => .artillery_fire,
            else => .infantry_attack,
        };
        self.audio.playSfxGain(sfx, ShotSfxGain);
        if (event.target_kind == .citadel or event.target_kind == .outpost or event.target_kind == .defense_grid) {
            self.audio.playSfxGain(.unit_hit_metal, HitSfxGain);
        }
    }

    fn shouldEmitLaserShot(self: *AppState, event: sim_mod.ShotEvent) bool {
        const emitter = self.laserEmitterFor(event.attacker_id);
        emitter.idle_seconds = 0;
        if (emitter.cooldown > 0) return false;
        emitter.cooldown = laserVisualCooldown(event.attacker_kind);
        return true;
    }

    fn laserEmitterFor(self: *AppState, attacker_id: u32) *LaserEmitter {
        for (&self.laser_emitters) |*emitter| {
            if (emitter.active and emitter.attacker_id == attacker_id) return emitter;
        }
        for (&self.laser_emitters) |*emitter| {
            if (!emitter.active) {
                emitter.* = .{ .active = true, .attacker_id = attacker_id };
                return emitter;
            }
        }
        const idx = self.laser_emitter_cursor;
        self.laser_emitter_cursor = (idx + 1) % self.laser_emitters.len;
        self.laser_emitters[idx] = .{ .active = true, .attacker_id = attacker_id };
        return &self.laser_emitters[idx];
    }

    fn spawnLaserShot(self: *AppState, event: sim_mod.ShotEvent) void {
        var start = self.worldToScreen(.{ .x = event.start_x, .y = event.start_y });
        var end = self.worldToScreen(.{ .x = event.end_x, .y = event.end_y });
        start.y -= self.shotLift(event.attacker_kind);
        end.y -= self.shotLift(event.target_kind) * 0.72;

        const color = laserColorForTeam(event.attacker_team);
        const beam = self.nextLaserBeamSlot() orelse return;
        beam.* = .{
            .active = true,
            .start = start,
            .end = end,
            .life = LaserBeamLife,
            .max_life = LaserBeamLife,
            .color = color,
        };

        const dx = end.x - start.x;
        const dy = end.y - start.y;
        const len = @max(1, @sqrt(dx * dx + dy * dy));
        const nx = dx / len;
        const ny = dy / len;
        const px = -ny;
        const py = nx;
        const particle_count: usize = if (event.damage >= 8) 6 else 4;
        var i: usize = 0;
        while (i < particle_count) : (i += 1) {
            const p = self.nextLaserParticleSlot() orelse break;
            const t = self.nextLaserRandom();
            const scatter = (self.nextLaserRandom() - 0.5) * 10;
            const speed = 46 + self.nextLaserRandom() * 96;
            const drift = (self.nextLaserRandom() - 0.5) * 170;
            const life = 0.22 + self.nextLaserRandom() * 0.34;
            p.* = .{
                .active = true,
                .pos = .{
                    .x = start.x + dx * t + px * scatter,
                    .y = start.y + dy * t + py * scatter,
                },
                .vel = .{
                    .x = -nx * speed + px * drift,
                    .y = -ny * speed + py * drift,
                },
                .accel = .{
                    .x = px * (self.nextLaserRandom() - 0.5) * 90,
                    .y = 72 + self.nextLaserRandom() * 80,
                },
                .life = life,
                .max_life = life,
                .radius = 1.6 + self.nextLaserRandom() * 2.5,
                .color = color,
            };
        }

        var impact: usize = 0;
        while (impact < 2) : (impact += 1) {
            const p = self.nextLaserParticleSlot() orelse break;
            const angle = self.nextLaserRandom() * std.math.tau;
            const speed = 70 + self.nextLaserRandom() * 130;
            const life = 0.16 + self.nextLaserRandom() * 0.22;
            p.* = .{
                .active = true,
                .pos = .{
                    .x = end.x + (self.nextLaserRandom() - 0.5) * 8,
                    .y = end.y + (self.nextLaserRandom() - 0.5) * 8,
                },
                .vel = .{
                    .x = @cos(angle) * speed,
                    .y = @sin(angle) * speed,
                },
                .accel = .{ .x = -nx * 45, .y = 95 },
                .life = life,
                .max_life = life,
                .radius = 1.4 + self.nextLaserRandom() * 2.2,
                .color = color,
            };
        }
    }

    fn updateLaserFx(self: *AppState, dt: f32) void {
        for (&self.laser_emitters) |*emitter| {
            if (!emitter.active) continue;
            emitter.cooldown = @max(0, emitter.cooldown - dt);
            emitter.idle_seconds += dt;
            if (emitter.idle_seconds >= LaserEmitterIdleSeconds) emitter.active = false;
        }
        for (&self.laser_beams) |*beam| {
            if (!beam.active) continue;
            beam.life -= dt;
            if (beam.life <= 0) {
                beam.active = false;
                if (self.laser_beam_active_count > 0) self.laser_beam_active_count -= 1;
            }
        }
        for (&self.laser_particles) |*particle| {
            if (!particle.active) continue;
            particle.life -= dt;
            if (particle.life <= 0) {
                particle.active = false;
                if (self.laser_particle_active_count > 0) self.laser_particle_active_count -= 1;
                continue;
            }
            particle.vel.x += particle.accel.x * dt;
            particle.vel.y += particle.accel.y * dt;
            const drag = @max(0, 1.0 - dt * 1.8);
            particle.vel.x *= drag;
            particle.vel.y *= drag;
            particle.pos.x += particle.vel.x * dt;
            particle.pos.y += particle.vel.y * dt;
        }
    }

    fn drawLaserFx(self: *AppState) void {
        if (self.laser_fx_pipeline.id == 0 or self.laser_fx_vertex_buffer.id == 0) return;
        self.laser_fx_vertex_count = 0;
        for (self.laser_beams) |beam| {
            if (!beam.active) continue;
            const fade = std.math.clamp(beam.life / @max(0.001, beam.max_life), 0, 1);
            self.appendBeamFx(beam.start, beam.end, beam.color, fade);
        }
        for (self.laser_particles) |particle| {
            if (!particle.active) continue;
            const fade = std.math.clamp(particle.life / @max(0.001, particle.max_life), 0, 1);
            var color = particle.color;
            color[3] *= fade;
            const size = particle.radius * (1.6 + fade * 1.2);
            self.appendParticleFx(particle.pos, size, color);
        }
        self.perf.laser_vertices = self.laser_fx_vertex_count;
        if (self.laser_fx_vertex_count == 0) return;

        sg.updateBuffer(self.laser_fx_vertex_buffer, sg.asRange(self.laser_fx_vertices[0..self.laser_fx_vertex_count]));
        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = self.laser_fx_vertex_buffer;
        sg.applyPipeline(self.laser_fx_pipeline);
        sg.applyBindings(bindings);
        sg.draw(0, @intCast(self.laser_fx_vertex_count), 1);
    }

    fn refreshPerfCounters(self: *AppState) void {
        var active_objects: usize = 0;
        for (self.game.map.objects[0..self.game.map.object_count]) |object| {
            if (object.active) active_objects += 1;
        }
        self.perf.object_count = self.game.map.object_count;
        self.perf.active_objects = active_objects;
        self.perf.active_beams = self.laser_beam_active_count;
        self.perf.active_particles = self.laser_particle_active_count;
    }

    fn clearLaserFx(self: *AppState) void {
        for (&self.laser_beams) |*beam| beam.active = false;
        for (&self.laser_particles) |*particle| particle.active = false;
        for (&self.laser_emitters) |*emitter| emitter.active = false;
        self.laser_beam_cursor = 0;
        self.laser_particle_cursor = 0;
        self.laser_emitter_cursor = 0;
        self.laser_beam_active_count = 0;
        self.laser_particle_active_count = 0;
        self.laser_fx_vertex_count = 0;
    }

    fn nextLaserBeamSlot(self: *AppState) ?*LaserBeam {
        if (self.laser_beam_active_count >= self.laser_beams.len) return null;
        var checked: usize = 0;
        while (checked < self.laser_beams.len) : (checked += 1) {
            const idx = self.laser_beam_cursor;
            self.laser_beam_cursor = (idx + 1) % self.laser_beams.len;
            if (!self.laser_beams[idx].active) {
                self.laser_beam_active_count += 1;
                return &self.laser_beams[idx];
            }
        }
        return null;
    }

    fn nextLaserParticleSlot(self: *AppState) ?*LaserParticle {
        if (self.laser_particle_active_count >= self.laser_particles.len) return null;
        var checked: usize = 0;
        while (checked < self.laser_particles.len) : (checked += 1) {
            const idx = self.laser_particle_cursor;
            self.laser_particle_cursor = (idx + 1) % self.laser_particles.len;
            if (!self.laser_particles[idx].active) {
                self.laser_particle_active_count += 1;
                return &self.laser_particles[idx];
            }
        }
        return null;
    }

    fn nextLaserRandom(self: *AppState) f32 {
        self.laser_rng = self.laser_rng *% 1664525 +% 1013904223;
        const bits = (self.laser_rng >> 8) & 0xffff;
        return @as(f32, @floatFromInt(bits)) / 65535.0;
    }

    fn appendBeamFx(self: *AppState, start: Vec2, end: Vec2, base_color: [4]f32, fade: f32) void {
        const dx = end.x - start.x;
        const dy = end.y - start.y;
        const len = @max(1, @sqrt(dx * dx + dy * dy));
        const px = -dy / len;
        const py = dx / len;
        var glow = base_color;
        glow[3] *= fade * 0.22;
        self.appendBeamQuad(start, end, px, py, 7.5 + fade * 2.5, glow);

        var core = base_color;
        core[0] = @min(1.0, core[0] + 0.22);
        core[1] = @min(1.0, core[1] + 0.22);
        core[2] = @min(1.0, core[2] + 0.22);
        core[3] *= fade * 0.92;
        self.appendBeamQuad(start, end, px, py, 2.0 + fade * 1.0, core);
    }

    fn appendBeamQuad(self: *AppState, start: Vec2, end: Vec2, px: f32, py: f32, half_w: f32, color: [4]f32) void {
        self.appendFxQuad(
            .{ .x = start.x + px * half_w, .y = start.y + py * half_w },
            .{ .x = end.x + px * half_w, .y = end.y + py * half_w },
            .{ .x = end.x - px * half_w, .y = end.y - py * half_w },
            .{ .x = start.x - px * half_w, .y = start.y - py * half_w },
            color,
        );
    }

    fn appendParticleFx(self: *AppState, center: Vec2, size: f32, color: [4]f32) void {
        var edge = color;
        edge[3] = 0;
        const top = Vec2{ .x = center.x, .y = center.y - size };
        const right = Vec2{ .x = center.x + size, .y = center.y };
        const bottom = Vec2{ .x = center.x, .y = center.y + size };
        const left = Vec2{ .x = center.x - size, .y = center.y };
        self.appendFxTriangle(center, top, right, color, edge, edge);
        self.appendFxTriangle(center, right, bottom, color, edge, edge);
        self.appendFxTriangle(center, bottom, left, color, edge, edge);
        self.appendFxTriangle(center, left, top, color, edge, edge);
    }

    fn appendFxQuad(
        self: *AppState,
        a: Vec2,
        b: Vec2,
        c0: Vec2,
        d: Vec2,
        color: [4]f32,
    ) void {
        self.appendFxTriangle(a, b, c0, color, color, color);
        self.appendFxTriangle(a, c0, d, color, color, color);
    }

    fn appendFxTriangle(self: *AppState, a: Vec2, b: Vec2, c0: Vec2, ca: [4]f32, cb: [4]f32, cc: [4]f32) void {
        self.appendFxVertex(a, ca);
        self.appendFxVertex(b, cb);
        self.appendFxVertex(c0, cc);
    }

    fn appendFxVertex(self: *AppState, screen: Vec2, color: [4]f32) void {
        if (self.laser_fx_vertex_count >= self.laser_fx_vertices.len) return;
        self.laser_fx_vertices[self.laser_fx_vertex_count] = .{
            .position = self.screenToClip(screen),
            .color = color,
        };
        self.laser_fx_vertex_count += 1;
    }

    fn screenToClip(self: *const AppState, screen: Vec2) [2]f32 {
        _ = self;
        const w = @max(1, sapp.widthf());
        const h = @max(1, sapp.heightf());
        return .{
            screen.x / w * 2.0 - 1.0,
            1.0 - screen.y / h * 2.0,
        };
    }

    fn shotLift(self: *const AppState, kind: map_mod.ObjectKind) f32 {
        if (self.object_sprites.get(kind)) |def| {
            return @max(14, def.draw_height * 0.42) * self.zoom;
        }
        const lift: f32 = switch (kind) {
            .citadel => @as(f32, 42),
            .imperator => @as(f32, 30),
            .outpost, .defense_grid => @as(f32, 34),
            .artillery => @as(f32, 26),
            .captain => @as(f32, 23),
            .infantry => @as(f32, 18),
            else => @as(f32, 16),
        } * self.zoom;
        return lift;
    }

    fn objectVisibleInPhase(self: *const AppState, object: map_mod.MapObject) bool {
        if (self.game_shell_screen == .replay) return true;
        if (self.game_shell_screen != .disabled and self.game_shell_screen != .setup) return true;
        const setup_player = self.game.simulation.activeSetupPlayer() orelse return true;
        return object.team == setup_player or object.kind == .obstacle;
    }

    fn tryDrawObjectSprite(self: *AppState, object: map_mod.MapObject, center: Vec2) bool {
        const def = self.object_sprites.get(object.kind);
        const asset_id = if (self.assetFitsObjectKind(object.kind, object.asset_id))
            object.asset_id
        else if (def) |object_def|
            object_def.asset_id orelse object.asset_id
        else
            object.asset_id;

        const sprite = self.spriteForAsset(asset_id) orelse return false;
        if (def) |object_def| {
            if (object_def.team_badge) self.drawTeamBadge(object, center, object_def);
            drawSpriteAnchored(sprite, self.sampler, self.alpha_pipeline, center, object_def, self.zoom, 1.0);
            return true;
        }

        if (!self.assetFitsObjectKind(object.kind, asset_id)) return false;
        const size = fallbackObjectDrawSize(object.kind, sprite);
        const w = size.x * self.zoom;
        const h = size.y * self.zoom;
        drawSpriteBottom(sprite, self.sampler, self.alpha_pipeline, center, w, h, 1.0);
        return true;
    }

    fn drawTeamBadge(self: *AppState, object: map_mod.MapObject, center: Vec2, def: *const sprite_defs.ObjectSpriteDef) void {
        const team_color: [4]f32 = if (object.team == 0)
            .{ 0.20, 0.62, 0.82, 0.42 }
        else
            .{ 0.86, 0.26, 0.20, 0.42 };
        const badge_center = Vec2{
            .x = center.x + def.offset_x * self.zoom,
            .y = center.y + (def.offset_y + 4) * self.zoom,
        };
        const w = TileW * self.zoom * (0.42 + 0.18 * @as(f32, @floatFromInt(def.footprint_w - 1)));
        const h = TileH * self.zoom * (0.58 + 0.16 * @as(f32, @floatFromInt(def.footprint_h - 1)));
        drawDiamond(badge_center, w, h, team_color);
    }

    fn drawObjectMarker(self: *AppState, object: map_mod.MapObject, center: Vec2) void {
        const team_color: [4]f32 = if (object.team == 0)
            .{ 0.20, 0.62, 0.82, 1.0 }
        else
            .{ 0.86, 0.35, 0.28, 1.0 };
        const neutral: [4]f32 = .{ 0.42, 0.72, 0.58, 1.0 };
        switch (object.kind) {
            .citadel => {
                const glow: [4]f32 = if (object.team == 0)
                    .{ 0.36, 0.82, 1.0, 0.95 }
                else
                    .{ 1.0, 0.40, 0.32, 0.95 };
                drawDiamond(center, TileW * self.zoom * 1.22, TileH * self.zoom * 1.22, .{ 0.10, 0.12, 0.12, 0.96 });
                drawDiamond(.{ .x = center.x, .y = center.y - 3 * self.zoom }, TileW * self.zoom * 0.98, TileH * self.zoom * 0.92, team_color);
                drawDiamond(.{ .x = center.x, .y = center.y - 9 * self.zoom }, TileW * self.zoom * 0.58, TileH * self.zoom * 0.52, .{ 0.18, 0.20, 0.21, 0.98 });
                drawRect(.{ .x = center.x - 4 * self.zoom, .y = center.y - 42 * self.zoom }, 8 * self.zoom, 34 * self.zoom, .{ 0.08, 0.09, 0.09, 0.92 });
                drawRect(.{ .x = center.x - 9 * self.zoom, .y = center.y - 45 * self.zoom }, 18 * self.zoom, 5 * self.zoom, glow);
                drawRect(.{ .x = center.x - 17 * self.zoom, .y = center.y - 8 * self.zoom }, 7 * self.zoom, 18 * self.zoom, .{ 0.07, 0.08, 0.08, 0.82 });
                drawRect(.{ .x = center.x + 10 * self.zoom, .y = center.y - 8 * self.zoom }, 7 * self.zoom, 18 * self.zoom, .{ 0.07, 0.08, 0.08, 0.82 });
            },
            .imperator => {
                drawDiamond(center, TileW * self.zoom * 0.58, TileH * self.zoom * 1.05, team_color);
                drawRect(.{ .x = center.x - 3, .y = center.y - 34 * self.zoom }, 6, 28 * self.zoom, .{ 0.90, 0.83, 0.52, 0.95 });
            },
            .infantry, .captain, .artillery => {
                const size: f32 = switch (object.kind) {
                    .captain => 0.54,
                    .artillery => 0.62,
                    else => 0.42,
                };
                drawDiamond(center, TileW * self.zoom * size, TileH * self.zoom * size, team_color);
                drawRect(.{ .x = center.x - 2, .y = center.y - 20 * self.zoom }, 4, 16 * self.zoom, .{ 0.10, 0.12, 0.12, 0.75 });
            },
            .portal => {
                drawDiamond(center, TileW * self.zoom * 0.82, TileH * self.zoom * 0.92, .{ 0.48, 0.38, 0.82, 0.85 });
                drawDiamond(center, TileW * self.zoom * 0.45, TileH * self.zoom * 0.48, .{ 0.78, 0.88, 0.96, 0.75 });
            },
            .healing_pod => drawDiamond(center, TileW * self.zoom * 0.62, TileH * self.zoom * 0.66, neutral),
            else => drawDiamond(center, TileW * self.zoom * 0.58, TileH * self.zoom * 0.68, team_color),
        }
    }

    fn drawHealthBar(self: *AppState, object: map_mod.MapObject, center: Vec2) void {
        if (object.max_hp <= 0 or object.hp >= object.max_hp) return;
        const w: f32 = 34;
        const h: f32 = 4;
        const pct = std.math.clamp(object.hp / object.max_hp, 0, 1);
        const y = if (self.object_sprites.get(object.kind)) |def|
            center.y + def.offset_y * self.zoom - def.draw_height * def.anchor_y * self.zoom - 7
        else
            center.y - 34;
        drawRect(.{ .x = center.x - w * 0.5, .y = y }, w, h, .{ 0.15, 0.12, 0.10, 0.9 });
        drawRect(.{ .x = center.x - w * 0.5, .y = y }, w * pct, h, .{ 0.2, 0.9, 0.38, 0.95 });
    }

    fn drawGrid(self: *AppState) void {
        sgl.beginLines();
        sgl.c4f(0.06, 0.06, 0.055, 0.32);
        for (0..self.game.map.height) |y| {
            for (0..self.game.map.width) |x| {
                if (map_mod.isVoidTerrain(self.game.map.terrain[y][x])) continue;
                const center = self.worldToScreen(.{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                });
                emitDiamondLine(center, TileW * self.zoom, TileH * self.zoom);
            }
        }
        sgl.end();
    }

    fn drawPathingOverlay(self: *AppState) void {
        for (0..self.game.map.height) |y| {
            for (0..self.game.map.width) |x| {
                const cell = self.game.map.terrain[y][x];
                if (cell.walkable or map_mod.isVoidTerrain(cell)) continue;
                const center = self.worldToScreen(.{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                });
                drawDiamond(center, TileW * self.zoom * 0.72, TileH * self.zoom * 0.64, .{ 0.86, 0.18, 0.10, 0.16 });
            }
        }
    }

    fn drawSectorOverlay(self: *AppState) void {
        sgl.beginLines();
        sgl.c4f(0.3, 0.85, 0.95, 0.8);
        for (self.game.pathfinder.sectors) |sector| {
            const a = self.worldToScreen(.{ .x = @floatFromInt(sector.x), .y = @floatFromInt(sector.y) });
            const b = self.worldToScreen(.{ .x = @floatFromInt(sector.x + sector.width), .y = @floatFromInt(sector.y) });
            const c0 = self.worldToScreen(.{ .x = @floatFromInt(sector.x + sector.width), .y = @floatFromInt(sector.y + sector.height) });
            const d = self.worldToScreen(.{ .x = @floatFromInt(sector.x), .y = @floatFromInt(sector.y + sector.height) });
            line(a, b);
            line(b, c0);
            line(c0, d);
            line(d, a);
        }
        sgl.end();
    }

    fn drawPortalOverlay(self: *AppState) void {
        sgl.beginQuads();
        for (self.game.pathfinder.graph.portals) |portal| {
            const center = self.worldToScreen(.{
                .x = (@as(f32, @floatFromInt(portal.tile_a.x)) + @as(f32, @floatFromInt(portal.tile_b.x))) * 0.5 + 0.5,
                .y = (@as(f32, @floatFromInt(portal.tile_a.y)) + @as(f32, @floatFromInt(portal.tile_b.y))) * 0.5 + 0.5,
            });
            sgl.c4f(0.95, 0.82, 0.18, 0.9);
            emitQuadCentered(center, 7, 7);
        }
        sgl.end();
    }

    fn drawEditorPreviewOverlay(self: *AppState) void {
        if (!self.editor.enabled or !self.editor.show_preview) return;
        self.drawBrushPreview();
        if (self.game_shell_screen != .setup) self.drawQuickAssetStrip();
    }

    fn drawBrushPreview(self: *AppState) void {
        const world = self.screenToWorld(self.mouse);
        const x: i32 = @intFromFloat(@floor(world.x));
        const y: i32 = @intFromFloat(@floor(world.y));
        if (!self.game.map.inBounds(x, y)) return;

        if (self.editor.tool == .object) {
            self.drawObjectPlacementPreview(x, y);
            return;
        }

        const radius = switch (self.editor.tool) {
            .terrain, .erase => self.editor.brush_radius,
            else => 0,
        };
        var oy: i32 = -radius;
        while (oy <= radius) : (oy += 1) {
            var ox: i32 = -radius;
            while (ox <= radius) : (ox += 1) {
                if (@abs(ox) + @abs(oy) > radius) continue;
                const tx = x + ox;
                const ty = y + oy;
                if (!self.game.map.inBounds(tx, ty)) continue;
                const is_center = ox == 0 and oy == 0;
                const center = self.worldToScreen(.{
                    .x = @as(f32, @floatFromInt(tx)) + 0.5,
                    .y = @as(f32, @floatFromInt(ty)) + 0.5,
                });

                switch (self.editor.tool) {
                    .terrain => {
                        const preview_void = self.editor.brush_terrain_id == map_mod.VoidTerrainId and !self.editor.terrain_walkable;
                        const preview_lava = self.editor.brush_terrain_id == map_mod.LavaTerrainId and !self.editor.terrain_walkable;
                        const preview_ice = self.editor.brush_terrain_id == map_mod.IceTerrainId and !self.editor.terrain_walkable;
                        if (preview_void) {
                            drawDiamondOutline(center, TileW * self.zoom, TileH * self.zoom, if (is_center) .{ 0.82, 0.94, 1.0, 0.82 } else .{ 0.70, 0.86, 1.0, 0.48 });
                        } else if (preview_lava) {
                            drawDiamond(center, TileW * self.zoom, TileH * self.zoom, .{ 1.0, 0.24, 0.04, if (is_center) 0.38 else 0.22 });
                        } else if (preview_ice) {
                            drawDiamond(center, TileW * self.zoom, TileH * self.zoom, .{ 0.40, 0.86, 1.0, if (is_center) 0.34 else 0.20 });
                        } else if (self.spriteForAsset(self.editor.brush_asset_id)) |sprite| {
                            drawSprite(sprite, self.sampler, self.alpha_pipeline, center, TileW * self.zoom, TileH * self.zoom, if (is_center) 0.48 else 0.30);
                        } else {
                            drawDiamond(center, TileW * self.zoom, TileH * self.zoom, .{ 0.42, 0.70, 0.92, if (is_center) 0.26 else 0.16 });
                        }
                        if (!preview_void) {
                            drawDiamondOutline(center, TileW * self.zoom, TileH * self.zoom, if (is_center) .{ 1.0, 0.86, 0.32, 0.95 } else .{ 0.85, 0.92, 0.96, 0.62 });
                        }
                    },
                    .erase => {
                        drawDiamond(center, TileW * self.zoom, TileH * self.zoom, .{ 0.95, 0.20, 0.16, if (is_center) 0.20 else 0.12 });
                        drawDiamondOutline(center, TileW * self.zoom, TileH * self.zoom, if (is_center) .{ 1.0, 0.36, 0.30, 0.98 } else .{ 0.95, 0.38, 0.32, 0.66 });
                        drawCross(center, TileW * self.zoom * 0.42, TileH * self.zoom * 0.42, .{ 1.0, 0.28, 0.22, if (is_center) 0.98 else 0.72 });
                    },
                    .select => drawDiamondOutline(center, TileW * self.zoom, TileH * self.zoom, .{ 0.98, 0.86, 0.30, 0.92 }),
                    else => {},
                }
            }
        }
    }

    fn drawObjectPlacementPreview(self: *AppState, x: i32, y: i32) void {
        const kind = self.editor.object_kind;
        const def = self.object_sprites.get(kind);
        const footprint_w = if (def) |object_def| object_def.footprint_w else @as(u8, 1);
        const footprint_h = if (def) |object_def| object_def.footprint_h else @as(u8, 1);

        var fy: u8 = 0;
        while (fy < footprint_h) : (fy += 1) {
            var fx: u8 = 0;
            while (fx < footprint_w) : (fx += 1) {
                const tx = x + @as(i32, @intCast(fx));
                const ty = y + @as(i32, @intCast(fy));
                if (!self.game.map.inBounds(tx, ty)) continue;
                const occupied = self.game.map.objectAt(tx, ty) != null;
                const terrain = self.game.map.terrain[@intCast(ty)][@intCast(tx)];
                const ok = terrain.buildable and !occupied;
                const center = self.worldToScreen(.{
                    .x = @as(f32, @floatFromInt(tx)) + 0.5,
                    .y = @as(f32, @floatFromInt(ty)) + 0.5,
                });
                drawDiamond(center, TileW * self.zoom, TileH * self.zoom, if (ok) .{ 0.18, 0.76, 0.36, 0.18 } else .{ 0.95, 0.20, 0.16, 0.22 });
                drawDiamondOutline(center, TileW * self.zoom, TileH * self.zoom, if (ok) .{ 0.34, 0.94, 0.44, 0.82 } else .{ 1.0, 0.34, 0.26, 0.90 });
            }
        }

        const center = self.worldToScreen(.{
            .x = @as(f32, @floatFromInt(x)) + 0.5,
            .y = @as(f32, @floatFromInt(y)) + 0.5,
        });
        const asset_id = self.assetForObjectKind(kind);
        if (self.spriteForAsset(asset_id)) |sprite| {
            if (def) |object_def| {
                drawSpriteAnchored(sprite, self.sampler, self.alpha_pipeline, center, object_def, self.zoom, 0.58);
            } else {
                const size = fallbackObjectDrawSize(kind, sprite);
                const w = size.x * self.zoom;
                const h = size.y * self.zoom;
                drawSpriteBottom(sprite, self.sampler, self.alpha_pipeline, center, w, h, 0.58);
            }
        } else {
            drawDiamond(center, TileW * self.zoom * 0.58, TileH * self.zoom * 0.68, .{ 0.94, 0.78, 0.24, 0.44 });
        }
    }

    fn drawQuickAssetStrip(self: *AppState) void {
        const slot_w: f32 = 48;
        const slot_h: f32 = 36;
        const gap: f32 = 6;
        const max_slots: usize = 9;
        var shown: usize = 0;
        for (self.catalog.assets.items) |asset| {
            if (shown >= max_slots) break;
            if (!self.assetUsefulForCurrentTool(asset)) continue;

            const x0 = 170 + @as(f32, @floatFromInt(shown)) * (slot_w + gap);
            const y0 = 14;
            drawRect(.{ .x = x0, .y = y0 }, slot_w, slot_h, .{ 0.025, 0.03, 0.028, 0.82 });
            if (self.spriteForAsset(asset.id)) |sprite| {
                const scale = @min((slot_w - 8) / @max(1, sprite.width), (slot_h - 8) / @max(1, sprite.height));
                drawSprite(sprite, self.sampler, self.alpha_pipeline, .{ .x = x0 + slot_w * 0.5, .y = y0 + slot_h * 0.5 }, sprite.width * scale, sprite.height * scale, 0.92);
            }
            const selected = asset.id == self.editor.brush_asset_id;
            drawRectOutline(.{ .x = x0, .y = y0 }, slot_w, slot_h, if (selected) .{ 0.95, 0.84, 0.25, 0.98 } else .{ 0.20, 0.23, 0.21, 0.78 });
            shown += 1;
        }
    }

    fn applyEditorAt(self: *AppState, screen: Vec2) void {
        if (!self.editor.enabled) return;
        const world = self.screenToWorld(screen);
        const x: i32 = @intFromFloat(@floor(world.x));
        const y: i32 = @intFromFloat(@floor(world.y));
        if (!self.game.map.inBounds(x, y)) return;
        self.editor.selected_cell_x = x;
        self.editor.selected_cell_y = y;

        switch (self.editor.tool) {
            .terrain => {
                var changed = false;
                var oy: i32 = -self.editor.brush_radius;
                while (oy <= self.editor.brush_radius) : (oy += 1) {
                    var ox: i32 = -self.editor.brush_radius;
                    while (ox <= self.editor.brush_radius) : (ox += 1) {
                        if (@abs(ox) + @abs(oy) > self.editor.brush_radius) continue;
                        const tx = x + ox;
                        const ty = y + oy;
                        if (!self.game.map.inBounds(tx, ty)) continue;
                        changed = self.game.map.paintTerrain(
                            tx,
                            ty,
                            self.editor.brush_terrain_id,
                            self.editor.brush_asset_id,
                            self.editor.terrain_walkable,
                            @intCast(@max(1, self.editor.terrain_cost)),
                        ) or changed;
                    }
                }
                if (changed) self.markPathingDirty();
            },
            .object => {
                const asset = self.assetForObjectKind(self.editor.object_kind);
                const setup_limited = self.game_shell_screen == .setup or self.game_shell_screen == .disabled;
                const player = if (setup_limited) self.game.simulation.placementPlayer(self.editor.current_player) else self.editor.current_player;
                if (setup_limited and !self.game.simulation.canPlaceObject(&self.game.map, self.editor.object_kind, player)) {
                    self.audio.playSfx(.invalid_action);
                    self.editor.setStatus("Setup placement limit reached for Player {d}.", .{player + 1});
                    return;
                }
                if (self.game.map.addObject(
                    self.editor.object_kind,
                    x,
                    y,
                    player,
                    player,
                    asset,
                ) != null) {
                    self.audio.playSfx(.build_complete);
                    self.markPathingDirty();
                } else {
                    self.audio.playSfx(.invalid_action);
                }
            },
            .erase => {
                var changed = false;
                const setup_limited = self.game_shell_screen == .setup or self.game_shell_screen == .disabled;
                const player = self.game.simulation.placementPlayer(self.editor.current_player);
                if (setup_limited) {
                    if (self.removeSetupObjectAtScreen(screen, player)) self.markPathingDirty();
                    return;
                }
                var oy: i32 = -self.editor.brush_radius;
                while (oy <= self.editor.brush_radius) : (oy += 1) {
                    var ox: i32 = -self.editor.brush_radius;
                    while (ox <= self.editor.brush_radius) : (ox += 1) {
                        if (@abs(ox) + @abs(oy) > self.editor.brush_radius) continue;
                        const tx = x + ox;
                        const ty = y + oy;
                        if (!self.game.map.inBounds(tx, ty)) continue;
                        if (!self.game.map.removeObjectAt(tx, ty)) {
                            changed = self.game.map.paintTerrain(tx, ty, 0, self.editor.brush_asset_id, true, 1) or changed;
                        } else {
                            changed = true;
                        }
                    }
                }
                if (changed) self.markPathingDirty();
            },
            .select => {},
        }
    }

    fn removeSetupObjectAtScreen(self: *AppState, screen: Vec2, player: u8) bool {
        var best_index: ?usize = null;
        var best_dist: f32 = std.math.floatMax(f32);
        var i: usize = 0;
        while (i < self.game.map.object_count) : (i += 1) {
            const object = self.game.map.objects[i];
            if (!object.active or object.team != player) continue;
            const center = self.worldToScreen(.{
                .x = @as(f32, @floatFromInt(object.x)) + 0.5,
                .y = @as(f32, @floatFromInt(object.y)) + 0.5,
            });
            if (!self.screenHitsObject(object, center, screen)) continue;
            const dx = screen.x - center.x;
            const dy = screen.y - center.y;
            const dist = dx * dx + dy * dy;
            if (dist < best_dist) {
                best_dist = dist;
                best_index = i;
            }
        }
        if (best_index) |index| {
            self.game.map.objects[index] = self.game.map.objects[self.game.map.object_count - 1];
            self.game.map.object_count -= 1;
            self.game.map.version += 1;
            return true;
        }
        return false;
    }

    fn screenHitsObject(self: *const AppState, object: map_mod.MapObject, center: Vec2, screen: Vec2) bool {
        if (self.object_sprites.get(object.kind)) |def| {
            const w = def.draw_width * self.zoom;
            const h = def.draw_height * self.zoom;
            const anchor_x = center.x + def.offset_x * self.zoom;
            const anchor_y = center.y + def.offset_y * self.zoom;
            const pad = 8.0 * self.zoom;
            const x0 = anchor_x - w * def.anchor_x - pad;
            const y0 = anchor_y - h * def.anchor_y - pad;
            return screen.x >= x0 and screen.x <= x0 + w + pad * 2 and
                screen.y >= y0 and screen.y <= y0 + h + pad * 2;
        }
        if (self.spriteForAsset(object.asset_id)) |sprite| {
            const size = fallbackObjectDrawSize(object.kind, sprite);
            const w = size.x * self.zoom;
            const h = size.y * self.zoom;
            const x0 = center.x - w * 0.5 - 8.0 * self.zoom;
            const y0 = center.y - h - 8.0 * self.zoom;
            return screen.x >= x0 and screen.x <= x0 + w + 16.0 * self.zoom and
                screen.y >= y0 and screen.y <= y0 + h + 16.0 * self.zoom;
        }
        const dx = @abs(screen.x - center.x);
        const dy = @abs(screen.y - center.y);
        return dx <= TileW * self.zoom * 0.45 and dy <= TileH * self.zoom * 0.65;
    }

    fn pickEditorAt(self: *AppState, screen: Vec2) void {
        if (!self.editor.enabled) return;
        const world = self.screenToWorld(screen);
        const x: i32 = @intFromFloat(@floor(world.x));
        const y: i32 = @intFromFloat(@floor(world.y));
        if (!self.game.map.inBounds(x, y)) return;
        self.editor.selected_cell_x = x;
        self.editor.selected_cell_y = y;

        if (self.game.map.objectAt(x, y)) |object| {
            self.editor.tool = .object;
            self.editor.object_kind = object.kind;
            self.editor.current_player = object.team;
            if (self.catalog.get(object.asset_id) != null) self.editor.brush_asset_id = object.asset_id;
            self.editor.setStatus("Picked {s} at {d},{d}", .{ tools.objectKindName(object.kind), x, y });
            return;
        }

        const cell = self.game.map.terrain[@intCast(y)][@intCast(x)];
        self.editor.tool = .terrain;
        self.editor.brush_terrain_id = cell.terrain_id;
        self.editor.brush_asset_id = cell.asset_id;
        self.editor.terrain_walkable = cell.walkable;
        self.editor.terrain_cost = cell.movement_cost;
        self.editor.setStatus("Picked terrain {d} at {d},{d}", .{ cell.terrain_id, x, y });
    }

    fn handleKeyboardCamera(self: *AppState, dt: f32) void {
        const speed = 520 * dt / self.zoom;
        if (self.keyDown(.A) or self.keyDown(.LEFT)) self.camera.x -= speed;
        if (self.keyDown(.D) or self.keyDown(.RIGHT)) self.camera.x += speed;
        if (self.keyDown(.W) or self.keyDown(.UP)) self.camera.y -= speed;
        if (self.keyDown(.S) or self.keyDown(.DOWN)) self.camera.y += speed;
    }

    fn setKey(self: *AppState, key: sapp.Keycode, down: bool) void {
        const raw: i32 = @intFromEnum(key);
        if (raw < 0) return;
        const idx: usize = @intCast(raw);
        if (idx < self.keys.len) self.keys[idx] = down;
    }

    fn keyDown(self: *const AppState, key: sapp.Keycode) bool {
        const raw: i32 = @intFromEnum(key);
        if (raw < 0) return false;
        const idx: usize = @intCast(raw);
        return idx < self.keys.len and self.keys[idx];
    }

    fn adjustBrushRadius(self: *AppState, delta: i32) void {
        self.editor.brush_radius = std.math.clamp(self.editor.brush_radius + delta, 0, 4);
        self.editor.setStatus("Brush radius {d}", .{self.editor.brush_radius});
    }

    fn cycleObjectKind(self: *AppState, delta: i32) void {
        var current: usize = 0;
        for (tools.ObjectPalette, 0..) |kind, i| {
            if (kind == self.editor.object_kind) {
                current = i;
                break;
            }
        }
        const next: usize = @intCast(@mod(@as(i32, @intCast(current)) + delta, @as(i32, @intCast(tools.ObjectPalette.len))));
        self.editor.tool = .object;
        self.editor.object_kind = tools.ObjectPalette[next];
        self.editor.setStatus("Object brush: {s}", .{tools.objectKindName(self.editor.object_kind)});
    }

    fn selectAssetSlot(self: *AppState, slot: usize) void {
        var shown: usize = 0;
        for (self.catalog.assets.items) |asset| {
            if (!self.assetUsefulForCurrentTool(asset)) continue;
            if (shown == slot) {
                self.selectAsset(asset.id);
                return;
            }
            shown += 1;
        }
    }

    fn cycleBrushAsset(self: *AppState, delta: i32) void {
        var count: usize = 0;
        var current_pos: ?usize = null;
        for (self.catalog.assets.items) |asset| {
            if (!self.assetUsefulForCurrentTool(asset)) continue;
            if (asset.id == self.editor.brush_asset_id) current_pos = count;
            count += 1;
        }
        if (count == 0) return;
        const base = current_pos orelse 0;
        const next: usize = @intCast(@mod(@as(i32, @intCast(base)) + delta, @as(i32, @intCast(count))));
        var shown: usize = 0;
        for (self.catalog.assets.items) |asset| {
            if (!self.assetUsefulForCurrentTool(asset)) continue;
            if (shown == next) {
                self.selectAsset(asset.id);
                return;
            }
            shown += 1;
        }
    }

    fn assetUsefulForCurrentTool(self: *const AppState, asset: asset_loader.SpriteAsset) bool {
        return switch (self.editor.tool) {
            .terrain => asset.kind == .terrain or asset.kind == .water,
            .object => asset.kind == .building or asset.kind == .doodad or asset.kind == .unit or asset.kind == .water,
            .erase, .select => true,
        };
    }

    fn assetForObjectKind(self: *const AppState, kind: map_mod.ObjectKind) u16 {
        if (self.selectedAssetFitsObject(kind)) {
            return self.editor.brush_asset_id;
        }
        return self.defaultAssetForObjectKind(kind, self.defaultRockAsset());
    }

    fn selectedAssetFitsObject(self: *const AppState, kind: map_mod.ObjectKind) bool {
        return self.assetFitsObjectKind(kind, self.editor.brush_asset_id);
    }

    fn assetFitsObjectKind(self: *const AppState, kind: map_mod.ObjectKind, asset_id: u16) bool {
        const asset = self.catalog.get(asset_id) orelse return false;
        return switch (kind) {
            .citadel, .outpost, .defense_grid => asset.kind == .building,
            .imperator, .infantry, .captain, .artillery => asset.kind == .unit,
            .portal, .healing_pod => asset.kind == .doodad,
            .obstacle => asset.kind == .building or asset.kind == .doodad or asset.kind == .water,
        };
    }

    fn spriteForAsset(self: *const AppState, asset_id: u16) ?Sprite {
        if (asset_id >= self.sprite_count) return null;
        const sprite = self.sprites[asset_id];
        return if (sprite.valid()) sprite else null;
    }

    fn worldToScreen(self: *const AppState, world: Vec2) Vec2 {
        const iso = Vec2{
            .x = (world.x - world.y) * TileW * 0.5,
            .y = (world.x + world.y) * TileH * 0.5,
        };
        return .{
            .x = (iso.x - self.camera.x) * self.zoom + sapp.widthf() * 0.5,
            .y = (iso.y - self.camera.y) * self.zoom + sapp.heightf() * 0.5,
        };
    }

    fn screenToWorld(self: *const AppState, screen: Vec2) Vec2 {
        const iso_x = (screen.x - sapp.widthf() * 0.5) / self.zoom + self.camera.x;
        const iso_y = (screen.y - sapp.heightf() * 0.5) / self.zoom + self.camera.y;
        return .{
            .x = ((iso_y / (TileH * 0.5)) + (iso_x / (TileW * 0.5))) * 0.5,
            .y = ((iso_y / (TileH * 0.5)) - (iso_x / (TileW * 0.5))) * 0.5,
        };
    }
};

fn createSprite(width: i32, height: i32, pixels: []const u8) Sprite {
    const img = sg.makeImage(.{
        .width = width,
        .height = height,
        .pixel_format = .RGBA8,
        .data = .{
            .mip_levels = [_]sg.Range{sg.asRange(pixels)} ++ ([_]sg.Range{.{}} ** 15),
        },
    });
    const view = sg.makeView(.{ .texture = .{ .image = img } });
    return .{
        .image = img,
        .view = view,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}

fn destroySprite(sprite: *Sprite) void {
    if (sprite.view.id != 0) sg.destroyView(sprite.view);
    if (sprite.image.id != 0) sg.destroyImage(sprite.image);
    sprite.* = .{};
}

fn laserFxShaderDesc() sg.ShaderDesc {
    var desc: sg.ShaderDesc = .{};
    desc.vertex_func.source = laserFxVertexShaderSource();
    desc.fragment_func.source = laserFxFragmentShaderSource();
    if (usesMetalBackend()) {
        desc.vertex_func.entry = "vs_main";
        desc.fragment_func.entry = "fs_main";
    }
    desc.attrs[0] = .{ .base_type = .FLOAT, .glsl_name = "position", .hlsl_sem_name = "POSITION" };
    desc.attrs[1] = .{ .base_type = .FLOAT, .glsl_name = "color0", .hlsl_sem_name = "COLOR" };
    desc.label = "laser-fx-shader";
    return desc;
}

fn laserFxVertexShaderSource() [*c]const u8 {
    return if (usesMetalBackend())
        MetalLaserFxVs.ptr
    else if (builtin.target.os.tag == .emscripten)
        GlesLaserFxVs.ptr
    else
        GlCoreLaserFxVs.ptr;
}

fn laserFxFragmentShaderSource() [*c]const u8 {
    return if (usesMetalBackend())
        MetalLaserFxFs.ptr
    else if (builtin.target.os.tag == .emscripten)
        GlesLaserFxFs.ptr
    else
        GlCoreLaserFxFs.ptr;
}

fn shaderTileShaderDesc() sg.ShaderDesc {
    var desc: sg.ShaderDesc = .{};
    desc.vertex_func.source = shaderTileVertexShaderSource();
    desc.fragment_func.source = shaderTileFragmentShaderSource();
    if (usesMetalBackend()) {
        desc.vertex_func.entry = "vs_main";
        desc.fragment_func.entry = "fs_main";
    }
    desc.attrs[0] = .{ .base_type = .FLOAT, .glsl_name = "position", .hlsl_sem_name = "POSITION" };
    desc.attrs[1] = .{ .base_type = .FLOAT, .glsl_name = "uv0", .hlsl_sem_name = "TEXCOORD", .hlsl_sem_index = 0 };
    desc.attrs[2] = .{ .base_type = .FLOAT, .glsl_name = "kind0", .hlsl_sem_name = "TEXCOORD", .hlsl_sem_index = 1 };
    desc.attrs[3] = .{ .base_type = .FLOAT, .glsl_name = "seed0", .hlsl_sem_name = "TEXCOORD", .hlsl_sem_index = 2 };
    desc.attrs[4] = .{ .base_type = .FLOAT, .glsl_name = "time0", .hlsl_sem_name = "TEXCOORD", .hlsl_sem_index = 3 };
    desc.label = "shader-tile-shader";
    return desc;
}

fn shaderTileVertexShaderSource() [*c]const u8 {
    return if (usesMetalBackend())
        MetalShaderTileVs.ptr
    else if (builtin.target.os.tag == .emscripten)
        GlesShaderTileVs.ptr
    else
        GlCoreShaderTileVs.ptr;
}

fn shaderTileFragmentShaderSource() [*c]const u8 {
    return if (usesMetalBackend())
        MetalShaderTileFs.ptr
    else if (builtin.target.os.tag == .emscripten)
        GlesShaderTileFs.ptr
    else
        GlCoreShaderTileFs.ptr;
}

fn usesMetalBackend() bool {
    return builtin.target.os.tag.isDarwin();
}

const MetalLaserFxVs =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VsIn {
    \\    float2 position [[attribute(0)]];
    \\    float4 color0 [[attribute(1)]];
    \\};
    \\
    \\struct VsOut {
    \\    float4 position [[position]];
    \\    float4 color0;
    \\};
    \\
    \\vertex VsOut vs_main(VsIn in [[stage_in]]) {
    \\    VsOut out;
    \\    out.position = float4(in.position, 0.0, 1.0);
    \\    out.color0 = in.color0;
    \\    return out;
    \\}
;

const MetalLaserFxFs =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct FsIn {
    \\    float4 position [[position]];
    \\    float4 color0;
    \\};
    \\
    \\fragment float4 fs_main(FsIn in [[stage_in]]) {
    \\    return in.color0;
    \\}
;

const GlesLaserFxVs =
    \\#version 300 es
    \\precision mediump float;
    \\layout(location=0) in vec2 position;
    \\layout(location=1) in vec4 color0;
    \\out vec4 v_color0;
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    v_color0 = color0;
    \\}
;

const GlesLaserFxFs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec4 v_color0;
    \\out vec4 frag_color;
    \\void main() {
    \\    frag_color = v_color0;
    \\}
;

const GlCoreLaserFxVs =
    \\#version 330
    \\layout(location=0) in vec2 position;
    \\layout(location=1) in vec4 color0;
    \\out vec4 v_color0;
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    v_color0 = color0;
    \\}
;

const GlCoreLaserFxFs =
    \\#version 330
    \\in vec4 v_color0;
    \\out vec4 frag_color;
    \\void main() {
    \\    frag_color = v_color0;
    \\}
;

const MetalShaderTileVs =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VsIn {
    \\    float2 position [[attribute(0)]];
    \\    float2 uv0 [[attribute(1)]];
    \\    float kind0 [[attribute(2)]];
    \\    float seed0 [[attribute(3)]];
    \\    float time0 [[attribute(4)]];
    \\};
    \\
    \\struct VsOut {
    \\    float4 position [[position]];
    \\    float2 uv0;
    \\    float kind0;
    \\    float seed0;
    \\    float time0;
    \\};
    \\
    \\vertex VsOut vs_main(VsIn in [[stage_in]]) {
    \\    VsOut out;
    \\    out.position = float4(in.position, 0.0, 1.0);
    \\    out.uv0 = in.uv0;
    \\    out.kind0 = in.kind0;
    \\    out.seed0 = in.seed0;
    \\    out.time0 = in.time0;
    \\    return out;
    \\}
;

const MetalShaderTileFs =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct FsIn {
    \\    float4 position [[position]];
    \\    float2 uv0;
    \\    float kind0;
    \\    float seed0;
    \\    float time0;
    \\};
    \\
    \\static float hash21(float2 p) {
    \\    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
    \\}
    \\
    \\fragment float4 fs_main(FsIn in [[stage_in]]) {
    \\    float2 uv = in.uv0;
    \\    float t = in.time0;
    \\    float seed = in.seed0 * 0.013;
    \\    float edge = smoothstep(0.54, 0.40, abs(uv.x - 0.5) + abs(uv.y - 0.5));
    \\    float grain = hash21(floor((uv + seed) * 18.0));
    \\    if (in.kind0 < 1.5) {
    \\        float flow = sin((uv.x * 11.0 - uv.y * 7.0) + t * 2.4 + seed) * 0.5 + 0.5;
    \\        float ember = pow(max(0.0, flow * 0.72 + grain * 0.45), 2.0);
    \\        float cracks = smoothstep(0.72, 0.98, sin((uv.x + uv.y) * 32.0 + t * 1.7 + seed) * 0.5 + 0.5);
    \\        float pulse = 0.78 + sin(t * 3.1 + seed * 9.0) * 0.18;
    \\        float3 base = mix(float3(0.18, 0.035, 0.015), float3(1.0, 0.28, 0.035), ember * pulse);
    \\        base += float3(1.0, 0.72, 0.20) * cracks * 0.22;
    \\        return float4(base * edge, edge);
    \\    }
    \\    float sheen = smoothstep(0.70, 0.98, sin((uv.x - uv.y) * 24.0 + t * 1.15 + seed) * 0.5 + 0.5);
    \\    float glint = pow(max(0.0, sin((uv.x * 21.0 + uv.y * 15.0) - t * 3.3 + seed)), 8.0);
    \\    float3 ice = mix(float3(0.05, 0.22, 0.34), float3(0.60, 0.92, 1.0), 0.34 + sheen * 0.30 + grain * 0.10);
    \\    ice += float3(0.82, 0.98, 1.0) * glint * 0.50;
    \\    return float4(ice * edge, edge * 0.94);
    \\}
;

const GlesShaderTileVs =
    \\#version 300 es
    \\precision mediump float;
    \\layout(location=0) in vec2 position;
    \\layout(location=1) in vec2 uv0;
    \\layout(location=2) in float kind0;
    \\layout(location=3) in float seed0;
    \\layout(location=4) in float time0;
    \\out vec2 v_uv0;
    \\out float v_kind0;
    \\out float v_seed0;
    \\out float v_time0;
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    v_uv0 = uv0;
    \\    v_kind0 = kind0;
    \\    v_seed0 = seed0;
    \\    v_time0 = time0;
    \\}
;

const GlesShaderTileFs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv0;
    \\in float v_kind0;
    \\in float v_seed0;
    \\in float v_time0;
    \\out vec4 frag_color;
    \\float hash21(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    \\}
    \\void main() {
    \\    vec2 uv = v_uv0;
    \\    float t = v_time0;
    \\    float seed = v_seed0 * 0.013;
    \\    float edge = smoothstep(0.54, 0.40, abs(uv.x - 0.5) + abs(uv.y - 0.5));
    \\    float grain = hash21(floor((uv + seed) * 18.0));
    \\    if (v_kind0 < 1.5) {
    \\        float flow = sin((uv.x * 11.0 - uv.y * 7.0) + t * 2.4 + seed) * 0.5 + 0.5;
    \\        float ember = pow(max(0.0, flow * 0.72 + grain * 0.45), 2.0);
    \\        float cracks = smoothstep(0.72, 0.98, sin((uv.x + uv.y) * 32.0 + t * 1.7 + seed) * 0.5 + 0.5);
    \\        float pulse = 0.78 + sin(t * 3.1 + seed * 9.0) * 0.18;
    \\        vec3 base = mix(vec3(0.18, 0.035, 0.015), vec3(1.0, 0.28, 0.035), ember * pulse);
    \\        base += vec3(1.0, 0.72, 0.20) * cracks * 0.22;
    \\        frag_color = vec4(base * edge, edge);
    \\        return;
    \\    }
    \\    float sheen = smoothstep(0.70, 0.98, sin((uv.x - uv.y) * 24.0 + t * 1.15 + seed) * 0.5 + 0.5);
    \\    float glint = pow(max(0.0, sin((uv.x * 21.0 + uv.y * 15.0) - t * 3.3 + seed)), 8.0);
    \\    vec3 ice = mix(vec3(0.05, 0.22, 0.34), vec3(0.60, 0.92, 1.0), 0.34 + sheen * 0.30 + grain * 0.10);
    \\    ice += vec3(0.82, 0.98, 1.0) * glint * 0.50;
    \\    frag_color = vec4(ice * edge, edge * 0.94);
    \\}
;

const GlCoreShaderTileVs =
    \\#version 330
    \\layout(location=0) in vec2 position;
    \\layout(location=1) in vec2 uv0;
    \\layout(location=2) in float kind0;
    \\layout(location=3) in float seed0;
    \\layout(location=4) in float time0;
    \\out vec2 v_uv0;
    \\out float v_kind0;
    \\out float v_seed0;
    \\out float v_time0;
    \\void main() {
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\    v_uv0 = uv0;
    \\    v_kind0 = kind0;
    \\    v_seed0 = seed0;
    \\    v_time0 = time0;
    \\}
;

const GlCoreShaderTileFs =
    \\#version 330
    \\in vec2 v_uv0;
    \\in float v_kind0;
    \\in float v_seed0;
    \\in float v_time0;
    \\out vec4 frag_color;
    \\float hash21(vec2 p) {
    \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
    \\}
    \\void main() {
    \\    vec2 uv = v_uv0;
    \\    float t = v_time0;
    \\    float seed = v_seed0 * 0.013;
    \\    float edge = smoothstep(0.54, 0.40, abs(uv.x - 0.5) + abs(uv.y - 0.5));
    \\    float grain = hash21(floor((uv + seed) * 18.0));
    \\    if (v_kind0 < 1.5) {
    \\        float flow = sin((uv.x * 11.0 - uv.y * 7.0) + t * 2.4 + seed) * 0.5 + 0.5;
    \\        float ember = pow(max(0.0, flow * 0.72 + grain * 0.45), 2.0);
    \\        float cracks = smoothstep(0.72, 0.98, sin((uv.x + uv.y) * 32.0 + t * 1.7 + seed) * 0.5 + 0.5);
    \\        float pulse = 0.78 + sin(t * 3.1 + seed * 9.0) * 0.18;
    \\        vec3 base = mix(vec3(0.18, 0.035, 0.015), vec3(1.0, 0.28, 0.035), ember * pulse);
    \\        base += vec3(1.0, 0.72, 0.20) * cracks * 0.22;
    \\        frag_color = vec4(base * edge, edge);
    \\        return;
    \\    }
    \\    float sheen = smoothstep(0.70, 0.98, sin((uv.x - uv.y) * 24.0 + t * 1.15 + seed) * 0.5 + 0.5);
    \\    float glint = pow(max(0.0, sin((uv.x * 21.0 + uv.y * 15.0) - t * 3.3 + seed)), 8.0);
    \\    vec3 ice = mix(vec3(0.05, 0.22, 0.34), vec3(0.60, 0.92, 1.0), 0.34 + sheen * 0.30 + grain * 0.10);
    \\    ice += vec3(0.82, 0.98, 1.0) * glint * 0.50;
    \\    frag_color = vec4(ice * edge, edge * 0.94);
    \\}
;

fn drawDiamond(center: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.beginTriangles();
    emitDiamondFill(center, w, h, color);
    sgl.end();
}

fn emitDiamondFill(center: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(center.x, center.y - h * 0.5);
    sgl.v2f(center.x + w * 0.5, center.y);
    sgl.v2f(center.x, center.y + h * 0.5);
    sgl.v2f(center.x, center.y - h * 0.5);
    sgl.v2f(center.x, center.y + h * 0.5);
    sgl.v2f(center.x - w * 0.5, center.y);
}

fn emitDiamondLine(center: Vec2, w: f32, h: f32) void {
    sgl.v2f(center.x, center.y - h * 0.5);
    sgl.v2f(center.x + w * 0.5, center.y);
    sgl.v2f(center.x + w * 0.5, center.y);
    sgl.v2f(center.x, center.y + h * 0.5);
    sgl.v2f(center.x, center.y + h * 0.5);
    sgl.v2f(center.x - w * 0.5, center.y);
    sgl.v2f(center.x - w * 0.5, center.y);
    sgl.v2f(center.x, center.y - h * 0.5);
}

fn drawDiamondOutline(center: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.beginLines();
    sgl.c4f(color[0], color[1], color[2], color[3]);
    emitDiamondLine(center, w, h);
    sgl.end();
}

fn emitStarDiamond(center: Vec2, radius: f32, color: [4]f32) void {
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(center.x, center.y - radius);
    sgl.v2f(center.x + radius, center.y);
    sgl.v2f(center.x, center.y + radius);
    sgl.v2f(center.x - radius, center.y);
}

fn ruleBullet(text: [*:0]const u8) void {
    c.igTextWrapped("- %s", text);
}

fn drawSprite(sprite: Sprite, sampler: sg.Sampler, pipeline: sgl.Pipeline, center: Vec2, w: f32, h: f32, alpha: f32) void {
    sgl.loadPipeline(pipeline);
    sgl.enableTexture();
    sgl.texture(sprite.view, sampler);
    sgl.beginQuads();
    sgl.c4f(1, 1, 1, alpha);
    emitTexturedQuadCentered(center, w, h);
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn drawSpriteUpright(sprite: Sprite, sampler: sg.Sampler, pipeline: sgl.Pipeline, center: Vec2, w: f32, h: f32, alpha: f32) void {
    sgl.loadPipeline(pipeline);
    sgl.enableTexture();
    sgl.texture(sprite.view, sampler);
    sgl.beginQuads();
    sgl.c4f(1, 1, 1, alpha);
    const x0 = center.x - w * 0.5;
    const y0 = center.y - h * 0.5;
    sgl.v2fT2f(x0, y0, 0, 1);
    sgl.v2fT2f(x0 + w, y0, 1, 1);
    sgl.v2fT2f(x0 + w, y0 + h, 1, 0);
    sgl.v2fT2f(x0, y0 + h, 0, 0);
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn drawSpriteBottom(sprite: Sprite, sampler: sg.Sampler, pipeline: sgl.Pipeline, bottom: Vec2, w: f32, h: f32, alpha: f32) void {
    sgl.loadPipeline(pipeline);
    sgl.enableTexture();
    sgl.texture(sprite.view, sampler);
    sgl.beginQuads();
    sgl.c4f(1, 1, 1, alpha);
    const x0 = bottom.x - w * 0.5;
    const y0 = bottom.y - h;
    sgl.v2fT2f(x0, y0, 0, 1);
    sgl.v2fT2f(x0 + w, y0, 1, 1);
    sgl.v2fT2f(x0 + w, bottom.y, 1, 0);
    sgl.v2fT2f(x0, bottom.y, 0, 0);
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn drawSpriteAnchored(
    sprite: Sprite,
    sampler: sg.Sampler,
    pipeline: sgl.Pipeline,
    anchor: Vec2,
    def: *const sprite_defs.ObjectSpriteDef,
    zoom: f32,
    alpha: f32,
) void {
    const w = def.draw_width * zoom;
    const h = def.draw_height * zoom;
    const anchor_x = anchor.x + def.offset_x * zoom;
    const anchor_y = anchor.y + def.offset_y * zoom;
    const x0 = anchor_x - w * def.anchor_x;
    const y0 = anchor_y - h * def.anchor_y;

    sgl.loadPipeline(pipeline);
    sgl.enableTexture();
    sgl.texture(sprite.view, sampler);
    sgl.beginQuads();
    sgl.c4f(1, 1, 1, alpha);
    sgl.v2fT2f(x0, y0, 0, 1);
    sgl.v2fT2f(x0 + w, y0, 1, 1);
    sgl.v2fT2f(x0 + w, y0 + h, 1, 0);
    sgl.v2fT2f(x0, y0 + h, 0, 0);
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn fallbackObjectDrawSize(kind: map_mod.ObjectKind, sprite: Sprite) Vec2 {
    const scale: f32 = switch (kind) {
        .outpost, .defense_grid => 1.15,
        .obstacle => 0.82,
        else => 0.9,
    };
    const max_w: f32 = 112;
    const max_h: f32 = 128;
    const source_w = @max(1.0, sprite.width * scale);
    const source_h = @max(1.0, sprite.height * scale);
    const fit = @min(max_w / source_w, max_h / source_h);
    return .{
        .x = source_w * fit,
        .y = source_h * fit,
    };
}

fn emitTexturedQuadCentered(center: Vec2, w: f32, h: f32) void {
    const x0 = center.x - w * 0.5;
    const y0 = center.y - h * 0.5;
    sgl.v2fT2f(x0, y0, 0, 0);
    sgl.v2fT2f(x0 + w, y0, 1, 0);
    sgl.v2fT2f(x0 + w, y0 + h, 1, 1);
    sgl.v2fT2f(x0, y0 + h, 0, 1);
}

fn emitQuadCentered(center: Vec2, w: f32, h: f32) void {
    const x0 = center.x - w * 0.5;
    const y0 = center.y - h * 0.5;
    sgl.v2f(x0, y0);
    sgl.v2f(x0 + w, y0);
    sgl.v2f(x0 + w, y0 + h);
    sgl.v2f(x0, y0 + h);
}

fn drawRect(pos: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.beginQuads();
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(pos.x, pos.y);
    sgl.v2f(pos.x + w, pos.y);
    sgl.v2f(pos.x + w, pos.y + h);
    sgl.v2f(pos.x, pos.y + h);
    sgl.end();
}

fn drawRectOutline(pos: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.beginLines();
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(pos.x, pos.y);
    sgl.v2f(pos.x + w, pos.y);
    sgl.v2f(pos.x + w, pos.y);
    sgl.v2f(pos.x + w, pos.y + h);
    sgl.v2f(pos.x + w, pos.y + h);
    sgl.v2f(pos.x, pos.y + h);
    sgl.v2f(pos.x, pos.y + h);
    sgl.v2f(pos.x, pos.y);
    sgl.end();
}

fn drawCross(center: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.beginLines();
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(center.x - w * 0.5, center.y - h * 0.5);
    sgl.v2f(center.x + w * 0.5, center.y + h * 0.5);
    sgl.v2f(center.x + w * 0.5, center.y - h * 0.5);
    sgl.v2f(center.x - w * 0.5, center.y + h * 0.5);
    sgl.end();
}

fn starHash01(seed: u32) f32 {
    var x = seed;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return @as(f32, @floatFromInt(x & 0xffff)) / 65535.0;
}

fn wrapFloat(value: f32, min: f32, max: f32) f32 {
    const span = max - min;
    if (!(span > 0)) return min;
    return value - @floor((value - min) / span) * span;
}

fn laserColorForTeam(team: u8) [4]f32 {
    return if (team == 0)
        .{ 0.38, 0.86, 1.0, 0.96 }
    else
        .{ 1.0, 0.34, 0.22, 0.96 };
}

fn laserVisualCooldown(kind: map_mod.ObjectKind) f32 {
    return switch (kind) {
        .imperator => 0.08,
        .artillery => 0.16,
        .outpost, .defense_grid => 0.12,
        .captain => 0.11,
        else => 0.13,
    };
}

fn elapsedMs(start_ticks: u64, end_ticks: u64) f32 {
    return @floatCast(stime.ms(stime.diff(end_ticks, start_ticks)));
}

fn smoothMs(target: *f32, value: f32) void {
    if (target.* == 0) {
        target.* = value;
    } else {
        target.* += (value - target.*) * 0.18;
    }
}

fn line(a: Vec2, b: Vec2) void {
    sgl.v2f(a.x, a.y);
    sgl.v2f(b.x, b.y);
}

fn uiV2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

fn uiCol32(r: u8, g: u8, b: u8, a: u8) c.ImU32 {
    return @as(c.ImU32, r) |
        (@as(c.ImU32, g) << 8) |
        (@as(c.ImU32, b) << 16) |
        (@as(c.ImU32, a) << 24);
}

fn playerUiColor(player: u8, alpha: u8) c.ImU32 {
    return switch (player) {
        0 => uiCol32(72, 161, 216, alpha),
        1 => uiCol32(224, 76, 58, alpha),
        else => uiCol32(218, 205, 136, alpha),
    };
}

fn playerPanelColor(player: u8, alpha: u8) c.ImU32 {
    return switch (player) {
        0 => uiCol32(16, 42, 58, alpha),
        1 => uiCol32(64, 26, 22, alpha),
        else => uiCol32(36, 34, 22, alpha),
    };
}

fn gameOverAccentColor(winner: ?u8, alpha: u8) c.ImU32 {
    return if (winner) |player|
        playerUiColor(player, alpha)
    else
        uiCol32(198, 190, 150, alpha);
}

fn gameOverPanelColor(winner: ?u8, alpha: u8) c.ImU32 {
    return if (winner) |player|
        playerPanelColor(player, alpha)
    else
        uiCol32(34, 35, 31, alpha);
}

fn entityStatsZ(kind: map_mod.ObjectKind, buf: []u8) [:0]const u8 {
    const stats = map_mod.defaultStats(kind);
    return switch (kind) {
        .citadel => std.fmt.bufPrintZ(buf, "HP {d:.0}  Heal {d:.0}  Range {d:.1}", .{ stats.hp, -stats.damage_per_second, stats.range }) catch "HP --",
        .portal => std.fmt.bufPrintZ(buf, "HP {d:.0}  Teleport", .{stats.hp}) catch "HP --",
        .healing_pod => std.fmt.bufPrintZ(buf, "HP {d:.0}  Heal {d:.0}  Range {d:.1}", .{ stats.hp, -stats.damage_per_second, stats.range }) catch "HP --",
        .obstacle => std.fmt.bufPrintZ(buf, "Blocks", .{}) catch "Blocks",
        .outpost, .defense_grid => std.fmt.bufPrintZ(buf, "HP {d:.0}  Dmg {d:.0}  Range {d:.1}", .{ stats.hp, stats.damage_per_second, stats.range }) catch "HP --",
        .imperator, .infantry, .captain, .artillery => std.fmt.bufPrintZ(
            buf,
            "HP {d:.0}  Dmg {d:.0}  Range {d:.1}  Move {d:.2}",
            .{ stats.hp, stats.damage_per_second, stats.range, stats.move_seconds },
        ) catch "HP --",
    };
}

fn copyToBuffer(buffer: []u8, value: []const u8) usize {
    if (buffer.len == 0) return 0;
    const len = @min(buffer.len, value.len);
    @memcpy(buffer[0..len], value[0..len]);
    return len;
}

fn terrainVariantHash(x: usize, y: usize, terrain_id: u8) u32 {
    var hash: u32 = 2166136261;
    hash = (hash ^ @as(u32, @intCast(x))) *% 16777619;
    hash = (hash ^ @as(u32, @intCast(y))) *% 16777619;
    hash = (hash ^ @as(u32, terrain_id)) *% 16777619;
    return hash;
}

fn hasCommandModifier(modifiers: u32) bool {
    return (modifiers & sapp.modifier_ctrl) != 0 or (modifiers & sapp.modifier_super) != 0;
}

fn hasShift(modifiers: u32) bool {
    return (modifiers & sapp.modifier_shift) != 0;
}

fn appMode() AppMode {
    if (std.mem.eql(u8, build_options.app_mode, "editor")) return .editor;
    if (std.mem.eql(u8, build_options.app_mode, "game")) return .game;
    return .integrated;
}

fn assetKindForObjectKind(kind: map_mod.ObjectKind) asset_loader.AssetKind {
    return switch (kind) {
        .citadel, .outpost, .defense_grid => .building,
        .imperator, .infantry, .captain, .artillery => .unit,
        .portal, .healing_pod, .obstacle => .doodad,
    };
}

fn makeParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (std.fs.path.isAbsolute(parent)) {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        try std.fs.cwd().makePath(parent);
    }
}

fn writeWholeFile(path: []const u8, bytes: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn appDesc() sapp.Desc {
    const is_web = builtin.target.cpu.arch.isWasm();
    return .{
        .width = 1440,
        .height = 900,
        .sample_count = 1,
        .window_title = GameTitle,
        .icon = .{ .sokol_default = true },
        .high_dpi = !is_web,
        .html5 = .{
            .canvas_selector = "#canvas",
            .canvas_resize = false,
            .preserve_drawing_buffer = false,
            .premultiplied_alpha = true,
            .ask_leave_site = false,
        },
        .logger = .{ .func = slog.func },
    };
}
