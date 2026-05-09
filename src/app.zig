const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const slog = sokol.log;

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
    mouse: Vec2 = .{ .x = 0, .y = 0 },
    last_mouse: Vec2 = .{ .x = 0, .y = 0 },
    panning: bool = false,
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

        self.loadAssets();
        self.loadObjectSpriteDefinitions();
        self.assignStarterAssets();
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
        self.handleKeyboardCamera(dt);
        self.game.update(dt);

        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = dt,
            .dpi_scale = sapp.dpiScale(),
        });
        imgui_ui.draw(self);

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

        self.drawWorld();
        sgl.draw();
        simgui.render();
        sg.endPass();
        sg.commit();
    }

    pub fn handleEvent(self: *AppState, ev: sapp.Event) void {
        const consumed = simgui.handleEvent(ev);
        switch (ev.type) {
            .MOUSE_MOVE => {
                self.last_mouse = self.mouse;
                self.mouse = .{ .x = ev.mouse_x, .y = ev.mouse_y };
                if (self.panning) {
                    self.camera.x -= (self.mouse.x - self.last_mouse.x) / self.zoom;
                    self.camera.y -= (self.mouse.y - self.last_mouse.y) / self.zoom;
                }
            },
            .MOUSE_DOWN => {
                self.mouse = .{ .x = ev.mouse_x, .y = ev.mouse_y };
                if (ev.mouse_button == .RIGHT) {
                    self.panning = true;
                } else if (ev.mouse_button == .LEFT and !consumed) {
                    self.applyEditorClick(self.mouse);
                }
            },
            .MOUSE_UP => {
                if (ev.mouse_button == .RIGHT) self.panning = false;
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
                    .TAB => self.editor.enabled = !self.editor.enabled,
                    .SPACE => self.togglePlaytest(),
                    .S => if (hasCommandModifier(ev.modifiers)) self.saveMap(),
                    .L => if (hasCommandModifier(ev.modifiers)) self.loadMap(),
                    ._1 => self.editor.tool = .terrain,
                    ._2 => self.editor.tool = .object,
                    ._3 => self.editor.tool = .erase,
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

    pub fn togglePlaytest(self: *AppState) void {
        self.game.simulation.togglePlay();
        self.editor.setStatus("Phase: {s}", .{@tagName(self.game.simulation.phase)});
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

    fn drawWorld(self: *AppState) void {
        self.drawTerrain();
        if (self.editor.show_pathing) self.drawPathingOverlay();
        if (self.editor.show_sectors) self.drawSectorOverlay();
        if (self.editor.show_portals) self.drawPortalOverlay();
        if (self.editor.show_grid) self.drawGrid();
        self.drawObjects();
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
            const center = self.worldToScreen(.{
                .x = @as(f32, @floatFromInt(object.x)) + 0.5,
                .y = @as(f32, @floatFromInt(object.y)) + 0.5,
            });
            if (!self.tryDrawObjectSprite(object, center)) {
                self.drawObjectMarker(object, center);
            }
            self.drawHealthBar(object, center);
        }
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

    fn applyEditorClick(self: *AppState, screen: Vec2) void {
        if (!self.editor.enabled) return;
        const world = self.screenToWorld(screen);
        const x: i32 = @intFromFloat(@floor(world.x));
        const y: i32 = @intFromFloat(@floor(world.y));
        if (!self.game.map.inBounds(x, y)) return;
        self.editor.selected_cell_x = x;
        self.editor.selected_cell_y = y;

        switch (self.editor.tool) {
            .terrain => {
                self.game.map.paintTerrain(
                    x,
                    y,
                    self.editor.brush_terrain_id,
                    self.editor.brush_asset_id,
                    self.editor.terrain_walkable,
                    @intCast(@max(1, self.editor.terrain_cost)),
                );
                self.game.rebuildPathing() catch {};
            },
            .object => {
                const asset = self.assetForObjectKind(self.editor.object_kind);
                _ = self.game.map.addObject(
                    self.editor.object_kind,
                    x,
                    y,
                    self.editor.current_player,
                    self.editor.current_player,
                    asset,
                );
                self.game.rebuildPathing() catch {};
            },
            .erase => {
                if (!self.game.map.removeObjectAt(x, y)) {
                    self.game.map.paintTerrain(x, y, 0, self.editor.brush_asset_id, true, 1);
                }
                self.game.rebuildPathing() catch {};
            },
            .select => {},
        }
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

fn line(a: Vec2, b: Vec2) void {
    sgl.v2f(a.x, a.y);
    sgl.v2f(b.x, b.y);
}

fn hasCommandModifier(modifiers: u32) bool {
    return (modifiers & sapp.modifier_ctrl) != 0 or (modifiers & sapp.modifier_super) != 0;
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
            .canvas_resize = true,
            .preserve_drawing_buffer = false,
            .premultiplied_alpha = true,
            .ask_leave_site = false,
        },
        .logger = .{ .func = slog.func },
    };
}
