const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const c = @import("../cimgui.zig").c;
const tools = @import("tools.zig");
const assets = @import("../assets/asset_loader.zig");
const sim = @import("../runtime/simulation.zig");
const map_mod = @import("../map/map.zig");

pub fn draw(app: anytype) void {
    if (!app.editor.enabled) return;
    drawToolbar(app);
    drawInspector(app);
    drawAssetBrowser(app);
}

fn drawToolbar(app: anytype) void {
    c.igSetNextWindowPos(v2(12, 56), c.ImGuiCond_Always, v2(0, 0));
    c.igSetNextWindowSize(v2(132, 268), c.ImGuiCond_Always);
    _ = c.igBegin("Tools", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
    defer c.igEnd();

    toolButton(app, .terrain, "Terrain");
    toolButton(app, .object, "Object");
    toolButton(app, .erase, "Erase");
    toolButton(app, .select, "Select");

    c.igSeparator();
    if (c.igButton(phaseButtonLabel(app.game.simulation.phase), v2(104, 0))) {
        app.togglePlaytest();
    }
    if (c.igButton("Default", v2(104, 0))) {
        app.resetDefaultMap();
    }
}

fn drawInspector(app: anytype) void {
    const w = sapp.widthf();
    c.igSetNextWindowPos(v2(@max(160, w - 336), 56), c.ImGuiCond_Always, v2(0, 0));
    c.igSetNextWindowSize(v2(324, 472), c.ImGuiCond_Always);
    _ = c.igBegin("Inspector", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
    defer c.igEnd();

    uiText("Mode: {s}", .{tools.toolName(app.editor.tool)});
    uiText("Phase: {s}", .{phaseName(app.game.simulation.phase)});
    if (app.game.simulation.winner) |winner| {
        uiText("Winner: Player {d}", .{winner + 1});
    }
    c.igSeparator();

    var player: i32 = app.editor.current_player;
    c.igSetNextItemWidth(160);
    if (c.igSliderInt("Player", &player, 0, 1, "%d", 0)) {
        app.editor.current_player = @intCast(std.math.clamp(player, 0, 1));
    }

    if (app.editor.tool == .terrain) {
        var terrain_id: i32 = app.editor.brush_terrain_id;
        c.igSetNextItemWidth(160);
        if (c.igSliderInt("Terrain", &terrain_id, 0, 15, "%d", 0)) {
            app.editor.brush_terrain_id = @intCast(std.math.clamp(terrain_id, 0, 15));
        }
        _ = c.igCheckbox("Walkable", &app.editor.terrain_walkable);
        c.igSetNextItemWidth(160);
        _ = c.igSliderInt("Move Cost", &app.editor.terrain_cost, 1, 9, "%d", 0);
        c.igSetNextItemWidth(160);
        _ = c.igSliderInt("Brush Radius", &app.editor.brush_radius, 0, 4, "%d", 0);
        if (c.igButton("New Variant", v2(136, 0))) {
            app.editor.brush_terrain_id +%= 1;
            app.editor.setStatus("Created terrain variant {d}", .{app.editor.brush_terrain_id});
        }
        if (c.igButton("Void Tile", v2(136, 0))) {
            app.editor.brush_terrain_id = map_mod.VoidTerrainId;
            app.editor.brush_asset_id = 0;
            app.editor.terrain_walkable = false;
            app.editor.terrain_cost = 1;
            app.editor.setStatus("Selected void terrain.", .{});
        }
        if (c.igButton("New Sprite", v2(136, 0))) {
            app.createGeneratedTerrainAsset();
        }
    } else if (app.editor.tool == .object) {
        uiText("Object Type", .{});
        for (tools.ObjectPalette) |kind| {
            var label: [96]u8 = undefined;
            const summary = app.objectPlacementSummary(kind);
            const z = if (summary.limited)
                std.fmt.bufPrintZ(
                    &label,
                    "{s} {d}/{d} | {d} left",
                    .{ tools.objectKindName(kind), summary.placed, summary.limit, summary.remaining },
                ) catch continue
            else
                std.fmt.bufPrintZ(&label, "{s}", .{tools.objectKindName(kind)}) catch continue;
            if (summary.full) pushDisabledButtonStyle();
            if (summary.full) c.igBeginDisabled(true);
            const clicked = c.igButton(z.ptr, v2(if (summary.limited) 206 else 136, 0));
            if (summary.full) c.igEndDisabled();
            if (summary.full) c.igPopStyleColor(3);
            if (clicked) {
                app.editor.object_kind = kind;
            }
            if (kind == app.editor.object_kind) {
                c.igSameLine(0, 6);
                uiText("*", .{});
            }
        }
        if (c.igButton("New Sprite", v2(136, 0))) {
            app.createGeneratedObjectAsset();
        }
    } else if (app.editor.tool == .erase) {
        c.igSetNextItemWidth(160);
        _ = c.igSliderInt("Brush Radius", &app.editor.brush_radius, 0, 4, "%d", 0);
    } else if (app.editor.tool == .select) {
        drawHoverProperties(app);
    }

    c.igSeparator();
    uiText("Layers", .{});
    _ = c.igCheckbox("Terrain Layer", &app.editor.show_terrain);
    _ = c.igCheckbox("Object Layer", &app.editor.show_objects);
    _ = c.igCheckbox("Health Bars", &app.editor.show_health);
    _ = c.igCheckbox("Preview", &app.editor.show_preview);
    c.igSeparator();
    uiText("Debug", .{});
    _ = c.igCheckbox("Grid", &app.editor.show_grid);
    _ = c.igCheckbox("Pathing", &app.editor.show_pathing);
    _ = c.igCheckbox("Sectors", &app.editor.show_sectors);
    _ = c.igCheckbox("Portals", &app.editor.show_portals);
    _ = c.igCheckbox("Simulation", &app.editor.show_simulation);
    _ = c.igCheckbox("Perf", &app.editor.show_perf);

    if (app.editor.show_perf) drawPerfStats(app);

    c.igSeparator();
    if (c.igButton("Save Map", v2(136, 0))) app.saveMap();
    c.igSameLine(0, 8);
    if (c.igButton("Load Map", v2(136, 0))) app.loadMap();

    const dbg = app.game.pathfinder.getDebugData();
    uiText("Sectors {d}  Portals {d}  Edges {d}", .{ dbg.sector_count, dbg.portal_count, dbg.portal_edge_count });
    uiText("Route cache {d}/{d}  Flow {d}/{d}", .{ dbg.path_cache_hits, dbg.path_cache_misses, dbg.flow_cache_hits, dbg.flow_cache_misses });
    c.igSeparator();
    c.igTextUnformatted(&app.editor.status, null);
}

fn drawPerfStats(app: anytype) void {
    const perf = app.perf;
    c.igSeparator();
    uiText("Perf: {s}", .{hotPerfLabel(perf)});
    uiText("Frame {d:.1} ms  {d:.0} fps", .{ perf.frame_ms, perf.fps });
    uiText("CPU {d:.2}  Submit {d:.2}", .{ perf.cpu_ms, perf.submit_ms });
    uiText("Update {d:.2}  Sim {d:.2}", .{ perf.update_ms, perf.sim_ms });
    uiText("FX step {d:.2}  Shots {d:.2}", .{ perf.fx_update_ms, perf.shot_ms });
    uiText("World {d:.2}  SGL {d:.2}", .{ perf.world_ms, perf.sgl_ms });
    uiText("Laser draw {d:.2}  UI {d:.2}", .{ perf.laser_draw_ms, perf.ui_ms + perf.imgui_render_ms });
    uiText("Shots {d}->{d}  FX {d}/{d}", .{ perf.raw_shot_events, perf.visual_shots, perf.active_beams, perf.active_particles });
    uiText("Objects {d}/{d}  Verts {d}", .{ perf.active_objects, perf.object_count, perf.laser_vertices });
}

fn hotPerfLabel(perf: anytype) []const u8 {
    var label: []const u8 = "none";
    var ms: f32 = 0;
    if (perf.sim_ms > ms) {
        label = "simulation";
        ms = perf.sim_ms;
    }
    if (perf.fx_update_ms + perf.shot_ms > ms) {
        label = "laser update";
        ms = perf.fx_update_ms + perf.shot_ms;
    }
    if (perf.world_ms + perf.sgl_ms > ms) {
        label = "world draw";
        ms = perf.world_ms + perf.sgl_ms;
    }
    if (perf.laser_draw_ms > ms) {
        label = "laser draw";
        ms = perf.laser_draw_ms;
    }
    if (perf.submit_ms > ms) {
        label = "submit/GPU";
    }
    return label;
}

fn drawAssetBrowser(app: anytype) void {
    const h = sapp.heightf();
    const w = sapp.widthf();
    c.igSetNextWindowPos(v2(156, @max(540, h - 168)), c.ImGuiCond_Always, v2(0, 0));
    c.igSetNextWindowSize(v2(@max(320, w - 504), 156), c.ImGuiCond_Always);
    _ = c.igBegin("Assets", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
    defer c.igEnd();

    uiText("Selected asset: {d}", .{app.editor.brush_asset_id});
    c.igSeparator();
    var shown: usize = 0;
    for (app.catalog.assets.items) |asset| {
        if (shown >= 18) break;
        const useful = switch (app.editor.tool) {
            .terrain => asset.kind == .terrain or asset.kind == .water,
            .object => asset.kind == .building or asset.kind == .doodad or asset.kind == .unit or asset.kind == .water,
            else => true,
        };
        if (!useful) continue;
        var label: [96]u8 = undefined;
        const z = std.fmt.bufPrintZ(&label, "{d}: {s}", .{ asset.id, trimName(asset.name) }) catch continue;
        if (c.igButton(z.ptr, v2(150, 0))) {
            app.selectAsset(asset.id);
        }
        if ((shown % 3) != 2) c.igSameLine(0, 8);
        shown += 1;
    }
    if (shown == 0) {
        uiText("No PNG assets found under assets/.", .{});
    }
    _ = assets.AssetKind.unknown;
}

fn toolButton(app: anytype, tool: tools.Tool, label: [:0]const u8) void {
    if (app.editor.tool == tool) {
        c.igPushStyleColor_U32(c.ImGuiCol_Button, col32(78, 135, 150, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, col32(92, 153, 169, 255));
        defer c.igPopStyleColor(2);
        if (c.igButton(label.ptr, v2(104, 0))) app.editor.tool = tool;
    } else if (c.igButton(label.ptr, v2(104, 0))) {
        app.editor.tool = tool;
    }
}

fn pushDisabledButtonStyle() void {
    c.igPushStyleColor_U32(c.ImGuiCol_Button, col32(58, 61, 62, 255));
    c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, col32(58, 61, 62, 255));
    c.igPushStyleColor_U32(c.ImGuiCol_ButtonActive, col32(58, 61, 62, 255));
}

fn phaseName(phase: sim.Phase) []const u8 {
    return switch (phase) {
        .setup_player_one => "Setup P1",
        .setup_player_two => "Setup P2",
        .playing => "Playing",
        .game_over => "Game Over",
    };
}

fn phaseButtonLabel(phase: sim.Phase) [:0]const u8 {
    return switch (phase) {
        .setup_player_one => "P2 Setup",
        .setup_player_two => "Start",
        .playing => "Pause",
        .game_over => "Reset",
    };
}

fn drawHoverProperties(app: anytype) void {
    uiText("Hover", .{});
    const x = app.editor.hover_cell_x;
    const y = app.editor.hover_cell_y;
    if (!app.game.map.inBounds(x, y)) {
        uiText("Tile: none", .{});
        return;
    }

    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    const cell = app.game.map.terrain[uy][ux];
    uiText("Tile: {d}, {d}", .{ x, y });
    uiText("Terrain ID: {d}", .{cell.terrain_id});
    uiText("Asset ID: {d}", .{cell.asset_id});
    if (app.catalog.get(cell.asset_id)) |asset| {
        uiText("Asset: {s}", .{trimName(asset.name)});
    }
    uiText("Walkable: {s}", .{yesNo(cell.walkable)});
    uiText("Buildable: {s}", .{yesNo(cell.buildable)});
    uiText("Move Cost: {d}", .{cell.movement_cost});
    uiText("Height: {d}", .{cell.height});

    if (app.game.map.objectAt(x, y)) |object| {
        c.igSeparator();
        uiText("Object: {s}", .{tools.objectKindName(object.kind)});
        uiText("ID: {d}  Team: {d}", .{ object.id, object.team });
        uiText("HP: {d:.0}/{d:.0}", .{ object.hp, object.max_hp });
        uiText("Object Asset: {d}", .{object.asset_id});
    } else {
        c.igSeparator();
        uiText("Object: none", .{});
    }
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn trimName(name: []const u8) []const u8 {
    if (name.len <= 22) return name;
    return name[0..22];
}

fn uiText(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c.igTextUnformatted(z.ptr, null);
}

fn v2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

fn col32(r: u8, g: u8, b: u8, a: u8) c.ImU32 {
    return @as(c.ImU32, r) |
        (@as(c.ImU32, g) << 8) |
        (@as(c.ImU32, b) << 16) |
        (@as(c.ImU32, a) << 24);
}
