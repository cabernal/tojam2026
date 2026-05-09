const tools = @import("tools.zig");
const schema = @import("../map/schema.zig");

pub const EditorState = struct {
    enabled: bool = true,
    tool: tools.Tool = .terrain,
    current_player: u8 = 0,
    brush_terrain_id: u8 = 0,
    brush_asset_id: u16 = 0,
    terrain_walkable: bool = true,
    terrain_cost: i32 = 1,
    brush_radius: i32 = 0,
    show_preview: bool = true,
    object_kind: schema.ObjectKind = .infantry,
    show_terrain: bool = true,
    show_objects: bool = true,
    show_health: bool = true,
    show_grid: bool = true,
    show_pathing: bool = false,
    show_sectors: bool = false,
    show_portals: bool = false,
    show_simulation: bool = true,
    selected_cell_x: i32 = -1,
    selected_cell_y: i32 = -1,
    status: [192]u8 = [_]u8{0} ** 192,

    pub fn setStatus(self: *EditorState, comptime fmt: []const u8, args: anytype) void {
        const z = std.fmt.bufPrintZ(&self.status, fmt, args) catch return;
        if (z.len < self.status.len) {
            self.status[z.len] = 0;
        }
    }
};

const std = @import("std");
