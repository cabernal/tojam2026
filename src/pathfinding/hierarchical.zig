const std = @import("std");
const grid = @import("grid_map.zig");
const sector_mod = @import("sector.zig");
const portal_graph = @import("portal_graph.zig");
const astar = @import("astar.zig");
const flow_mod = @import("flow_field.zig");
const cache_mod = @import("cache.zig");
const debug_mod = @import("debug.zig");

pub const HierarchicalPathfinder = struct {
    allocator: std.mem.Allocator,
    sector_size: usize,
    sectors: []sector_mod.Sector = &.{},
    graph: portal_graph.PortalGraph,
    cache: cache_mod.PathCache,
    built_version: u64 = 0,
    debug: debug_mod.PathDebugData = .{},

    pub fn init(allocator: std.mem.Allocator, sector_size: usize) HierarchicalPathfinder {
        return .{
            .allocator = allocator,
            .sector_size = sector_size,
            .graph = portal_graph.PortalGraph.init(allocator),
            .cache = cache_mod.PathCache.init(allocator),
        };
    }

    pub fn deinit(self: *HierarchicalPathfinder) void {
        self.allocator.free(self.sectors);
        self.graph.deinit();
        self.cache.deinit();
        self.* = undefined;
    }

    pub fn build(self: *HierarchicalPathfinder, map: *const grid.GridMap, profile: grid.MovementProfile) !void {
        self.allocator.free(self.sectors);
        self.sectors = try sector_mod.buildSectors(self.allocator, map, self.sector_size);
        try self.graph.build(map, self.sectors, self.sector_size, profile);
        self.cache.clear();
        self.built_version = map.version;
        self.updateDebug();
    }

    pub fn updateDirtySectors(self: *HierarchicalPathfinder, map: *const grid.GridMap, profile: grid.MovementProfile) !void {
        if (self.built_version != map.version) {
            try self.build(map, profile);
        } else {
            self.cache.invalidateChangedVersion(map.version);
        }
    }

    pub fn findPath(
        self: *HierarchicalPathfinder,
        map: *const grid.GridMap,
        start: grid.TileCoord,
        goal: grid.TileCoord,
        profile: grid.MovementProfile,
    ) !astar.Path {
        try self.updateDirtySectors(map, profile);
        const start_sector = sector_mod.sectorIdForCoord(map, self.sector_size, start) orelse return error.NoPath;
        const goal_sector = sector_mod.sectorIdForCoord(map, self.sector_size, goal) orelse return error.NoPath;

        self.debug.last_route_portals = 0;
        if (start_sector != goal_sector) {
            if (self.cache.getRoute(start_sector, goal_sector, profile.key(), map.version)) |route| {
                self.debug.last_route_portals = route.len;
            } else {
                var route = try astar.findPortalRoute(self.allocator, &self.graph, start_sector, goal_sector);
                defer route.deinit();
                self.debug.last_route_portals = route.portal_ids.len;
                try self.cache.putRoute(start_sector, goal_sector, profile.key(), map.version, route.portal_ids);
            }
        }
        self.updateDebug();

        return astar.findGridPath(self.allocator, map, start, goal, profile);
    }

    pub fn getFlowField(
        self: *HierarchicalPathfinder,
        map: *const grid.GridMap,
        target: grid.TileCoord,
        sector_id: usize,
        profile: grid.MovementProfile,
    ) !*flow_mod.FlowField {
        try self.updateDirtySectors(map, profile);
        if (self.cache.getFlow(target, sector_id, profile.key(), map.version)) |field| {
            self.updateDebug();
            return field;
        }
        var field = try flow_mod.FlowField.init(self.allocator, map, target, sector_id, profile);
        try field.compute(map, profile);
        const result = try self.cache.putFlow(field);
        self.updateDebug();
        return result;
    }

    pub fn assignDestinationSlots(
        self: *HierarchicalPathfinder,
        map: *const grid.GridMap,
        starts: []const grid.TileCoord,
        target: grid.TileCoord,
        profile: grid.MovementProfile,
    ) ![]grid.TileCoord {
        var slots = try self.allocator.alloc(grid.TileCoord, starts.len);
        errdefer self.allocator.free(slots);

        var used: std.ArrayList(grid.TileCoord) = .empty;
        defer used.deinit(self.allocator);

        for (starts, 0..) |_, i| {
            var found = false;
            var radius: i32 = 0;
            while (radius < 16 and !found) : (radius += 1) {
                var y = target.y - radius;
                while (y <= target.y + radius and !found) : (y += 1) {
                    var x = target.x - radius;
                    while (x <= target.x + radius and !found) : (x += 1) {
                        if (@max(@abs(x - target.x), @abs(y - target.y)) != radius) continue;
                        const candidate = grid.TileCoord{ .x = x, .y = y };
                        if (!map.isWalkableFor(x, y, profile)) continue;
                        var duplicate = false;
                        for (used.items) |slot| {
                            if (slot.eql(candidate)) {
                                duplicate = true;
                                break;
                            }
                        }
                        if (duplicate) continue;
                        slots[i] = candidate;
                        try used.append(self.allocator, candidate);
                        found = true;
                    }
                }
            }
            if (!found) slots[i] = target;
        }
        return slots;
    }

    pub fn getDebugData(self: *HierarchicalPathfinder) debug_mod.PathDebugData {
        return self.debug;
    }

    fn updateDebug(self: *HierarchicalPathfinder) void {
        self.debug.sector_count = self.sectors.len;
        self.debug.portal_count = self.graph.portals.len;
        self.debug.portal_edge_count = self.graph.edges.len;
        self.debug.path_cache_hits = self.cache.route_hits;
        self.debug.path_cache_misses = self.cache.route_misses;
        self.debug.flow_cache_hits = self.cache.flow_hits;
        self.debug.flow_cache_misses = self.cache.flow_misses;
    }
};

test "hierarchical route, flow cache, invalidation, and slots" {
    var g = try grid.GridMap.init(std.testing.allocator, 12, 8);
    defer g.deinit();
    for (0..7) |y| g.setBlocked(5, @intCast(y), true);

    var finder = HierarchicalPathfinder.init(std.testing.allocator, 4);
    defer finder.deinit();
    try finder.build(&g, .{ .allow_diagonal_movement = false });

    var path = try finder.findPath(&g, .{ .x = 1, .y = 1 }, .{ .x = 10, .y = 1 }, .{ .allow_diagonal_movement = false });
    defer path.deinit();
    try std.testing.expect(path.tiles.len > 0);
    try std.testing.expect(finder.getDebugData().last_route_portals > 0);

    const goal_sector = sector_mod.sectorIdForCoord(&g, 4, .{ .x = 10, .y = 1 }).?;
    const f1 = try finder.getFlowField(&g, .{ .x = 10, .y = 1 }, goal_sector, .{ .allow_diagonal_movement = false });
    const f2 = try finder.getFlowField(&g, .{ .x = 10, .y = 1 }, goal_sector, .{ .allow_diagonal_movement = false });
    try std.testing.expect(f1 == f2);
    try std.testing.expect(finder.getDebugData().flow_cache_hits > 0);

    const starts = [_]grid.TileCoord{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 2 } };
    const slots = try finder.assignDestinationSlots(&g, &starts, .{ .x = 10, .y = 1 }, .{ .allow_diagonal_movement = false });
    defer std.testing.allocator.free(slots);
    try std.testing.expect(!slots[0].eql(slots[1]));

    g.setBlocked(6, 7, true);
    try finder.updateDirtySectors(&g, .{ .allow_diagonal_movement = false });
    try std.testing.expectEqual(g.version, finder.built_version);
}
