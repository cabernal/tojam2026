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

const TileW: f32 = 64;
const TileH: f32 = 32;
const MaxSprites = asset_loader.MaxAssets;
const NoAsset: u16 = std.math.maxInt(u16);

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

const Sprite = struct {
    image: sg.Image = .{},
    view: sg.View = .{},
    width: f32 = 0,
    height: f32 = 0,

    fn valid(self: Sprite) bool {
        return self.image.id != 0 and self.view.id != 0;
    }
};

pub const AppState = struct {
    allocator: std.mem.Allocator = undefined,
    game: runtime.RuntimeGame = undefined,
    catalog: asset_loader.AssetCatalog = undefined,
    object_sprites: sprite_defs.SpriteDefinitions = undefined,
    editor: editor_mod.EditorState = .{},
    sprites: [MaxSprites]Sprite = [_]Sprite{.{}} ** MaxSprites,
    sprite_count: usize = 0,
    sampler: sg.Sampler = .{},
    alpha_pipeline: sgl.Pipeline = .{},
    pass_action: sg.PassAction = .{},
    initialized: bool = false,
    allow_editor: bool = true,
    loading: LoadingState = .{},
    mouse: Vec2 = .{ .x = 0, .y = 0 },
    last_mouse: Vec2 = .{ .x = 0, .y = 0 },
    panning: bool = false,
    painting: bool = false,
    generated_asset_counter: u32 = 0,
    right_pan_start: Vec2 = .{ .x = 0, .y = 0 },
    right_pan_moved: bool = false,
    keys: [512]bool = [_]bool{false} ** 512,
    camera: Vec2 = .{ .x = 0, .y = 0 },
    zoom: f32 = 1.0,

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

        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });
        sgl.setup(.{ .logger = .{ .func = slog.func } });
        simgui.setup(.{ .logger = .{ .func = slog.func } });

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

        self.initialized = true;
    }

    pub fn cleanup(self: *AppState) void {
        if (!self.initialized) return;
        for (self.sprites[0..self.sprite_count]) |*sprite| destroySprite(sprite);
        if (self.sampler.id != 0) sg.destroySampler(self.sampler);
        if (self.alpha_pipeline.id != 0) sgl.destroyPipeline(self.alpha_pipeline);
        self.object_sprites.deinit();
        self.catalog.deinit();
        self.game.deinit();
        simgui.shutdown();
        sgl.shutdown();
        sg.shutdown();
        self.initialized = false;
    }

    pub fn frame(self: *AppState) void {
        if (!self.initialized) return;
        var dt: f32 = @floatCast(sapp.frameDuration());
        if (!(dt > 0 and dt < 0.25)) dt = 1.0 / 60.0;

        if (!self.ready() and self.loading.frames_seen > 0 and self.loading.phase != .failed) {
            self.advanceLoading();
        }
        const is_ready = self.ready();
        if (is_ready) {
            self.syncEditorPlayerWithSetup();
            self.handleKeyboardCamera(dt);
            self.game.update(dt);
        }

        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = dt,
            .dpi_scale = sapp.dpiScale(),
        });
        if (is_ready) {
            imgui_ui.draw(self);
        } else {
            self.drawLoadingUi();
        }

        sg.beginPass(.{
            .action = self.pass_action,
            .swapchain = sglue.swapchain(),
        });

        sgl.defaults();
        sgl.matrixModeProjection();
        sgl.loadIdentity();
        sgl.ortho(0, sapp.widthf(), sapp.heightf(), 0, -1, 1);
        sgl.matrixModeModelview();
        sgl.loadIdentity();

        if (is_ready) {
            self.drawWorld();
        } else {
            self.drawLoadingBackdrop();
        }
        sgl.draw();
        simgui.render();
        sg.endPass();
        sg.commit();

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
                        if (self.allow_editor) self.editor.enabled = !self.editor.enabled;
                    },
                    .SPACE => self.togglePlaytest(),
                    .S => if (hasCommandModifier(ev.modifiers)) self.saveMap(),
                    .L => if (hasCommandModifier(ev.modifiers)) self.loadMap(),
                    ._1 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(0) else self.editor.tool = .terrain;
                    },
                    ._2 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(1) else self.editor.tool = .object;
                    },
                    ._3 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(2) else self.editor.tool = .erase;
                    },
                    ._4 => {
                        if (hasShift(ev.modifiers)) self.selectAssetSlot(3) else self.editor.tool = .select;
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
                    .T => self.editor.tool = .terrain,
                    .O => self.editor.tool = .object,
                    .X => self.editor.tool = .erase,
                    .V => self.editor.tool = .select,
                    else => {},
                }
            },
            .KEY_UP => self.setKey(ev.key_code, false),
            else => {},
        }
    }

    pub fn saveMap(self: *AppState) void {
        if (!platform.canPersistMaps()) {
            self.editor.setStatus("Map save is disabled in the web build.", .{});
            return;
        }
        map_io.save(schema.DefaultMapPath, &self.game.map) catch |err| {
            self.editor.setStatus("Save failed: {s}", .{@errorName(err)});
            return;
        };
        self.editor.setStatus("Saved {s}", .{schema.DefaultMapPath});
    }

    pub fn loadMap(self: *AppState) void {
        if (!platform.canPersistMaps()) {
            self.editor.setStatus("Map load is disabled in the web build.", .{});
            return;
        }
        const loaded = map_io.load(self.allocator, schema.DefaultMapPath) catch |err| {
            self.editor.setStatus("Load failed: {s}", .{@errorName(err)});
            return;
        };
        self.game.map = loaded;
        self.assignObjectAssets(true);
        self.game.rebuildPathing() catch {};
        self.editor.setStatus("Loaded {s}", .{schema.DefaultMapPath});
    }

    pub fn resetDefaultMap(self: *AppState) void {
        self.game.map = map_mod.GameMap.initDefault();
        self.game.simulation.resetSetup();
        self.syncEditorPlayerWithSetup();
        self.assignStarterAssets();
        self.game.rebuildPathing() catch {};
        self.editor.setStatus("Reset to starter battlefield.", .{});
    }

    pub fn selectAsset(self: *AppState, asset_id: u16) void {
        self.editor.brush_asset_id = asset_id;
        if (self.catalog.get(asset_id)) |asset| {
            self.editor.setStatus("Selected asset {d}: {s}", .{ asset.id, asset.name });
        }
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
        if (!self.allow_editor) return;
        self.game.simulation.togglePlay();
        self.syncEditorPlayerWithSetup();
        self.editor.setStatus("Phase: {s}", .{@tagName(self.game.simulation.phase)});
    }

    fn ready(self: *const AppState) bool {
        return self.loading.phase == .complete;
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
                self.allow_editor = false;
                self.editor.enabled = false;
                self.game.simulation.startPlaying();
            },
        }
    }

    fn syncEditorPlayerWithSetup(self: *AppState) void {
        if (self.game.simulation.activeSetupPlayer()) |player| {
            self.editor.current_player = player;
        }
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
                self.game.rebuildPathing() catch {};
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

        c.igTextUnformatted("TOJam 2026 RTS Prototype", null);
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

    fn assignStarterAssets(self: *AppState) void {
        const terrain_count = self.countAssets(.terrain);
        const water_id = self.catalog.firstOfKind(.water) orelse self.catalog.firstOfKind(.terrain) orelse NoAsset;
        const rock_id = self.defaultRockAsset();
        for (0..self.game.map.height) |y| {
            for (0..self.game.map.width) |x| {
                var cell = &self.game.map.terrain[y][x];
                if (cell.terrain_id == 3) {
                    cell.asset_id = water_id;
                } else if (!cell.walkable) {
                    cell.asset_id = if (rock_id != NoAsset) rock_id else self.terrainAsset(cell.terrain_id);
                } else if (terrain_count > 0) {
                    cell.asset_id = self.terrainAsset(cell.terrain_id);
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
            .obstacle => self.originalDoodad(object.id),
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

    fn originalDoodad(self: *const AppState, object_id: u32) ?u16 {
        const suffixes = [_][]const u8{
            "doodads/arid_badlands/flora/Acacia Style Trees Patch 2z2 B-green.png",
            "doodads/arid_badlands/flora/Giant Cactus Patch 2x2 A-green.png",
            "doodads/arid_badlands/odds/Rail Segment 2.2.png",
            "doodads/arid_badlands/rocks/Dersert Rocks - Size 1A - light.png",
            "doodads/arid_badlands/rocks/Dersert Rocks - Size 1B - medium.png",
            "doodads/arid_badlands/rocks/Dersert Rocks - Size 2A - dark.png",
            "doodads/arid_badlands/rocks/Desert Small Rockpile- Dif terrain C - light.png",
        };
        const index: usize = @intCast(object_id % suffixes.len);
        return self.catalog.findByPathSuffix(suffixes[index]);
    }

    fn terrainAsset(self: *const AppState, terrain_id: u8) u16 {
        const count = self.countAssets(.terrain);
        if (count == 0) return NoAsset;
        return self.catalog.nthOfKind(.terrain, @as(usize, terrain_id) % count) orelse NoAsset;
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
        if (self.editor.show_terrain) self.drawTerrain();
        if (self.editor.show_pathing) self.drawPathingOverlay();
        if (self.editor.show_sectors) self.drawSectorOverlay();
        if (self.editor.show_portals) self.drawPortalOverlay();
        if (self.editor.show_grid) self.drawGrid();
        if (self.editor.show_objects) self.drawObjects();
        self.drawEditorPreviewOverlay();
    }

    fn drawTerrain(self: *AppState) void {
        for (0..self.game.map.height) |y| {
            for (0..self.game.map.width) |x| {
                const cell = self.game.map.terrain[y][x];
                const center = self.worldToScreen(.{
                    .x = @as(f32, @floatFromInt(x)) + 0.5,
                    .y = @as(f32, @floatFromInt(y)) + 0.5,
                });
                const color = render.terrainColor(cell);
                drawDiamond(center, TileW * self.zoom, TileH * self.zoom, color);
                if (self.spriteForAsset(cell.asset_id)) |sprite| {
                    drawSprite(sprite, self.sampler, self.alpha_pipeline, center, TileW * self.zoom, TileH * self.zoom, 0.23);
                }
            }
        }
    }

    fn drawObjects(self: *AppState) void {
        for (self.game.map.objects[0..self.game.map.object_count]) |object| {
            if (!object.active) continue;
            if (!self.objectVisibleInPhase(object)) continue;
            const center = self.worldToScreen(.{
                .x = @as(f32, @floatFromInt(object.x)) + 0.5,
                .y = @as(f32, @floatFromInt(object.y)) + 0.5,
            });
            if (!self.tryDrawObjectSprite(object, center)) {
                self.drawObjectMarker(object, center);
            }
            if (self.editor.show_health) self.drawHealthBar(object, center);
        }
    }

    fn objectVisibleInPhase(self: *const AppState, object: map_mod.MapObject) bool {
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
        const scale: f32 = switch (object.kind) {
            .outpost, .defense_grid => 1.15,
            .obstacle => 0.82,
            else => 0.9,
        };
        const w = @min(112, sprite.width * scale) * self.zoom;
        const h = @min(128, sprite.height * scale) * self.zoom;
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
                if (self.game.map.terrain[y][x].walkable) continue;
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
        self.drawQuickAssetStrip();
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
                        if (self.spriteForAsset(self.editor.brush_asset_id)) |sprite| {
                            drawSprite(sprite, self.sampler, self.alpha_pipeline, center, TileW * self.zoom, TileH * self.zoom, if (is_center) 0.48 else 0.30);
                        } else {
                            drawDiamond(center, TileW * self.zoom, TileH * self.zoom, .{ 0.42, 0.70, 0.92, if (is_center) 0.26 else 0.16 });
                        }
                        drawDiamondOutline(center, TileW * self.zoom, TileH * self.zoom, if (is_center) .{ 1.0, 0.86, 0.32, 0.95 } else .{ 0.85, 0.92, 0.96, 0.62 });
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
                const scale: f32 = switch (kind) {
                    .outpost, .defense_grid => 1.15,
                    .obstacle => 0.82,
                    else => 0.9,
                };
                const w = @min(112, sprite.width * scale) * self.zoom;
                const h = @min(128, sprite.height * scale) * self.zoom;
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
                        self.game.map.paintTerrain(
                            tx,
                            ty,
                            self.editor.brush_terrain_id,
                            self.editor.brush_asset_id,
                            self.editor.terrain_walkable,
                            @intCast(@max(1, self.editor.terrain_cost)),
                        );
                        changed = true;
                    }
                }
                if (changed) self.game.rebuildPathing() catch {};
            },
            .object => {
                const asset = self.assetForObjectKind(self.editor.object_kind);
                const player = self.game.simulation.placementPlayer(self.editor.current_player);
                if (!self.game.simulation.canPlaceObject(&self.game.map, self.editor.object_kind, player)) {
                    self.editor.setStatus("Setup placement limit reached for Player {d}.", .{player + 1});
                    return;
                }
                _ = self.game.map.addObject(
                    self.editor.object_kind,
                    x,
                    y,
                    player,
                    player,
                    asset,
                );
                self.game.rebuildPathing() catch {};
            },
            .erase => {
                var changed = false;
                var oy: i32 = -self.editor.brush_radius;
                while (oy <= self.editor.brush_radius) : (oy += 1) {
                    var ox: i32 = -self.editor.brush_radius;
                    while (ox <= self.editor.brush_radius) : (ox += 1) {
                        if (@abs(ox) + @abs(oy) > self.editor.brush_radius) continue;
                        const tx = x + ox;
                        const ty = y + oy;
                        if (!self.game.map.inBounds(tx, ty)) continue;
                        if (!self.game.map.removeObjectAt(tx, ty)) {
                            self.game.map.paintTerrain(tx, ty, 0, self.editor.brush_asset_id, true, 1);
                        }
                        changed = true;
                    }
                }
                if (changed) self.game.rebuildPathing() catch {};
            },
            .select => {},
        }
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
            .obstacle => asset.kind == .doodad or asset.kind == .water,
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

fn drawDiamond(center: Vec2, w: f32, h: f32, color: [4]f32) void {
    sgl.beginTriangles();
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(center.x, center.y - h * 0.5);
    sgl.v2f(center.x + w * 0.5, center.y);
    sgl.v2f(center.x, center.y + h * 0.5);
    sgl.v2f(center.x, center.y - h * 0.5);
    sgl.v2f(center.x, center.y + h * 0.5);
    sgl.v2f(center.x - w * 0.5, center.y);
    sgl.end();
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
        .window_title = "TOJam 2026 RTS Prototype",
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
