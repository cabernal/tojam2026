const std = @import("std");
const map_mod = @import("../map/map.zig");
const path = @import("../pathfinding/mod.zig");
const sim_mod = @import("simulation.zig");

pub const RuntimeGame = struct {
    allocator: std.mem.Allocator,
    map: map_mod.GameMap,
    grid: path.GridMap,
    pathfinder: path.HierarchicalPathfinder,
    simulation: sim_mod.Simulation = .{},

    pub fn init(allocator: std.mem.Allocator) !RuntimeGame {
        var game_map = map_mod.GameMap.initDefault();
        var grid_map = try path.GridMap.init(allocator, map_mod.MapW, map_mod.MapH);
        errdefer grid_map.deinit();
        game_map.rebuildGrid(&grid_map);
        var finder = path.HierarchicalPathfinder.init(allocator, 8);
        errdefer finder.deinit();
        try finder.build(&grid_map, .{ .allow_diagonal_movement = true });
        return .{
            .allocator = allocator,
            .map = game_map,
            .grid = grid_map,
            .pathfinder = finder,
        };
    }

    pub fn deinit(self: *RuntimeGame) void {
        self.pathfinder.deinit();
        self.grid.deinit();
        self.* = undefined;
    }

    pub fn rebuildPathing(self: *RuntimeGame) !void {
        self.map.rebuildGrid(&self.grid);
        try self.pathfinder.updateDirtySectors(&self.grid, .{ .allow_diagonal_movement = true });
    }

    pub fn update(self: *RuntimeGame, dt: f32) void {
        self.simulation.update(&self.map, &self.grid, &self.pathfinder, dt);
    }
};

