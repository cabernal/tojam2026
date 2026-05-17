const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const slog = sokol.log;
const c = @import("../cimgui.zig").c;

const asset_loader = @import("../assets/asset_loader.zig");
const png_loader = @import("../assets/png_loader.zig");
const platform = @import("../platform/web.zig");
const png_writer = @import("png_writer.zig");

const WindowTitle = "Imperator's Gambit Asset Studio";
const MaxCanvas = 128;
const MaxPixels = MaxCanvas * MaxCanvas;
const MaxPixelBytes = MaxPixels * 4;
const DefaultSavePath = "assets/generated/studio_sprite.png";

const Vec2 = struct {
    x: f32,
    y: f32,
};

const CanvasView = struct {
    origin: Vec2,
    scale: f32,
    pixel_w: f32,
    pixel_h: f32,
};

const PixelCoord = struct {
    x: i32,
    y: i32,
};

const Tool = enum {
    brush,
    eraser,
    fill,
    picker,
};

const CanvasMode = enum {
    sprite,
    tile,
};

const Preset = struct {
    name: [:0]const u8,
    mode: CanvasMode,
    width: usize,
    height: usize,
};

const LoadResult = struct {
    original_width: usize,
    original_height: usize,
    resized: bool,
};

const ImageSize = struct {
    width: usize,
    height: usize,
};

const Presets = [_]Preset{
    .{ .name = "Sprite 32", .mode = .sprite, .width = 32, .height = 32 },
    .{ .name = "Unit 48x64", .mode = .sprite, .width = 48, .height = 64 },
    .{ .name = "Object 96", .mode = .sprite, .width = 96, .height = 96 },
    .{ .name = "Iso 64x32", .mode = .tile, .width = 64, .height = 32 },
    .{ .name = "Iso 128x64", .mode = .tile, .width = 128, .height = 64 },
};

const Palette = [_][4]f32{
    .{ 0.90, 0.72, 0.40, 1.0 },
    .{ 0.68, 0.46, 0.25, 1.0 },
    .{ 0.35, 0.26, 0.20, 1.0 },
    .{ 0.75, 0.34, 0.24, 1.0 },
    .{ 0.34, 0.55, 0.44, 1.0 },
    .{ 0.16, 0.32, 0.38, 1.0 },
    .{ 0.28, 0.54, 0.76, 1.0 },
    .{ 0.78, 0.86, 0.92, 1.0 },
    .{ 0.96, 0.94, 0.80, 1.0 },
    .{ 0.52, 0.42, 0.55, 1.0 },
    .{ 0.12, 0.12, 0.15, 1.0 },
    .{ 1.00, 1.00, 1.00, 0.0 },
};

pub const AppState = struct {
    allocator: std.mem.Allocator = undefined,
    catalog: asset_loader.AssetCatalog = undefined,
    pass_action: sg.PassAction = .{},
    initialized: bool = false,

    mode: CanvasMode = .tile,
    tool: Tool = .brush,
    width: usize = 64,
    height: usize = 32,
    pending_width: i32 = 64,
    pending_height: i32 = 32,
    brush_radius: i32 = 1,
    snap_tile_mask: bool = true,
    show_grid: bool = true,
    grid_alpha: f32 = 0.13,
    canvas_zoom: f32 = 1.0,
    canvas_pan: Vec2 = .{ .x = 0, .y = 0 },
    dirty: bool = false,
    selected_asset: ?u16 = null,
    hover_x: i32 = -1,
    hover_y: i32 = -1,
    export_index: i32 = 1,
    mouse: Vec2 = .{ .x = -1, .y = -1 },
    last_mouse: Vec2 = .{ .x = -1, .y = -1 },
    left_painting: bool = false,
    right_painting: bool = false,
    canvas_panning: bool = false,
    loaded_asset_id: ?u16 = null,
    loaded_source_width: usize = 0,
    loaded_source_height: usize = 0,
    loaded_was_resized: bool = false,
    confirm_overwrite: bool = false,

    color: [4]f32 = .{ 0.90, 0.72, 0.40, 1.0 },
    pixels: [MaxPixelBytes]u8 = [_]u8{0} ** MaxPixelBytes,
    save_path: [256]u8 = [_]u8{0} ** 256,
    loaded_source_path: [256]u8 = [_]u8{0} ** 256,
    loaded_source_name: [96]u8 = [_]u8{0} ** 96,
    status: [192]u8 = [_]u8{0} ** 192,
    status_len: usize = 0,

    pub fn init(self: *AppState, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.catalog = asset_loader.AssetCatalog.init(allocator);
        self.updateGeneratedSavePath();
        self.clearCanvas();
        self.dirty = false;
        self.setStatus("Ready. Paint a tile or sprite, then save into assets/generated.", .{});

        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = slog.func },
        });
        sgl.setup(.{ .logger = .{ .func = slog.func } });
        simgui.setup(.{ .logger = .{ .func = slog.func } });
        self.pass_action = .{};
        self.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0.055, .g = 0.060, .b = 0.058, .a = 1.0 },
        };

        self.refreshCatalog();
        self.initialized = true;
    }

    pub fn cleanup(self: *AppState) void {
        if (!self.initialized) return;
        self.catalog.deinit();
        simgui.shutdown();
        sgl.shutdown();
        sg.shutdown();
        self.initialized = false;
    }

    pub fn frame(self: *AppState) void {
        if (!self.initialized) return;
        var dt: f32 = @floatCast(sapp.frameDuration());
        if (!(dt > 0 and dt < 0.25)) dt = 1.0 / 60.0;

        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = dt,
            .dpi_scale = sapp.dpiScale(),
        });
        self.updateHoverFromMouse();
        self.drawUi();

        sg.beginPass(.{
            .action = self.pass_action,
            .swapchain = sglue.swapchain(),
        });
        self.prepareScreenSgl();
        self.drawCanvasSgl();
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
                if (self.canvas_panning) {
                    self.canvas_pan.x += self.mouse.x - self.last_mouse.x;
                    self.canvas_pan.y += self.mouse.y - self.last_mouse.y;
                } else if (self.left_painting and self.screenToPixel(self.mouse) != null) {
                    self.paintFromMouse(false);
                } else if (self.right_painting and self.screenToPixel(self.mouse) != null) {
                    self.paintFromMouse(true);
                }
            },
            .MOUSE_DOWN => {
                self.last_mouse = self.mouse;
                self.mouse = .{ .x = ev.mouse_x, .y = ev.mouse_y };
                if (!consumed and self.screenToPixel(self.mouse) != null) {
                    if (ev.mouse_button == .LEFT) {
                        self.left_painting = true;
                        self.paintFromMouse(false);
                    } else if (ev.mouse_button == .RIGHT) {
                        self.right_painting = true;
                        self.paintFromMouse(true);
                    } else if (ev.mouse_button == .MIDDLE) {
                        self.canvas_panning = true;
                    }
                }
            },
            .MOUSE_UP => {
                if (ev.mouse_button == .LEFT) self.left_painting = false;
                if (ev.mouse_button == .RIGHT) self.right_painting = false;
                if (ev.mouse_button == .MIDDLE) self.canvas_panning = false;
            },
            .MOUSE_SCROLL => {
                self.mouse = .{ .x = ev.mouse_x, .y = ev.mouse_y };
                if (!consumed and self.screenToPixel(self.mouse) != null) {
                    self.adjustZoom(ev.scroll_y);
                }
            },
            else => {},
        }
    }

    fn drawUi(self: *AppState) void {
        const w = sapp.widthf();
        const h = sapp.heightf();
        const left_w: f32 = 276;
        const right_w: f32 = 312;
        const top: f32 = 16;

        self.drawToolsPanel(.{ .x = 12, .y = top }, .{ .x = left_w, .y = h - top * 2 });
        self.drawAssetsPanel(.{ .x = @max(left_w + 392.0, w - right_w - 12), .y = top }, .{ .x = right_w, .y = h - top * 2 });
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

    fn drawCanvasSgl(self: *AppState) void {
        const view = self.canvasView();
        self.drawBackdrop(view);
        self.drawCanvasPixelsSgl(view);
        if (self.show_grid and view.scale >= 6) self.drawGridSgl(view);
        if (self.mode == .tile) self.drawTileOutlineSgl(view);
        if (self.hover_x >= 0 and self.hover_y >= 0) self.drawHoverSgl(view);
    }

    fn canvasView(self: *const AppState) CanvasView {
        const left: f32 = 306;
        const right: f32 = 342;
        const top: f32 = 56;
        const bottom: f32 = 32;
        const avail_w = @max(260.0, sapp.widthf() - left - right);
        const avail_h = @max(220.0, sapp.heightf() - top - bottom);
        const scale_x = (avail_w - 48) / @as(f32, @floatFromInt(self.width));
        const scale_y = (avail_h - 64) / @as(f32, @floatFromInt(self.height));
        const fit_scale = @max(1.0, @floor(@min(scale_x, scale_y)));
        const scale = std.math.clamp(fit_scale * self.canvas_zoom, 1.0, 96.0);
        const pixel_w = @as(f32, @floatFromInt(self.width)) * scale;
        const pixel_h = @as(f32, @floatFromInt(self.height)) * scale;
        return .{
            .origin = .{
                .x = left + (avail_w - pixel_w) * 0.5 + self.canvas_pan.x,
                .y = top + (avail_h - pixel_h) * 0.5 + self.canvas_pan.y,
            },
            .scale = scale,
            .pixel_w = pixel_w,
            .pixel_h = pixel_h,
        };
    }

    fn updateHoverFromMouse(self: *AppState) void {
        if (self.screenToPixel(self.mouse)) |pixel| {
            self.hover_x = pixel.x;
            self.hover_y = pixel.y;
        } else {
            self.hover_x = -1;
            self.hover_y = -1;
        }
    }

    fn screenToPixel(self: *const AppState, screen: Vec2) ?PixelCoord {
        const view = self.canvasView();
        if (screen.x < view.origin.x or screen.y < view.origin.y) return null;
        if (screen.x >= view.origin.x + view.pixel_w or screen.y >= view.origin.y + view.pixel_h) return null;
        const x: i32 = @intFromFloat(@floor((screen.x - view.origin.x) / view.scale));
        const y: i32 = @intFromFloat(@floor((screen.y - view.origin.y) / view.scale));
        if (!self.inCanvas(x, y)) return null;
        return .{ .x = x, .y = y };
    }

    fn paintFromMouse(self: *AppState, alternate: bool) void {
        if (self.screenToPixel(self.mouse)) |pixel| {
            self.applyTool(pixel.x, pixel.y, alternate);
            self.hover_x = pixel.x;
            self.hover_y = pixel.y;
        }
    }

    fn adjustZoom(self: *AppState, scroll_y: f32) void {
        const before = self.screenToWorldCanvas(self.mouse);
        const factor: f32 = if (scroll_y > 0) 1.15 else 1.0 / 1.15;
        self.canvas_zoom = std.math.clamp(self.canvas_zoom * factor, 0.25, 8.0);
        if (before) |pixel_pos| {
            const view = self.canvasView();
            const after_screen = Vec2{
                .x = view.origin.x + pixel_pos.x * view.scale,
                .y = view.origin.y + pixel_pos.y * view.scale,
            };
            self.canvas_pan.x += self.mouse.x - after_screen.x;
            self.canvas_pan.y += self.mouse.y - after_screen.y;
        }
    }

    fn screenToWorldCanvas(self: *const AppState, screen: Vec2) ?Vec2 {
        const view = self.canvasView();
        if (screen.x < view.origin.x or screen.y < view.origin.y) return null;
        if (screen.x >= view.origin.x + view.pixel_w or screen.y >= view.origin.y + view.pixel_h) return null;
        return .{
            .x = (screen.x - view.origin.x) / view.scale,
            .y = (screen.y - view.origin.y) / view.scale,
        };
    }

    fn drawBackdrop(self: *const AppState, view: CanvasView) void {
        _ = self;
        const pad: f32 = 18;
        sgl.beginQuads();
        emitRect(view.origin.x - pad, view.origin.y - pad, view.pixel_w + pad * 2, view.pixel_h + pad * 2, .{ 0.075, 0.085, 0.082, 0.94 });
        emitRect(view.origin.x - 8, view.origin.y - 8, view.pixel_w + 16, view.pixel_h + 16, .{ 0.028, 0.031, 0.030, 1.0 });
        sgl.end();
    }

    fn drawCanvasPixelsSgl(self: *const AppState, view: CanvasView) void {
        sgl.beginQuads();
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const px = view.origin.x + @as(f32, @floatFromInt(x)) * view.scale;
                const py = view.origin.y + @as(f32, @floatFromInt(y)) * view.scale;
                const checker: [4]f32 = if (((x / 4) + (y / 4)) % 2 == 0)
                    .{ 0.36, 0.38, 0.36, 1.0 }
                else
                    .{ 0.25, 0.27, 0.25, 1.0 };
                emitRect(px, py, view.scale, view.scale, checker);

                const idx = self.pixelIndex(@intCast(x), @intCast(y));
                if (self.pixels[idx + 3] != 0) {
                    emitRect(
                        px,
                        py,
                        view.scale,
                        view.scale,
                        .{
                            @as(f32, @floatFromInt(self.pixels[idx])) / 255.0,
                            @as(f32, @floatFromInt(self.pixels[idx + 1])) / 255.0,
                            @as(f32, @floatFromInt(self.pixels[idx + 2])) / 255.0,
                            @as(f32, @floatFromInt(self.pixels[idx + 3])) / 255.0,
                        },
                    );
                }

                if (self.mode == .tile and self.snap_tile_mask and !self.insideTile(@intCast(x), @intCast(y))) {
                    emitRect(px, py, view.scale, view.scale, .{ 0.02, 0.025, 0.026, 0.55 });
                }
            }
        }
        sgl.end();
    }

    fn drawGridSgl(self: *const AppState, view: CanvasView) void {
        sgl.beginLines();
        sgl.c4f(1, 1, 1, self.grid_alpha);
        for (0..self.width + 1) |x| {
            const sx = view.origin.x + @as(f32, @floatFromInt(x)) * view.scale;
            sgl.v2f(sx, view.origin.y);
            sgl.v2f(sx, view.origin.y + view.pixel_h);
        }
        for (0..self.height + 1) |y| {
            const sy = view.origin.y + @as(f32, @floatFromInt(y)) * view.scale;
            sgl.v2f(view.origin.x, sy);
            sgl.v2f(view.origin.x + view.pixel_w, sy);
        }
        sgl.end();
    }

    fn drawTileOutlineSgl(self: *const AppState, view: CanvasView) void {
        _ = self;
        const top = Vec2{ .x = view.origin.x + view.pixel_w * 0.5, .y = view.origin.y };
        const right = Vec2{ .x = view.origin.x + view.pixel_w, .y = view.origin.y + view.pixel_h * 0.5 };
        const bottom = Vec2{ .x = view.origin.x + view.pixel_w * 0.5, .y = view.origin.y + view.pixel_h };
        const left = Vec2{ .x = view.origin.x, .y = view.origin.y + view.pixel_h * 0.5 };
        sgl.beginLines();
        sgl.c4f(0.42, 0.80, 0.88, 0.92);
        emitLine(top, right);
        emitLine(right, bottom);
        emitLine(bottom, left);
        emitLine(left, top);
        sgl.end();
    }

    fn drawHoverSgl(self: *const AppState, view: CanvasView) void {
        const x = view.origin.x + @as(f32, @floatFromInt(self.hover_x)) * view.scale;
        const y = view.origin.y + @as(f32, @floatFromInt(self.hover_y)) * view.scale;
        sgl.beginLines();
        sgl.c4f(1, 1, 1, 0.90);
        emitRectLine(x, y, view.scale, view.scale);
        sgl.end();
    }

    fn drawToolsPanel(self: *AppState, pos: c.ImVec2_c, size: c.ImVec2_c) void {
        c.igSetNextWindowPos(pos, c.ImGuiCond_Always, v2(0, 0));
        c.igSetNextWindowSize(size, c.ImGuiCond_Always);
        _ = c.igBegin("Tile and Sprite Studio", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
        defer c.igEnd();

        c.igSeparatorText("Mode");
        self.modeButton(.sprite, "Sprite");
        c.igSameLine(0, 8);
        self.modeButton(.tile, "Tile");

        c.igSeparatorText("Presets");
        for (Presets, 0..) |preset, i| {
            if (c.igButton(preset.name.ptr, v2(if (i == 2) 232 else 108, 0))) {
                self.applyPreset(preset);
            }
            if (i == 0 or i == 3) c.igSameLine(0, 8);
        }

        c.igSetNextItemWidth(92);
        var next_w = self.pending_width;
        if (c.igInputInt("Width", &next_w, 1, 8, 0)) {
            self.pending_width = std.math.clamp(next_w, 1, MaxCanvas);
        }
        c.igSetNextItemWidth(92);
        var next_h = self.pending_height;
        if (c.igInputInt("Height", &next_h, 1, 8, 0)) {
            self.pending_height = std.math.clamp(next_h, 1, MaxCanvas);
        }
        if (c.igButton("Apply Size", v2(112, 0))) {
            self.resizeCanvas(@intCast(self.pending_width), @intCast(self.pending_height));
        }
        c.igSameLine(0, 8);
        if (c.igButton("Clear", v2(112, 0))) {
            self.clearCanvas();
        }

        c.igSeparatorText("Tools");
        self.toolButton(.brush, "Brush");
        c.igSameLine(0, 8);
        self.toolButton(.eraser, "Erase");
        self.toolButton(.fill, "Fill");
        c.igSameLine(0, 8);
        self.toolButton(.picker, "Pick");

        c.igSetNextItemWidth(156);
        _ = c.igSliderInt("Brush Radius", &self.brush_radius, 0, 8, "%d", 0);
        c.igSetNextItemWidth(156);
        _ = c.igSliderFloat("Zoom", &self.canvas_zoom, 0.25, 8.0, "%.2fx", 0);
        if (c.igButton("Zoom -", v2(70, 0))) {
            self.canvas_zoom = @max(0.25, self.canvas_zoom / 1.25);
        }
        c.igSameLine(0, 8);
        if (c.igButton("Zoom +", v2(70, 0))) {
            self.canvas_zoom = @min(8.0, self.canvas_zoom * 1.25);
        }
        c.igSameLine(0, 8);
        if (c.igButton("Fit", v2(70, 0))) {
            self.canvas_zoom = 1.0;
            self.canvas_pan = .{ .x = 0, .y = 0 };
        }
        _ = c.igCheckbox("Show Grid", &self.show_grid);
        c.igSetNextItemWidth(156);
        _ = c.igSliderFloat("Grid Brightness", &self.grid_alpha, 0.0, 0.60, "%.2f", 0);
        if (self.mode == .tile) {
            _ = c.igCheckbox("Tile Mask", &self.snap_tile_mask);
        }

        c.igSeparatorText("Color");
        _ = c.igColorEdit4("Brush RGBA", self.color[0..].ptr, c.ImGuiColorEditFlags_Uint8 | c.ImGuiColorEditFlags_AlphaBar);
        for (Palette, 0..) |entry, i| {
            var id_buf: [32]u8 = undefined;
            const id = std.fmt.bufPrintZ(&id_buf, "##palette{d}", .{i}) catch continue;
            if (c.igColorButton(id.ptr, colorVec(entry), c.ImGuiColorEditFlags_NoTooltip, v2(28, 24))) {
                self.color = entry;
            }
            if ((i % 6) != 5) c.igSameLine(0, 6);
        }

        c.igSeparatorText("Tile Helpers");
        c.igBeginDisabled(self.mode != .tile);
        if (c.igButton("Fill Diamond", v2(112, 0))) self.fillTileDiamond();
        c.igSameLine(0, 8);
        if (c.igButton("Outline", v2(112, 0))) self.outlineTileDiamond();
        if (c.igButton("Shade Tile", v2(112, 0))) self.shadeTileDiamond();
        c.igEndDisabled();
        c.igSameLine(0, 8);
        if (c.igButton("Mirror X", v2(112, 0))) self.mirrorX();

        c.igSeparatorText("Export");
        c.igSetNextItemWidth(104);
        var next_index = self.export_index;
        if (c.igInputInt("Export #", &next_index, 1, 10, 0)) {
            self.export_index = std.math.clamp(next_index, 1, 9999);
            self.updateGeneratedSavePath();
        }
        if (c.igButton("Generated Name", v2(132, 0))) {
            self.updateGeneratedSavePath();
        }
        uiText("{s}", .{cStringSlice(&self.save_path)});
        if (c.igButton("Save Copy", v2(112, 0))) {
            self.saveGeneratedCopy();
        }
        c.igSameLine(0, 8);
        if (c.igButton("Reload Assets", v2(112, 0))) {
            self.refreshCatalog();
        }

        c.igSeparatorText("Loaded Source");
        if (self.hasLoadedSource()) {
            uiText("{s}", .{self.loadedNameSlice()});
            uiText("{d}x{d}  {s}", .{
                self.loaded_source_width,
                self.loaded_source_height,
                if (self.loaded_was_resized) "resized to fit" else "full image",
            });
        } else {
            uiText("No source sprite opened.", .{});
        }
        if (self.loaded_was_resized) {
            uiText("Overwrite disabled for resized images.", .{});
        }
        const can_overwrite = self.hasLoadedSource() and !self.loaded_was_resized;
        c.igBeginDisabled(!can_overwrite);
        if (self.confirm_overwrite) {
            if (c.igButton("Confirm Overwrite", v2(232, 0))) {
                self.saveLoadedSource();
            }
        } else if (c.igButton("Overwrite Loaded", v2(232, 0))) {
            self.confirm_overwrite = true;
            self.setStatus("Press Confirm Overwrite to replace {s}.", .{self.loadedNameSlice()});
        }
        c.igEndDisabled();

        c.igSeparator();
        self.drawStatus();
    }

    fn drawAssetsPanel(self: *AppState, pos: c.ImVec2_c, size: c.ImVec2_c) void {
        c.igSetNextWindowPos(pos, c.ImGuiCond_Always, v2(0, 0));
        c.igSetNextWindowSize(size, c.ImGuiCond_Always);
        _ = c.igBegin("Game Assets", null, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize);
        defer c.igEnd();

        uiText("Catalog: {d} PNG assets", .{self.catalog.assets.items.len});
        if (c.igButton("Open Selected", v2(132, 0))) {
            self.loadSelectedAsset();
        }
        c.igSameLine(0, 8);
        if (c.igButton("Rescan", v2(92, 0))) {
            self.refreshCatalog();
        }
        c.igSeparator();

        _ = c.igBeginChild_Str("asset-list", v2(0, -1), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_None);
        defer c.igEndChild();

        for (self.catalog.assets.items) |asset| {
            var label_buf: [160]u8 = undefined;
            const label = std.fmt.bufPrintZ(
                &label_buf,
                "{d:0>3}  {s}  {s}",
                .{ asset.id, @tagName(asset.kind), trimName(asset.name) },
            ) catch continue;
            const selected = if (self.selected_asset) |id| id == asset.id else false;
            if (c.igSelectable_Bool(label.ptr, selected, c.ImGuiSelectableFlags_None, v2(0, 0))) {
                self.selected_asset = asset.id;
            }
        }
    }

    fn modeButton(self: *AppState, mode: CanvasMode, label: [:0]const u8) void {
        const selected = self.mode == mode;
        if (selected) pushSelectedButton();
        defer if (selected) c.igPopStyleColor(3);
        if (c.igButton(label.ptr, v2(108, 0))) {
            self.mode = mode;
            if (mode == .tile and self.width == self.height) self.resizeCanvas(64, 32);
            self.setStatus("Switched to {s} mode.", .{@tagName(mode)});
        }
    }

    fn toolButton(self: *AppState, tool: Tool, label: [:0]const u8) void {
        const selected = self.tool == tool;
        if (selected) pushSelectedButton();
        defer if (selected) c.igPopStyleColor(3);
        if (c.igButton(label.ptr, v2(108, 0))) {
            self.tool = tool;
        }
    }

    fn pushSelectedButton() void {
        c.igPushStyleColor_U32(c.ImGuiCol_Button, col32(66, 128, 148, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, col32(80, 150, 172, 255));
        c.igPushStyleColor_U32(c.ImGuiCol_ButtonActive, col32(58, 110, 130, 255));
    }

    fn applyPreset(self: *AppState, preset: Preset) void {
        self.mode = preset.mode;
        self.resizeCanvas(preset.width, preset.height);
        self.clearCanvas();
        self.clearLoadedSource();
        self.updateGeneratedSavePath();
        self.setStatus("New {s} canvas: {d}x{d}.", .{ @tagName(preset.mode), preset.width, preset.height });
    }

    fn resizeCanvas(self: *AppState, next_w: usize, next_h: usize) void {
        const w = std.math.clamp(next_w, 1, MaxCanvas);
        const h = std.math.clamp(next_h, 1, MaxCanvas);
        var next_pixels = [_]u8{0} ** MaxPixelBytes;
        const copy_w = @min(self.width, w);
        const copy_h = @min(self.height, h);
        for (0..copy_h) |y| {
            const src = y * MaxCanvas * 4;
            const dst = y * MaxCanvas * 4;
            @memcpy(next_pixels[dst .. dst + copy_w * 4], self.pixels[src .. src + copy_w * 4]);
        }
        self.pixels = next_pixels;
        self.width = w;
        self.height = h;
        self.pending_width = @intCast(w);
        self.pending_height = @intCast(h);
        self.dirty = true;
        self.confirm_overwrite = false;
        if (self.hasLoadedSource() and (w != self.loaded_source_width or h != self.loaded_source_height)) {
            self.loaded_was_resized = true;
        }
    }

    fn updateGeneratedSavePath(self: *AppState) void {
        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(
            &buf,
            "assets/generated/studio_{s}_{d}x{d}_{d}.png",
            .{ @tagName(self.mode), self.width, self.height, self.export_index },
        ) catch DefaultSavePath;
        copyCString(&self.save_path, path);
    }

    fn clearCanvas(self: *AppState) void {
        @memset(self.pixels[0..], 0);
        self.dirty = true;
        self.confirm_overwrite = false;
    }

    fn clearLoadedSource(self: *AppState) void {
        self.loaded_asset_id = null;
        @memset(self.loaded_source_path[0..], 0);
        @memset(self.loaded_source_name[0..], 0);
        self.loaded_source_width = 0;
        self.loaded_source_height = 0;
        self.loaded_was_resized = false;
        self.confirm_overwrite = false;
    }

    fn refreshCatalog(self: *AppState) void {
        self.catalog.scan(platform.assetRoot()) catch |err| {
            self.setStatus("Asset scan failed: {s}", .{@errorName(err)});
            return;
        };
        if (self.selected_asset) |id| {
            if (@as(usize, id) >= self.catalog.assets.items.len) self.selected_asset = null;
        }
        self.setStatus("Scanned {d} PNG assets under {s}.", .{ self.catalog.assets.items.len, platform.assetRoot() });
    }

    fn loadSelectedAsset(self: *AppState) void {
        const id = self.selected_asset orelse {
            self.setStatus("Select an asset from the list first.", .{});
            return;
        };
        const asset = self.catalog.get(id) orelse {
            self.setStatus("Selected asset no longer exists.", .{});
            return;
        };
        const loaded = self.loadPng(asset.path) catch |err| {
            self.setStatus("Load failed: {s}", .{@errorName(err)});
            return;
        };
        self.loaded_asset_id = asset.id;
        copyCString(&self.loaded_source_path, asset.path);
        copyCString(&self.loaded_source_name, asset.name);
        self.loaded_source_width = loaded.original_width;
        self.loaded_source_height = loaded.original_height;
        self.loaded_was_resized = loaded.resized;
        self.confirm_overwrite = false;
        self.suggestEditPath(asset.name);
        if (loaded.resized) {
            self.setStatus("Opened resized copy of {s} ({d}x{d}).", .{ asset.name, loaded.original_width, loaded.original_height });
        } else {
            self.setStatus("Opened {s} for editing.", .{asset.name});
        }
    }

    fn loadPng(self: *AppState, path: []const u8) !LoadResult {
        const image = try png_loader.loadRgba(self.allocator, path);
        defer image.deinit();

        const original_w: usize = @intCast(image.width);
        const original_h: usize = @intCast(image.height);
        const resized = original_w > MaxCanvas or original_h > MaxCanvas;
        const fitted = fittedSize(original_w, original_h);
        const next_w = fitted.width;
        const next_h = fitted.height;
        self.width = next_w;
        self.height = next_h;
        self.pending_width = @intCast(next_w);
        self.pending_height = @intCast(next_h);
        self.mode = if ((next_w == 64 and next_h == 32) or (next_w == 128 and next_h == 64)) .tile else .sprite;
        @memset(self.pixels[0..], 0);

        const src_w = original_w;
        const src_h = original_h;
        for (0..next_h) |y| {
            const source_original_y = @min(src_h - 1, (y * src_h + next_h / 2) / next_h);
            const source_y = src_h - 1 - source_original_y;
            for (0..next_w) |x| {
                const source_x = @min(src_w - 1, (x * src_w + next_w / 2) / next_w);
                const src = (source_y * src_w + source_x) * 4;
                const dst = self.pixelIndex(@intCast(x), @intCast(y));
                @memcpy(self.pixels[dst .. dst + 4], image.pixels[src .. src + 4]);
            }
        }
        self.dirty = false;
        return .{
            .original_width = original_w,
            .original_height = original_h,
            .resized = resized,
        };
    }

    fn saveGeneratedCopy(self: *AppState) void {
        const path = cStringSlice(&self.save_path);
        if (path.len == 0) {
            self.setStatus("Choose a save path first.", .{});
            return;
        }
        self.savePngToPath(path, "Saved copy {s}.", true);
    }

    fn saveLoadedSource(self: *AppState) void {
        if (!self.hasLoadedSource()) {
            self.setStatus("Open a source sprite first.", .{});
            return;
        }
        if (self.loaded_was_resized) {
            self.setStatus("Overwrite blocked because the opened image was resized.", .{});
            return;
        }
        self.savePngToPath(self.loadedPathSlice(), "Overwrote {s}.", false);
    }

    fn savePngToPath(self: *AppState, path: []const u8, comptime fmt: []const u8, refresh_save_path: bool) void {
        makeParentPath(path) catch |err| {
            self.setStatus("Could not create export folder: {s}", .{@errorName(err)});
            return;
        };
        png_writer.writeRgbaFile(self.allocator, path, self.width, self.height, self.pixels[0..], MaxCanvas * 4) catch |err| {
            self.setStatus("Save failed: {s}", .{@errorName(err)});
            return;
        };
        self.dirty = false;
        self.confirm_overwrite = false;
        self.refreshCatalog();
        self.setStatus(fmt, .{path});
        if (!refresh_save_path) {
            self.restoreLoadedSelection();
        }
    }

    fn suggestEditPath(self: *AppState, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "assets/generated/edit_{s}", .{name}) catch {
            copyCString(&self.save_path, DefaultSavePath);
            return;
        };
        copyCString(&self.save_path, path);
    }

    fn hasLoadedSource(self: *const AppState) bool {
        return self.loadedPathSlice().len != 0;
    }

    fn loadedPathSlice(self: *const AppState) []const u8 {
        return cStringSlice(&self.loaded_source_path);
    }

    fn loadedNameSlice(self: *const AppState) []const u8 {
        const name = cStringSliceSmall(&self.loaded_source_name);
        return if (name.len != 0) name else "(unnamed)";
    }

    fn restoreLoadedSelection(self: *AppState) void {
        if (!self.hasLoadedSource()) return;
        if (self.catalog.findByPathSuffix(self.loadedPathSlice())) |id| {
            self.loaded_asset_id = id;
            self.selected_asset = id;
        }
    }

    fn applyTool(self: *AppState, x: i32, y: i32, alternate: bool) void {
        if (!self.inCanvas(x, y)) return;
        if (alternate and self.tool != .picker) {
            self.paintBrush(x, y, .{ 0, 0, 0, 0 });
            return;
        }
        switch (self.tool) {
            .brush => self.paintBrush(x, y, colorBytes(self.color)),
            .eraser => self.paintBrush(x, y, .{ 0, 0, 0, 0 }),
            .fill => self.floodFill(x, y, colorBytes(self.color)),
            .picker => self.pickColor(x, y),
        }
    }

    fn paintBrush(self: *AppState, x: i32, y: i32, color: [4]u8) void {
        const radius: i32 = if (self.brush_radius < 0) 0 else self.brush_radius;
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (radius > 0 and dx * dx + dy * dy > radius * radius) continue;
                self.setPixel(x + dx, y + dy, color);
            }
        }
    }

    fn floodFill(self: *AppState, sx: i32, sy: i32, replacement: [4]u8) void {
        if (!self.editablePixel(sx, sy)) return;
        const start_idx = self.pixelIndex(sx, sy);
        var target: [4]u8 = undefined;
        @memcpy(target[0..], self.pixels[start_idx .. start_idx + 4]);
        if (std.mem.eql(u8, target[0..], replacement[0..])) return;

        var queue: [MaxPixels]u16 = undefined;
        var seen = [_]bool{false} ** MaxPixels;
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = @intCast(@as(usize, @intCast(sy)) * MaxCanvas + @as(usize, @intCast(sx)));
        tail += 1;

        while (head < tail) {
            const packed_coord = queue[head];
            head += 1;
            const x: i32 = @intCast(@as(usize, packed_coord) % MaxCanvas);
            const y: i32 = @intCast(@as(usize, packed_coord) / MaxCanvas);
            if (!self.editablePixel(x, y)) continue;
            const linear = @as(usize, @intCast(y)) * MaxCanvas + @as(usize, @intCast(x));
            if (seen[linear]) continue;
            seen[linear] = true;

            const idx = self.pixelIndex(x, y);
            if (!std.mem.eql(u8, self.pixels[idx .. idx + 4], target[0..])) continue;
            @memcpy(self.pixels[idx .. idx + 4], &replacement);

            self.pushFillNeighbor(&queue, &tail, x + 1, y, &seen);
            self.pushFillNeighbor(&queue, &tail, x - 1, y, &seen);
            self.pushFillNeighbor(&queue, &tail, x, y + 1, &seen);
            self.pushFillNeighbor(&queue, &tail, x, y - 1, &seen);
        }
        self.dirty = true;
    }

    fn pushFillNeighbor(self: *const AppState, queue: *[MaxPixels]u16, tail: *usize, x: i32, y: i32, seen: *[MaxPixels]bool) void {
        if (tail.* >= queue.len or !self.editablePixel(x, y)) return;
        const linear = @as(usize, @intCast(y)) * MaxCanvas + @as(usize, @intCast(x));
        if (seen[linear]) return;
        queue[tail.*] = @intCast(linear);
        tail.* += 1;
    }

    fn pickColor(self: *AppState, x: i32, y: i32) void {
        if (!self.inCanvas(x, y)) return;
        const idx = self.pixelIndex(x, y);
        self.color = .{
            @as(f32, @floatFromInt(self.pixels[idx])) / 255.0,
            @as(f32, @floatFromInt(self.pixels[idx + 1])) / 255.0,
            @as(f32, @floatFromInt(self.pixels[idx + 2])) / 255.0,
            @as(f32, @floatFromInt(self.pixels[idx + 3])) / 255.0,
        };
    }

    fn fillTileDiamond(self: *AppState) void {
        const color = colorBytes(self.color);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                if (self.insideTile(@intCast(x), @intCast(y))) {
                    const idx = self.pixelIndex(@intCast(x), @intCast(y));
                    @memcpy(self.pixels[idx .. idx + 4], &color);
                }
            }
        }
        self.dirty = true;
    }

    fn outlineTileDiamond(self: *AppState) void {
        const color = colorBytes(self.color);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const ix: i32 = @intCast(x);
                const iy: i32 = @intCast(y);
                if (!self.insideTile(ix, iy)) continue;
                if (self.insideTile(ix - 1, iy) and self.insideTile(ix + 1, iy) and self.insideTile(ix, iy - 1) and self.insideTile(ix, iy + 1)) continue;
                const idx = self.pixelIndex(ix, iy);
                @memcpy(self.pixels[idx .. idx + 4], &color);
            }
        }
        self.dirty = true;
    }

    fn shadeTileDiamond(self: *AppState) void {
        const base = colorBytes(self.color);
        for (0..self.height) |y| {
            const t = if (self.height > 1) @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height - 1)) else 0;
            const shade = 1.18 - t * 0.42;
            for (0..self.width) |x| {
                if (!self.insideTile(@intCast(x), @intCast(y))) continue;
                const idx = self.pixelIndex(@intCast(x), @intCast(y));
                self.pixels[idx] = scaleByte(base[0], shade);
                self.pixels[idx + 1] = scaleByte(base[1], shade);
                self.pixels[idx + 2] = scaleByte(base[2], shade);
                self.pixels[idx + 3] = base[3];
            }
        }
        self.dirty = true;
    }

    fn mirrorX(self: *AppState) void {
        for (0..self.height) |y| {
            var x: usize = 0;
            while (x < self.width / 2) : (x += 1) {
                const a = self.pixelIndex(@intCast(x), @intCast(y));
                const b = self.pixelIndex(@intCast(self.width - 1 - x), @intCast(y));
                var tmp: [4]u8 = undefined;
                @memcpy(tmp[0..], self.pixels[a .. a + 4]);
                @memcpy(self.pixels[a .. a + 4], self.pixels[b .. b + 4]);
                @memcpy(self.pixels[b .. b + 4], &tmp);
            }
        }
        self.dirty = true;
    }

    fn setPixel(self: *AppState, x: i32, y: i32, color: [4]u8) void {
        if (!self.editablePixel(x, y)) return;
        const idx = self.pixelIndex(x, y);
        @memcpy(self.pixels[idx .. idx + 4], &color);
        self.dirty = true;
    }

    fn editablePixel(self: *const AppState, x: i32, y: i32) bool {
        if (!self.inCanvas(x, y)) return false;
        if (self.mode == .tile and self.snap_tile_mask and !self.insideTile(x, y)) return false;
        return true;
    }

    fn inCanvas(self: *const AppState, x: i32, y: i32) bool {
        if (x < 0 or y < 0) return false;
        return @as(usize, @intCast(x)) < self.width and @as(usize, @intCast(y)) < self.height;
    }

    fn insideTile(self: *const AppState, x: i32, y: i32) bool {
        if (!self.inCanvas(x, y)) return false;
        const nx = @abs((@as(f32, @floatFromInt(x)) + 0.5) - @as(f32, @floatFromInt(self.width)) * 0.5) /
            (@as(f32, @floatFromInt(self.width)) * 0.5);
        const ny = @abs((@as(f32, @floatFromInt(y)) + 0.5) - @as(f32, @floatFromInt(self.height)) * 0.5) /
            (@as(f32, @floatFromInt(self.height)) * 0.5);
        return nx + ny <= 1.0;
    }

    fn pixelIndex(self: *const AppState, x: i32, y: i32) usize {
        _ = self;
        return (@as(usize, @intCast(y)) * MaxCanvas + @as(usize, @intCast(x))) * 4;
    }

    fn setStatus(self: *AppState, comptime fmt: []const u8, args: anytype) void {
        @memset(self.status[0..], 0);
        const text = std.fmt.bufPrint(self.status[0 .. self.status.len - 1], fmt, args) catch "Status message too long.";
        self.status_len = text.len;
        self.status[self.status_len] = 0;
    }

    fn drawStatus(self: *const AppState) void {
        if (self.dirty) {
            uiText("Unsaved changes", .{});
        }
        c.igTextUnformatted(self.status[0..].ptr, null);
    }
};

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

fn fittedSize(width: usize, height: usize) ImageSize {
    if (width <= MaxCanvas and height <= MaxCanvas) {
        return .{ .width = width, .height = height };
    }
    if (width >= height) {
        const fitted_h = @max(1, (height * MaxCanvas + width / 2) / width);
        return .{ .width = MaxCanvas, .height = @min(MaxCanvas, fitted_h) };
    }
    const fitted_w = @max(1, (width * MaxCanvas + height / 2) / height);
    return .{ .width = @min(MaxCanvas, fitted_w), .height = MaxCanvas };
}

fn copyCString(dest: anytype, text: []const u8) void {
    @memset(dest.*[0..], 0);
    const len = @min(dest.*.len - 1, text.len);
    @memcpy(dest.*[0..len], text[0..len]);
}

fn cStringSlice(buf: *const [256]u8) []const u8 {
    return cStringSliceAny(buf);
}

fn cStringSliceSmall(buf: *const [96]u8) []const u8 {
    return cStringSliceAny(buf);
}

fn cStringSliceAny(buf: anytype) []const u8 {
    const slice = buf.*[0..];
    const end = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return std.mem.trim(u8, slice[0..end], " \t\r\n");
}

fn colorBytes(color: [4]f32) [4]u8 {
    return .{
        floatByte(color[0]),
        floatByte(color[1]),
        floatByte(color[2]),
        floatByte(color[3]),
    };
}

fn floatByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * 255.0 + 0.5);
}

fn scaleByte(value: u8, scale: f32) u8 {
    return floatByte((@as(f32, @floatFromInt(value)) / 255.0) * scale);
}

fn colorVec(color: [4]f32) c.ImVec4_c {
    return .{ .x = color[0], .y = color[1], .z = color[2], .w = color[3] };
}

fn trimName(name: []const u8) []const u8 {
    if (name.len <= 32) return name;
    return name[0..32];
}

fn uiText(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    c.igTextUnformatted(z.ptr, null);
}

fn emitRect(x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
    sgl.c4f(color[0], color[1], color[2], color[3]);
    sgl.v2f(x, y);
    sgl.v2f(x + w, y);
    sgl.v2f(x + w, y + h);
    sgl.v2f(x, y + h);
}

fn emitLine(a: Vec2, b: Vec2) void {
    sgl.v2f(a.x, a.y);
    sgl.v2f(b.x, b.y);
}

fn emitRectLine(x: f32, y: f32, w: f32, h: f32) void {
    emitLine(.{ .x = x, .y = y }, .{ .x = x + w, .y = y });
    emitLine(.{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h });
    emitLine(.{ .x = x + w, .y = y + h }, .{ .x = x, .y = y + h });
    emitLine(.{ .x = x, .y = y + h }, .{ .x = x, .y = y });
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

pub fn appDesc() sapp.Desc {
    const is_web = builtin.target.cpu.arch.isWasm();
    return .{
        .width = 1440,
        .height = 900,
        .sample_count = 1,
        .window_title = WindowTitle,
        .icon = .{ .sokol_default = true },
        .high_dpi = !is_web,
        .html5 = .{
            .canvas_selector = "#canvas",
            .canvas_resize = false,
            .preserve_drawing_buffer = false,
            .premultiplied_alpha = true,
            .ask_leave_site = false,
        },
    };
}
